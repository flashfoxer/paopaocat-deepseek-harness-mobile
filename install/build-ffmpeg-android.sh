#!/bin/bash
# 为 dsh-mobile 编译 Android arm64 的 ffmpeg / ffprobe（**共享库版** + libx264）。
#
# ## 为什么要自己编（不用现成的预编译二进制）
#   ① 现成的未必带 libx264，而口播/短剧靠它做 H.264 编码；
#   ② 往用户手机上放一段**别人编的**可执行文件是供应链风险。
#   官方源码 + 本机 NDK 自己编，可复现、可核对。
#
# ## 为什么是"共享库"而不是静态（体积）
#   静态双份：ffmpeg 21.5 MB + ffprobe 21.4 MB = **42.8 MB**（手机上解压后）。
#   共享库： 两个可执行文件各 ~0.3 MB + 8 个 libav*/libsw* 合计 **23.8 MB**。
#   → 省 19 MB 安装体积 / 约 9.7 MB APK（用户 2026-10-11 选定的方案）。
#
# ## 三个必须处理的坑（都是踩过的）
#   1. `ERROR: x264 not found using pkg-config` —— 必须把 x264 的
#      `prefix/lib/pkgconfig` 设进 `PKG_CONFIG_PATH`，否则 configure 找不到已装好的 x264。
#   2. **版本化 soname 进不了 APK**：ffmpeg 默认产出 `libavcodec.so.61.19.100` + 软链，
#      而 jniLibs 只收 `lib*.so`、且 **APK 不支持软链**。所以用 `patchelf`
#      把 soname 与可执行文件的 NEEDED 统一改成**朴素名**（`libavcodec.so`）。
#   3. `grep -c` 的退出码：别用它做检查（匹配 0 条返回 1，`set -e` 会把整个脚本判成失败，
#      产物其实早已编好 —— 白排查过一轮）。用 `grep -q ... || exit 1`。
#
# 产物落在 `$OUT`（默认 /tmp/ffshared-out）：两个可执行文件 + 需要的 lib*.so，
# 直接 cp 进 `$DSH_ANDROID_NODE/jnilibs/<abi>/` 即可 —— 那里的 `lib*.so` 会被 Gradle
# 打进包、解压到 nativeLibraryDir，而 **Android 只允许从那里执行文件**。
#
# 验证：`file`（架构）+ `readelf -d`（依赖闭合）+ `install/check-release.py`（出包闸门）；
# 功能验证见 `docs/AUDIT-2026-10-09.md` §17.3（同源码的静态版在 qemu 下真跑 + ffprobe 校验产物）。
set -euo pipefail

NDK=${NDK:-/opt/android-sdk/ndk/28.2.13676358}
API=24                      # 与 Flutter 的 minSdkVersion 一致（见 FlutterExtension.kt）
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
CC=$TC/bin/aarch64-linux-android$API-clang
AR=$TC/bin/llvm-ar; NM=$TC/bin/llvm-nm; RANLIB=$TC/bin/llvm-ranlib; STRIP=$TC/bin/llvm-strip
JOBS=$(nproc)
WORK=${WORK:-/tmp/ffbuild-shared}
OUT=${OUT:-/tmp/ffshared-out}

ALLOWED_SYSTEM_LIBS='libm.so libc.so libdl.so libz.so libandroid.so libmediandk.so libcamera2ndk.so liblog.so'

mkdir -p "$WORK"; cd "$WORK"

echo "=== [1/4] 取源码 ==="
if [ ! -d x264 ]; then
  timeout 600 git clone --depth 1 https://github.com/mirror/x264.git
fi
if [ ! -d ffmpeg ]; then
  timeout 900 curl -fL -o ffmpeg.tar.xz https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz
  tar xf ffmpeg.tar.xz && mv ffmpeg-7.1 ffmpeg
fi
echo "x264:   $(cd x264 && git rev-parse --short HEAD)"
echo "ffmpeg: $(cat ffmpeg/VERSION)"

echo "=== [2/4] x264（静态 + PIC —— 静态链进 libavcodec.so）==="
cd "$WORK/x264"
if [ ! -f "$WORK/prefix/lib/libx264.a" ]; then
  CC=$CC AR=$AR NM=$NM RANLIB=$RANLIB STRIP=$STRIP \
  ./configure --host=aarch64-linux-android --enable-static --enable-pic --disable-cli \
    --prefix="$WORK/prefix" --extra-cflags="-O2"
  make -j"$JOBS" && make install
