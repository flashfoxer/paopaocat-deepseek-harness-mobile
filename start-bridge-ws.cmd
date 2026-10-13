@echo off
chcp 65001 >nul
cd /d "%~dp0bridge"

if not exist "node_modules\ws" (
  echo Installing bridge dependencies...
  call npm install --no-audit --no-fund --registry=https://registry.npmmirror.com
)

set DSH_MOBILE_TLS=0
echo.
echo NOTE: TLS is DISABLED - the bridge speaks plaintext ws.
echo       Use this only on a private network (e.g. Tailscale), or with an app
echo       build that does not support wss yet.
echo.

rem The Agent workspace must sit on an ACL-writable path.
rem Under "D:\新建文件夹\..." every tool call fails with:
rem   SetNamedSecurityInfoW failed (Win32 5): grantWrite(...)
set DSH_MOBILE_CWD=C:\Users\25894\dsh-mobile-workspace
if not exist "%DSH_MOBILE_CWD%" mkdir "%DSH_MOBILE_CWD%"

set DSH_MOBILE_HOST=0.0.0.0
set DSH_PERMISSION_MODE=workspace-write
node src\bridge.mjs serve

echo.
echo Bridge stopped. Press any key to close.
pause >nul
