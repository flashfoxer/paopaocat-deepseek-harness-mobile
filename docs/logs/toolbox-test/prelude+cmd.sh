# ---- DSH Android exec shim prelude（自动生成，勿手改）----
DSH_ANDROID_NODE_BIN='D:\Programs\PaopaocatDSH\node\node.exe'
DSH_ANDROID_FS_SHIM='D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\toolbox-test\fake-fs-shim.cjs'
DSH_ANDROID_EXEC_SHIM='D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\app\assets\toolbox\android-exec-shim.cjs'
DSH_ANDROID_TMPDIR='/data/user/0/com.paopao.dsh/files/tmp'
export DSH_ANDROID_NODE_BIN DSH_ANDROID_FS_SHIM DSH_ANDROID_EXEC_SHIM DSH_ANDROID_TMPDIR
case ":$PATH:" in *:/system/bin:*) ;; *) PATH="/system/bin:/system/xbin${PATH:+:$PATH}"; export PATH ;; esac
if [ -n "$LD_LIBRARY_PATH" ]; then LD_LIBRARY_PATH='D:\Programs\PaopaocatDSH\node':"$LD_LIBRARY_PATH"; else LD_LIBRARY_PATH='D:\Programs\PaopaocatDSH\node'; fi
export LD_LIBRARY_PATH
if [ -d "$DSH_ANDROID_TMPDIR" ]; then TMPDIR="$DSH_ANDROID_TMPDIR"; export TMPDIR; fi
node() { "$DSH_ANDROID_NODE_BIN" --expose-internals --require "$DSH_ANDROID_FS_SHIM" --require "$DSH_ANDROID_EXEC_SHIM" "$@"; }
dsh_node() { node "$@"; }
_dsh_sh_run() {
  case "$1" in
    -c|-*c) _dsh_flag="$1" ;;
    *) _dsh_flag="" ;;
  esac
  if [ -n "$_dsh_flag" ] && [ -n "$2" ] && [ -n "$DSH_ANDROID_PRELUDE" ]; then
    _dsh_cmd="$2"
    shift 2
    /system/bin/sh "$_dsh_flag" "$DSH_ANDROID_PRELUDE
$_dsh_cmd" "$@"
  else
    exec /system/bin/sh "$@"
  fi
}
bash() { _dsh_sh_run "$@"; }
sh() { _dsh_sh_run "$@"; }
DSH_ANDROID_PRELUDE='# ---- DSH Android exec shim prelude（自动生成，勿手改）----
DSH_ANDROID_NODE_BIN='\''D:\Programs\PaopaocatDSH\node\node.exe'\''
DSH_ANDROID_FS_SHIM='\''D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\docs\logs\toolbox-test\fake-fs-shim.cjs'\''
DSH_ANDROID_EXEC_SHIM='\''D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\app\assets\toolbox\android-exec-shim.cjs'\''
DSH_ANDROID_TMPDIR='\''/data/user/0/com.paopao.dsh/files/tmp'\''
export DSH_ANDROID_NODE_BIN DSH_ANDROID_FS_SHIM DSH_ANDROID_EXEC_SHIM DSH_ANDROID_TMPDIR
case ":$PATH:" in *:/system/bin:*) ;; *) PATH="/system/bin:/system/xbin${PATH:+:$PATH}"; export PATH ;; esac
if [ -n "$LD_LIBRARY_PATH" ]; then LD_LIBRARY_PATH='\''D:\Programs\PaopaocatDSH\node'\'':"$LD_LIBRARY_PATH"; else LD_LIBRARY_PATH='\''D:\Programs\PaopaocatDSH\node'\''; fi
export LD_LIBRARY_PATH
if [ -d "$DSH_ANDROID_TMPDIR" ]; then TMPDIR="$DSH_ANDROID_TMPDIR"; export TMPDIR; fi
node() { "$DSH_ANDROID_NODE_BIN" --expose-internals --require "$DSH_ANDROID_FS_SHIM" --require "$DSH_ANDROID_EXEC_SHIM" "$@"; }
dsh_node() { node "$@"; }
_dsh_sh_run() {
  case "$1" in
    -c|-*c) _dsh_flag="$1" ;;
    *) _dsh_flag="" ;;
  esac
  if [ -n "$_dsh_flag" ] && [ -n "$2" ] && [ -n "$DSH_ANDROID_PRELUDE" ]; then
    _dsh_cmd="$2"
    shift 2
    /system/bin/sh "$_dsh_flag" "$DSH_ANDROID_PRELUDE
$_dsh_cmd" "$@"
  else
    exec /system/bin/sh "$@"
  fi
}
bash() { _dsh_sh_run "$@"; }
sh() { _dsh_sh_run "$@"; }
'
export DSH_ANDROID_PRELUDE
echo hello-from-mksh; node -e "console.log(2+2)"
