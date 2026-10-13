#!/system/bin/sh
# 0.13 设备端探针 runner（由主机生成；只做一件事：用 App 真正用的那套
# node + shim + 环境变量，跑 fix13_shim_probe.js）。
PKG=com.dshmobile.dsh_mobile
LIB='__LIB__'
F=/data/data/$PKG/files

LD_LIBRARY_PATH=$LIB
DSH_ANDROID_NODE_BIN=$LIB/libnode.so
DSH_ANDROID_FS_SHIM=$F/shims/android-fs-shim.cjs
DSH_ANDROID_EXEC_SHIM=$F/shims/android-exec-shim.cjs
DSH_ANDROID_TMPDIR=$F/tmp
DSH_ANDROID_TOOLBOX=$F/toolbox
DSH_ANDROID_SHIM_DEBUG=1
export LD_LIBRARY_PATH DSH_ANDROID_NODE_BIN DSH_ANDROID_FS_SHIM DSH_ANDROID_EXEC_SHIM
export DSH_ANDROID_TMPDIR DSH_ANDROID_TOOLBOX DSH_ANDROID_SHIM_DEBUG

mkdir -p "$F/tmp" 2>/dev/null

exec "$LIB/libnode.so" --expose-internals \
  --require "$DSH_ANDROID_FS_SHIM" \
  --require "$DSH_ANDROID_EXEC_SHIM" \
  /data/local/tmp/fix13_shim_probe.js
