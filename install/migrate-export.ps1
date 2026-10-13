<#
.SYNOPSIS
  Export everything needed to continue this project on another computer.

.DESCRIPTION
  Produces one folder + one zip under -Dest containing:
    01-project/        the repo (dsh-mobile, minus dist/*.apk, build, .dart_tool, __pycache__)
    02-session/        the DSH desktop home: storages/ (session cache + ARCHIVES), sessions/,
                       mnemon-cli/ (memory), logs/, settings
    03-build-deps/     D:\dev\android-node  (dsh-runtime.zip + jniLibs)  +  debug.keystore
    04-apks/           the built APKs            (only with -IncludeApks; ~3.4 GB)
    05-misc/           theme-screenshots / pdf-images / .dsh-vision-router (workspace extras)
    MANIFEST.txt       file counts, sizes, sha256 of the zip
  Secrets (.credentials.yaml / .env) are NOT copied unless -IncludeSecrets is given.

.NOTES
  ASCII only on purpose: Windows PowerShell 5.1 mis-reads BOM-less UTF-8 scripts with CJK text.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\migrate-export.ps1
#>
param(
  [string]$Dest = 'D:\dev\build\migration',
  [switch]$IncludeApks,
  [switch]$IncludeSecrets
)

$ErrorActionPreference = 'Continue'
$Repo     = Split-Path -Parent $PSScriptRoot          # dsh-mobile\
$Workspace= Split-Path -Parent $Repo                  # the folder that holds dsh-mobile\
$DshHome  = Join-Path $env:APPDATA 'PaopaocatDSH'
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$Stage    = Join-Path $Dest "stage-$Stamp"
$ZipName  = "dsh-mobile-migration-$Stamp.zip"
$ZipPath  = Join-Path $Dest $ZipName

function Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

Step "prepare"
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Write-Host "stage : $Stage"
Write-Host "zip   : $ZipPath"

Step "01 project (repo minus rebuildable stuff)"
$projDst = Join-Path $Stage '01-project'
robocopy $Repo $projDst /MIR /XD build .dart_tool .idea .gradle __pycache__ node_modules /XF '*.apk' `
  /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy project failed: $LASTEXITCODE" }
Write-Host "  done"

Step "02 DSH desktop home (session + archives + memory)"
$sessDst = Join-Path $Stage '02-session'
New-Item -ItemType Directory -Force -Path $sessDst | Out-Null
# storages = session cache + the rolled-over ARCHIVES; sessions = session transcripts;
# mnemon-cli = runtime memory; logs = diagnostics
foreach ($item in 'storages', 'sessions', 'mnemon-cli', 'logs') {
  $src = Join-Path $DshHome $item
  if (Test-Path $src) {
    robocopy $src (Join-Path $sessDst $item) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    Write-Host "  + $item"
  } else { Write-Host "  (missing) $item" }
}
foreach ($f in 'settings.yaml.imported', '.anonymous-user-id', '.install-version') {
  $src = Join-Path $DshHome $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $sessDst $f) -Force; Write-Host "  + $f" }
}
if ($IncludeSecrets) {
  foreach ($f in '.credentials.yaml', '.env') {
    $src = Join-Path $DshHome $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $sessDst $f) -Force; Write-Host "  + $f  (SECRET!)" }
  }
} else {
  Write-Host "  (skipped .credentials.yaml / .env - re-enter keys on the new machine, or re-run with -IncludeSecrets)"
}

Step "03 build deps (required to build the local APK)"
$depDst = Join-Path $Stage '03-build-deps'
New-Item -ItemType Directory -Force -Path $depDst | Out-Null
$androidNode = 'D:\dev\android-node'
if (Test-Path $androidNode) {
  robocopy $androidNode (Join-Path $depDst 'android-node') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  Write-Host "  + D:\dev\android-node"
} else { Write-Host "  (missing) D:\dev\android-node" }
$ks = Join-Path $env:USERPROFILE '.android\debug.keystore'
if (Test-Path $ks) {
  Copy-Item $ks (Join-Path $depDst 'debug.keystore') -Force
  Write-Host "  + debug.keystore (same signing key => in-place upgrade works)"
}

if ($IncludeApks) {
  Step "04 apks"
  $apkDst = Join-Path $Stage '04-apks'
  $dist = Join-Path $Repo 'dist'
  if (Test-Path $dist) { robocopy $dist $apkDst /MIR /XD _old-names /NFL /NDL /NJH /NJS /NP | Out-Null; Write-Host "  + dist" }
} else {
  Write-Host "`n(skipping dist/*.apk - rebuildable; add -IncludeApks to include them)"
}

Step "05 workspace extras"
$miscDst = Join-Path $Stage '05-misc'
New-Item -ItemType Directory -Force -Path $miscDst | Out-Null
foreach ($item in 'theme-screenshots', 'pdf-images', '.dsh-vision-router') {
  $src = Join-Path $Workspace $item
  if (Test-Path $src) {
    robocopy $src (Join-Path $miscDst $item) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    Write-Host "  + $item"
  }
}

Step "manifest"
$lines = @()
$lines += "export    : $(Get-Date -Format o)"
$lines += "machine   : $env:COMPUTERNAME / $env:USERNAME"
$lines += "repo      : $Repo"
$lines += "dsh home  : $DshHome"
$lines += "apks      : $(if ($IncludeApks) { 'included' } else { 'excluded' })"
$lines += "secrets   : $(if ($IncludeSecrets) { 'INCLUDED' } else { 'excluded' })"
$lines += ""
$lines += "--- sections ---"
foreach ($d in Get-ChildItem $Stage -Directory) {
  $s = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  $n = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue).Count
  $lines += ("{0,-16} {1,6} files {2,10:N1} MB" -f $d.Name, $n, ($s / 1MB))
}
$lines += ""
$lines += "--- docs included (project/docs) ---"
$lines += (Get-ChildItem (Join-Path $projDst 'docs') -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$lines | Set-Content (Join-Path $Stage 'MANIFEST.txt') -Encoding UTF8
$lines | ForEach-Object { Write-Host "  $_" }

Step "zip (tar -a => fast, no recompression of APKs unless included)"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Push-Location $Stage
tar -a -cf $ZipPath *
Pop-Location
if (-not (Test-Path $ZipPath)) { throw "zip failed" }
$hash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash
$size = (Get-Item $ZipPath).Length
Add-Content (Join-Path $Stage 'MANIFEST.txt') -Value "sha256    : $hash" -Encoding UTF8
Write-Host ""
Write-Host "DONE" -ForegroundColor Green
Write-Host ("  zip    : {0}" -f $ZipPath)
Write-Host ("  size   : {0:N1} MB" -f ($size / 1MB))
Write-Host ("  sha256 : {0}" -f $hash)
Write-Host ("  stage  : {0}  (keep it, or delete after verifying the zip)" -f $Stage)
