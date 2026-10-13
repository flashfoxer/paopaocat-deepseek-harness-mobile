#!/usr/bin/env bash
# 为 android-arm64 编译 llama.cpp 的 llama-server（端侧模型的文本/多模态引擎）。
#
# 为什么需要脚本而不是记在文档里：源码、ggml pin、STL 选择、strip 这几步任一漏掉都会
# 得到"能编但体积大 10 倍"或"编不过"的结果（都踩过，见 端侧模型-引擎接入可行性核对.md）。
#
# 用法：bash install/engine-build/build-llama-android.sh [输出目录]
set -euo pipefail

OUT="${1:-/tmp/dsh-llama-android}"
NDK="${ANDROID_NDK:-/opt/android-sdk/ndk/28.2.13676358}"
CMAKE_BIN="${CMAKE_BIN:-/opt/android-sdk/cmake/3.22.1/bin/cmake}"
LLAMA_REPO="${LLAMA_REPO:-ggml-org/llama.cpp}"
LLAMA_REF="${LLAMA_REF:-master}"
# 本机 github.com:443 不通；gh-proxy.com 实测 8.45 MB/s（codeload 只有 48 KB/s）
PROXY="${GH_PROXY:-https://gh-proxy.com}"

WORK="$(mktemp -d)"
echo "工作目录：$WORK"
echo "== 1/4 取源码（走 $PROXY）"
curl -L --fail -o "$WORK/llama.tar.gz" \
  "$PROXY/https://github.com/$LLAMA_REPO/archive/refs/heads/$LLAMA_REF.tar.gz"
tar xzf "$WORK/llama.tar.gz" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'llama.cpp-*' | head -1)"
echo "   源码：$SRC"

echo "== 2/4 配置（android-arm64 / c++_shared / 关测试示例 UI）"
"$CMAKE_BIN" -G Ninja -S "$SRC" -B "$SRC/build-android" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
  -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF

echo "== 3/4 编译 llama-server"
"$CMAKE_BIN" --build "$SRC/build-android" --target llama-server -j"$(nproc)"

echo "== 4/4 strip + 拷到 $OUT"
STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
mkdir -p "$OUT"
for f in "$SRC"/build-android/bin/*.so "$SRC"/build-android/bin/llama-server; do
  [ -f "$f" ] || continue
  cp "$f" "$OUT/"
  "$STRIP" --strip-unneeded "$OUT/$(basename "$f")" 2>/dev/null || true
done
du -sh "$OUT"
ls -1 "$OUT"
echo
echo "下一步（还没做，属于 P0 的活）："
echo "  · llama-server 要改名成 lib*.so 才进得了 jniLibs（例如 libllamaserver.so）"
echo "  · 与 7 个依赖 .so 一起放到 jniLibs；build.gradle.kts 已有 useLegacyPackaging=true"
echo "  · 运行时用 LD_LIBRARY_PATH 指向 nativeLibraryDir（照 libnode.so 的做法）"
