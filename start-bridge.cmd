@echo off
chcp 65001 >nul
cd /d "%~dp0bridge"

if not exist "node_modules\ws" (
  echo [1/2] Installing bridge dependencies...
  call npm install --no-audit --no-fund --registry=https://registry.npmmirror.com
)

echo.
echo [2/2] Starting DSH Mobile Bridge...
echo   - listening on 0.0.0.0 (phone can reach it)
echo   - permission mode: workspace-write (phone approval enabled)
echo.

rem IMPORTANT: the Agent workspace must sit on a path whose ACL can be changed.
rem If it lives under "D:\新建文件夹\..." (non-ASCII + restricted ACL), every tool
rem call fails with: SetNamedSecurityInfoW failed (Win32 5): grantWrite(...)
set DSH_MOBILE_CWD=C:\Users\25894\dsh-mobile-workspace
if not exist "%DSH_MOBILE_CWD%" mkdir "%DSH_MOBILE_CWD%"

if /i "%~1"=="ws" (
  set DSH_MOBILE_TLS=0
  echo NOTE: TLS disabled - running plaintext ws. Use this only on a private
  echo       network (Tailscale) or with an app build that predates wss support.
)

set DSH_MOBILE_HOST=0.0.0.0
set DSH_PERMISSION_MODE=workspace-write
node src\bridge.mjs serve

echo.
echo Bridge stopped. Press any key to close.
pause >nul
