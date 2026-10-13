#!/usr/bin/env bash
# 为 android-arm64 编译 stable-diffusion.cpp 的 sd-server（端侧生图 / 生视频引擎）。
#
# ⚠️ 这个引擎有 4 个坑，任一漏掉都编不出来（都实测踩过）：
#   ① 源码要挂代理：本机 github.com:443 不通，codeload 只有 48 KB/s；
#   ② **ggml 是子模块**（不是 llama.cpp 那个 ggml，是作者 leejet 的 fork），
#      而 GitHub tarball **不含子模块**；拿 ggml master 顶上还会因版本漂移报
#      `cannot initialize return object of type 'ggml_type' ...`（F8 类型缺失）。
#      → 必须用 GitHub API 读子模块**锁定的 commit**，再按 commit 下载。
#   ③ `SD_SERVER_BUILD_FRONTEND` 默认 ON，会去 pnpm 编它自己的 Web UI（子模块同样缺失），
#      报错是 `Error: ERR_PNPM_NO_SCRIPT` —— 看着像 pnpm 环境问题，其实是"我们不需要前端"。
#   ④ OpenMP 默认 ON → 产物多一个 libomp.so 依赖；关掉更干净。
#
# 用法：bash install/engine-build/build-sd-android.sh [输出目录]
#       默认输出到 /tmp/dshbuild/android-sd/jnilibs/arm64-v8a（与 llama 分开，便于按需随包）
set -euo pipefail

OUT="${1:-/tmp/dshbuild/android-sd/jnilibs/arm64-v8a}"
NDK="${ANDROID_NDK:-/opt/android-sdk/ndk/28.2.13676358}"
CMAKE_BIN="${CMAKE_BIN:-/opt/android-sdk/cmake/3.22.1/bin/cmake}"
SD_REPO="${SD_REPO:-leejet/stable-diffusion.cpp}"
PROXY="${GH_PROXY:-https://gh-proxy.com}"

WORK="$(mktemp -d)"
echo "工作目录：$WORK"

echo "== 1/5 取 sd.cpp 源码（走 $PROXY）"
curl -L --fail -o "$WORK/sd.tar.gz" \
  "$PROXY/https://github.com/$SD_REPO/archive/refs/heads/master.tar.gz"
tar xzf "$WORK/sd.tar.gz" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'stable-diffusion.cpp-*' | head -1)"
echo "   源码：$SRC"

echo "== 2/5 查 ggml 子模块锁定的 commit（tarball 拿不到子模块）"
GGML_SHA="$(curl -sS "https://api.github.com/repos/$SD_REPO/contents/ggml" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')"
echo "   锁定 commit：$GGML_SHA（注意：上游更新后这个值会变，脚本每次现查）"

echo "== 3/5 按 commit 取 ggml（leejet/ggml fork，不是 ggml-org/ggml）"
curl -L --fail -o "$WORK/ggml.tar.gz" \
  "$PROXY/https://github.com/leejet/ggml/archive/$GGML_SHA.tar.gz"
tar xzf "$WORK/ggml.tar.gz" -C "$WORK"
GGML="$(find "$WORK" -maxdepth 1 -type d -name 'ggml-*' | head -1)"
echo "   ggml：$GGML"
test -f "$GGML/src/ggml-impl.h" || { echo "❌ ggml 树不完整（缺 ggml-impl.h）"; exit 1; }

echo "== 4/5 配置（android-arm64 / 关前端 / 关 OpenMP）"
"$CMAKE_BIN" -G Ninja -S "$SRC" -B "$SRC/build-android" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DSD_BUILD_EXAMPLES=ON -DSD_BUILD_SHARED_LIBS=ON \
  -DSD_SERVER_BUILD_FRONTEND=OFF \
  -DSD_WEBP=OFF -DSD_WEBM=OFF \
  -DGGML_OPENMP=OFF \
  -DSD_GGML_SOURCE_DIR="$GGML"

echo "== 5/5 编译 sd-server + strip + 拷到 $OUT"
"$CMAKE_BIN" --build "$SRC/build-android" --target sd-server -j"$(nproc)"
STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
mkdir -p "$OUT"
cp "$SRC"/build-android/bin/libstable-diffusion.so "$OUT/"
$STRIP --strip-unneeded "$OUT/libstable-diffusion.so" 2>/dev/null || true
# 可执行文件必须叫 lib*.so 才会被打包进 jniLibs（与 libnode.so / libllamaserver.so 同理）。
cp "$SRC"/build-android/bin/sd-server "$OUT/libsdserver.so"
$STRIP --strip-unneeded "$OUT/libsdserver.so" 2>/dev/null || true
chmod +x "$OUT/libsdserver.so"
du -sh "$OUT"
ls -1 "$OUT"
echo
echo "体积提醒：约 39 MB（36.6 库 + 1.3 可执行）。**别默认随包** ——"
echo "  生图功能没接通之前，加进去只是让 APK 白胖 39 MB。"
echo "接通方式（还没做）："
echo "  · App 侧照 local_model_server.dart 写一个 local_image_server.dart（起 libsdserver.so）"
echo "  · 走它的 OpenAI 兼容图像路由（源码里有 routes_openai.cpp）"
echo "  · 与 assets/toolbox/make-image.mjs 的云端生图并存，让用户选"
