<#
.SYNOPSIS
  Assemble a ready-to-pack Android node runtime from Termux .deb packages.

.DESCRIPTION
  Termux packages contain paths like /data/data/com.termux/files/usr/...
  This script flattens them into:

      runtime/<arch>/bin/node
      runtime/<arch>/lib/lib*.so*

  Usage:
    - aarch64 -> real device (arm64 phone)
    - x86_64  -> emulator verification

  NOTE: this file is deliberately ASCII-only. PowerShell 5.1 reads .ps1 as ANSI
  unless the file has a BOM, and non-ASCII comments break parsing outright.
#>
param(
  [ValidateSet('aarch64', 'x86_64')]
  [string]$Arch = 'x86_64'
)

$debRoot = 'D:\dev\android-node'
$out = Join-Path $debRoot "runtime\$Arch"
$tmp = Join-Path $debRoot "runtime\_tmp_$Arch"

Remove-Item -Recurse -Force $out, $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$out\bin", "$out\lib", $tmp | Out-Null

function Expand-Deb {
  param([string]$DebPath, [string]$DestDir)
  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
  & tar -xf $DebPath -C $DestDir
  $dataTar = Join-Path $DestDir 'data.tar.xz'
  if (Test-Path $dataTar) {
    & tar -xf $dataTar -C $DestDir
    Remove-Item $dataTar -Force -ErrorAction SilentlyContinue
  }
  Remove-Item (Join-Path $DestDir 'control.tar.xz') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $DestDir 'debian-binary') -Force -ErrorAction SilentlyContinue
}

Write-Host "Extracting node ($Arch) ..." -ForegroundColor Cyan
Expand-Deb "$debRoot\nodejs-26.4.0-$Arch.deb" "$tmp\node"

$nodeSrc = Get-ChildItem "$tmp\node" -Recurse -File | Where-Object { $_.FullName -match '\\bin\\node$' } | Select-Object -First 1
if (-not $nodeSrc) { throw "node binary not found in package" }

Copy-Item $nodeSrc.FullName "$out\bin\node" -Force
Write-Host ("  node binary: {0:N1} MB" -f ((Get-Item "$out\bin\node").Length / 1MB))

$depsDir = Join-Path $debRoot "deps\$Arch"
$debs = Get-ChildItem $depsDir -Filter '*.deb' -ErrorAction SilentlyContinue
Write-Host ("Extracting {0} dependency packages ..." -f $debs.Count) -ForegroundColor Cyan

foreach ($deb in $debs) {
  $sub = Join-Path $tmp $deb.BaseName
  Expand-Deb $deb.FullName $sub
  $libs = Get-ChildItem $sub -Recurse -File | Where-Object { $_.Name -match '\.so(\.\d+)*$' }
  foreach ($lib in $libs) {
    Copy-Item $lib.FullName "$out\lib\" -Force
    Write-Host ("  {0,-34} {1,7:N2} MB" -f $lib.Name, ($lib.Length / 1MB))
  }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== runtime: $out ===" -ForegroundColor Green
Get-ChildItem $out -Recurse -File | ForEach-Object {
  Write-Host ("  {0,-42} {1,8:N2} MB" -f $_.FullName.Replace("$out\", ''), ($_.Length / 1MB))
}
$total = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("total: {0:N1} MB" -f ($total / 1MB)) -ForegroundColor Green
