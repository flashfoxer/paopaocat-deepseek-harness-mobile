# shot.ps1 - capture a device screenshot into the workspace screenshots folder.
#
# WHY THIS EXISTS (three traps, all hit before):
#   1. `adb pull` to a non-ASCII local path fails ("cannot create file/directory"),
#      so we pull to an ASCII temp dir first and copy afterwards.
#   2. PowerShell's `>` redirect can mangle binary output, so we never redirect
#      adb output to a file - we use `adb shell screencap` + `adb pull`.
#   3. PowerShell 5.1 reads .ps1 as ANSI unless it has a BOM, so THIS FILE MUST
#      STAY PURE ASCII.
#
# Usage: powershell -File shot.ps1 -Name page08_task
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Adb = 'D:\dev\android-sdk\platform-tools\adb.exe',
  [string]$OutDir = 'D:\dsh-shots',
  [string]$DestDir = ''
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$remote = '/sdcard/dsh_shot.png'
$tmp = Join-Path $OutDir ($Name + '.png')

& $Adb shell screencap -p $remote | Out-Null
if ($LASTEXITCODE -ne 0) { throw "screencap failed" }
& $Adb pull $remote $tmp | Out-Null
if ($LASTEXITCODE -ne 0) { throw "adb pull failed" }
& $Adb shell rm -f $remote | Out-Null

if ($DestDir -ne '') {
  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
  Copy-Item -Path $tmp -Destination (Join-Path $DestDir ($Name + '.png')) -Force
}

Write-Host ("OK {0}  {1:N0} bytes" -f $tmp, (Get-Item $tmp).Length)
