# Dump the semantic tree of each tab for EVIDENCE.
#
# Why a separate script: `adb pull <remote> <local>` FAILS when <local> contains
# non-ASCII characters ("cannot create file/directory 'D:\\...\\logs\\ui.xml'").
# So pull into a pure-ASCII directory first, then read/copy from there.
#
# PURE ASCII ONLY (Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI).
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$adb  = 'D:\dev\android-sdk\platform-tools\adb.exe'
$tmp  = 'D:\dev\uiverify'          # ASCII-only staging area
$shot = Join-Path $root 'docs\screenshots'
New-Item -ItemType Directory -Force -Path $tmp, $shot | Out-Null

function Dump($tag) {
    & $adb shell uiautomator dump 2>&1 | Out-Null
    $remote = '/sdcard/window_dump.xml'
    $local = Join-Path $tmp ('ui-' + $tag + '.xml')
    if (Test-Path $local) { Remove-Item -Force $local }
    & $adb pull $remote $local 2>&1 | Out-Null
    if (-not (Test-Path $local)) { Write-Output ('  (' + $tag + ') PULL FAILED'); return }
    $texts = Select-String -Path $local -Pattern 'text="([^"]*)"' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -and $_.Trim().Length -gt 0 }
    Write-Output ('  (' + $tag + ') ' + $texts.Count + ' texts')
    Write-Output ('    ' + (($texts | Select-Object -Unique -First 24) -join ' | '))
}

function Snap($name) {
    & $adb shell screencap -p /sdcard/s.png 2>&1 | Out-Null
    $local = Join-Path $tmp ($name + '.png')
    & $adb pull /sdcard/s.png $local 2>&1 | Out-Null
    if (Test-Path $local) {
        Copy-Item -Force $local (Join-Path $shot ($name + '.png'))
        Write-Output ('  shot: ' + $name)
    } else {
        Write-Output ('  shot FAILED: ' + $name)
    }
}

function Tap($x, $label, $sleep, $snapName) {
    Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] tap ' + $label)
    & $adb shell input tap $x 2280 | Out-Null
    Start-Sleep -Seconds $sleep
    Dump $label
    if ($snapName) { Snap $snapName }
}

# The app is already installed and running from the previous step.
Tap 108 'home' 2 'round5c_home'
Tap 540 'library' 5 'round5c_library'
Tap 756 'scheduled' 3 'round5c_scheduled'
Tap 972 'settings' 5 'round5c_settings'

Write-Output '--- flutter errors ---'
$log = & $adb logcat -d 2>&1
$errs = $log | Select-String -Pattern 'dsh-flutter-error' | Select-Object -First 8
if ($errs) { $errs | ForEach-Object { '  ' + $_.Line } } else { Write-Output '  0 hits' }