fi
ls -la "$WORK/prefix/lib/libx264.a"

echo "=== [3/4] ffmpeg（共享库 + libx264 + ffmpeg/ffprobe）==="
cd "$WORK/ffmpeg"
export PKG_CONFIG_PATH="$WORK/prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$WORK/prefix/lib/pkgconfig"
./configure --target-os=android --arch=aarch64 --enable-cross-compile \
  --cc=$CC --ar=$AR --nm=$NM --ranlib=$RANLIB --strip=$STRIP \
  --enable-shared --disable-static --enable-pic --enable-gpl --enable-libx264 \
  --pkg-config-flags=--static --disable-symver \
  --extra-cflags="-I$WORK/prefix/include -O2" --extra-ldflags="-L$WORK/prefix/lib" \
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --disable-debug --disable-ffplay --enable-ffmpeg --enable-ffprobe
make -j"$JOBS"
if ! grep -q "CONFIG_LIBX264 1" config.h; then
  echo "libx264 **没编进去**（config.h 里没有 CONFIG_LIBX264 1）—— 检查 pkg-config 与 x264 安装路径" >&2
  exit 1
fi
echo "libx264: 已编入"

echo "=== [4/4] 整理成「能进 APK」的形状 ==="
# 只打包 ffmpeg/ffprobe **真正 NEEDED** 的库（readelf 说话，不凭猜），
# 并把 soname 统一成朴素名（版本化名字进不了 jniLibs）。
rm -rf "$OUT"; mkdir -p "$OUT"
NEEDED=$(for exe in ffmpeg ffprobe; do
  readelf -d "$exe" | grep -oE 'lib(av|sw|post)[a-z]*\.so'
done | sort -u)
echo "NEEDED 的库：$(echo "$NEEDED" | tr '\n' ' ')"
for name in $NEEDED; do
  base=${name%.so}
  real=$(ls -la "$base/$base".so.* | grep -v '\->' | awk '{print $9}' | head -1)
  [ -n "$real" ] || { echo "找不到 $base 的真实文件" >&2; exit 1; }
  cp -f "$real" "$OUT/$name"
  patchelf --set-soname "$name" "$OUT/$name"
done
cp -f ffmpeg "$OUT/ffmpeg"; cp -f ffprobe "$OUT/ffprobe"
# ⚠️ 这两个是**可执行文件**，最终要以 libffmpeg.so / libffprobe.so 的名字放进 jniLibs
#    （名字必须是 lib*.so，否则 Gradle 根本不会把它打进包）。
patchelf --set-soname libffmpeg.so "$OUT/ffmpeg"

echo
echo "=== 依赖闭合自检（跨库依赖必须在集合内，外部只能是 Android 系统库）==="
cd "$OUT"
FAILED=0
for f in lib*.so ffmpeg ffprobe; do
  for dep in $(readelf -d "$f" | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[//;s/\]//'); do
    if [ -f "$dep" ]; then continue; fi
    case " $ALLOWED_SYSTEM_LIBS " in *" $dep "*) continue ;; esac
    echo "  ❌ $f 依赖了集合外的 $dep" >&2; FAILED=1
  done
done
[ "$FAILED" = 0 ] && echo "  ✅ 全部闭合"
echo
echo "=== 产物（可直接 cp 进 jnilibs/<abi>/）==="
ls -la "$OUT" | awk 'NR>1 {printf "  %8.2f MB  %s\n", $5/1048576, $9}'
du -sm "$OUT" | awk '{print "  合计 " $1 " MB（静态双份方案是 42.8 MB）"}'
echo
echo "下一步："
echo "  cp $OUT/ffmpeg   \$DSH_ANDROID_NODE/jnilibs/arm64-v8a/libffmpeg.so"
echo "  cp $OUT/ffprobe  \$DSH_ANDROID_NODE/jnilibs/arm64-v8a/libffprobe.so"
echo "  cp $OUT/lib*.so  \$DSH_ANDROID_NODE/jnilibs/arm64-v8a/"
echo "  python3 install/check-release.py <apk>   # 闸门会验「存在 + AArch64」"
