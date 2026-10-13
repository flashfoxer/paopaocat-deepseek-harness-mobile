<#
.SYNOPSIS
  Build the asset bundle that the APK ships and unpacks on first launch.

.DESCRIPTION
  We pack the DSH install tree into ONE zip instead of a loose assets/ tree:
  unpacking a single zip stream is dramatically faster than 26k individual
  AssetManager.open() calls (26,492 files, ~484 MB).

  Zip layout:
      app/**      -> the DSH install tree (node_modules, lib, package.json ...)
      shims/**    -> three Android-specific patches (see below)

  The three shims are required for DSH to run on Android at all:
      android-shim-require-builtin.js  -> node_modules/node-addon-require-builtin/lib/index.js
      android-shim-flock.js            -> node_modules/@deepseek-ai/node-addon-system/lib/flock.js
      android-fs-shim.cjs              -> loaded via node --require

  ---------------------------------------------------------------------------
  SLIMMING (2026-10-09). After packing, this script runs install/slim-runtime-zip.py,
  which drops what Android can never use. The $DshSource is a WINDOWS install tree
  (D:\Programs\PaopaocatDSH\app), so the raw zip ships Windows .exe/.dll/.pdb
  plus a pile of dev files. Measured on the real zip:

      raw     157.9 MB / 26495 entries
      slim     33.7 MB /  9930 entries    (-124.2 MB, -78.7%)
      APK     226.6 MB -> ~113.4 MB

  The rules live ONLY in that Python file (it has its own tests in
  install/test_slim_rules.py). Do NOT re-implement them here: two copies of a
  deletion rule WILL drift, and the drifting copy deletes something load-bearing.
  The slimmer also refuses to produce output when its own checks fail
  (package entry points, top-level ESM imports, licences of packages we still ship).

  -SlimOnly : do not repack (a repack takes minutes); just slim the existing zip.
  -SkipSlim : old behaviour, ship the raw Windows tree (only for A/B debugging).

  ASCII-only on purpose: PowerShell 5.1 reads .ps1 as ANSI without a BOM.
#>
param(
  [string]$DshSource = 'D:\Programs\PaopaocatDSH\app',
  [string]$OutDir = 'D:\dev\android-node\app-assets',
  [switch]$Force,
  [switch]$SkipSlim,
  [switch]$SlimOnly
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$shimDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'install'
$zipPath = Join-Path $OutDir 'dsh-runtime.zip'
$slimmer = Join-Path $shimDir 'slim-runtime-zip.py'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Invoke-Slimmer {
  param([string]$Src, [string]$Dst)
  if (-not (Test-Path $slimmer)) { throw "Missing slimmer: $slimmer" }
  $py = 'C:\Python314\python.exe'
  if (-not (Test-Path $py)) { $py = 'python' }
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Host "`n--- slimming runtime zip ---" -ForegroundColor Cyan
  & $py $slimmer $Src $Dst
  if ($LASTEXITCODE -ne 0) {
    throw ("Slimmer refused (exit $LASTEXITCODE): its self-checks failed, so the rules " +
           "would delete something load-bearing. See the FAIL items above. " +
           "DO NOT SHIP a raw or partial zip.")
  }
}

# ---- -SlimOnly: slim the existing zip in place (no repack) ----
if ($SlimOnly) {
  if (-not (Test-Path $zipPath)) { throw "-SlimOnly needs an existing zip: $zipPath" }
  $before = (Get-Item $zipPath).Length
  $tmp = "$zipPath.slim.tmp"
  Invoke-Slimmer -Src $zipPath -Dst $tmp
  Move-Item -Force $tmp $zipPath
  $after = (Get-Item $zipPath).Length
  Write-Host ("`nDone (slim-only): {0:N1} MB -> {1:N1} MB  (saved {2:N1} MB)" -f `
    ($before / 1MB), ($after / 1MB), (($before - $after) / 1MB)) -ForegroundColor Green
  Write-Host "Now rebuild the APK: install\build-local-apk.ps1 -Abi arm64-v8a -Mode release"
  exit 0
}

if (-not (Test-Path $DshSource)) { throw "DSH source not found: $DshSource" }

if ((Test-Path $zipPath) -and -not $Force) {
  $size = (Get-Item $zipPath).Length / 1MB
  Write-Host ("Zip already exists ({0:N1} MB): {1}" -f $size, $zipPath)
  Write-Host "Use -Force to rebuild, or -SlimOnly to slim it without repacking."
  exit 0
}

Write-Host "Packing DSH tree into zip (this takes a few minutes for ~484 MB) ..." -ForegroundColor Cyan
Write-Host "  source: $DshSource"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# includeBaseDirectory = true -> entries are prefixed with the source folder name ("app/")
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $DshSource, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true
)
Write-Host ("  packed in {0:N0}s -> {1:N1} MB" -f $sw.Elapsed.TotalSeconds, ((Get-Item $zipPath).Length / 1MB))

# ---- append the three shims under shims/ ----
Write-Host "Appending shims ..." -ForegroundColor Cyan
$shims = @{
  'android-shim-require-builtin.js' = Join-Path $shimDir 'android-shim-require-builtin.js'
  'android-shim-flock.js'           = Join-Path $shimDir 'android-shim-flock.js'
  'android-fs-shim.cjs'             = Join-Path $shimDir 'android-fs-shim.cjs'
}

$archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Update')
try {
  foreach ($name in $shims.Keys) {
    $srcFile = $shims[$name]
    if (-not (Test-Path $srcFile)) { throw "shim not found: $srcFile" }
    $entryName = "shims/$name"
    $existing = $archive.GetEntry($entryName)
    if ($existing) { $existing.Delete() }
    $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $outStream = $entry.Open()
    try {
      $inStream = [System.IO.File]::OpenRead($srcFile)
      try { $inStream.CopyTo($outStream) } finally { $inStream.Dispose() }
    } finally { $outStream.Dispose() }
    Write-Host ("  + {0}" -f $entryName)
  }
} finally {
  $archive.Dispose()
}

$raw = (Get-Item $zipPath).Length / 1MB
# NOTE: must dispose the reader or the Move-Item below fails with "file in use".
$entryCount = 0
$reader = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try { $entryCount = $reader.Entries.Count } finally { $reader.Dispose() }
Write-Host ("`nRaw zip: {0}  ({1:N1} MB, {2} entries)" -f $zipPath, $raw, $entryCount) -ForegroundColor Green

if ($SkipSlim) {
  Write-Host "`n[SKIP] slimming skipped (-SkipSlim): shipping the RAW Windows tree." -ForegroundColor Yellow
  exit 0
}

# ---- shrink it: keep only what Android can actually load ----
$tmp = "$zipPath.slim.tmp"
Invoke-Slimmer -Src $zipPath -Dst $tmp
Move-Item -Force $tmp $zipPath

$final = (Get-Item $zipPath).Length / 1MB
Write-Host ("`nDone: {0}  ({1:N1} MB after slimming, was {2:N1} MB)" -f `
  $zipPath, $final, $raw) -ForegroundColor Green
Write-Host "Next: install\build-local-apk.ps1 -Abi arm64-v8a -Mode release"
Write-Host "      (or install\rebuild-and-verify.ps1, which also runs the release check)"
