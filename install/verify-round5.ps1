# Round-5 smoke test on the x86_64 emulator (INTERNAL verification only; the
# deliverable is still the arm64 release APK).
#
# Why: this round changed main.dart's root widget, added a native foreground
# service + permissions, and touched four pages. Static analysis cannot tell us
# whether the app still launches. If it crashes on start the delivered APK is
# bricked, so we smoke it here first.
#
# PURE ASCII ONLY (Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI).
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$adb  = 'D:\dev\android-sdk\platform-tools\adb.exe'
$logs = Join-Path $root 'docs\logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$shotDir = Join-Path $root 'docs\screenshots'
New-Item -ItemType Directory -Force -Path $shotDir | Out-Null

function Step($m) { Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

# Dump the semantic tree and print the visible texts (Flutter draws its own UI,
# so this is the only reliable way to assert what is on screen).
function Dump-Texts($tag) {
    & $adb shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
    $dst = Join-Path $logs ('ui-' + $tag + '.xml')
    & $adb pull /sdcard/ui.xml $dst 2>&1 | Out-Null
    if (-not (Test-Path $dst)) { Write-Output "  ($tag) dump failed"; return }
    $texts = Select-String -Path $dst -Pattern 'text="([^"]+)"' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -and $_.Trim().Length -gt 0 }
    Write-Output ("  (" + $tag + ") " + (($texts | Select-Object -Unique -First 22) -join ' | '))
}

function Snap($name) {
    & $adb shell screencap -p /sdcard/s.png 2>&1 | Out-Null
    $tmp = Join-Path $logs ($name + '.png')
    & $adb pull /sdcard/s.png $tmp 2>&1 | Out-Null
    if (Test-Path $tmp) { Copy-Item -Force $tmp (Join-Path $shotDir ($name + '.png')); Write-Output "  shot: $name" }
}

Step 'build x86_64 debug (internal)'
& (Join-Path $root 'install\build-local-apk.ps1') -Abi x86_64 -Mode debug 2>&1 |
    Tee-Object -FilePath (Join-Path $logs 'build-x86-round5.log') | Select-Object -Last 4

$apk = Join-Path $root 'dist\dsh-local-x86_64-app-debug.apk'
if (-not (Test-Path $apk)) { Step 'FAIL: x86_64 apk missing'; exit 1 }
Step ('apk = ' + (Get-Item $apk).Length + ' bytes @ ' + (Get-Item $apk).LastWriteTime)

Step 'install + launch'
& $adb install -r $apk 2>&1 | Select-Object -Last 2
& $adb logcat -c
& $adb shell am force-stop com.dshmobile.dsh_mobile
& $adb shell am start -n com.dshmobile.dsh_mobile/.MainActivity 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds 28

Step 'home page'
Dump-Texts 'home'
Snap 'round5_home'

# Bottom nav cells are five equal slots; centres are ~108/324/540/756/972 at
# y ~2280 on a 1080x2400 screen. (Measured in earlier rounds.)
function Tap-Nav($x, $label) {
    Step ('tap nav: ' + $label)
    & $adb shell input tap $x 2280 | Out-Null
    Start-Sleep -Seconds 4
    Dump-Texts $label
}

Tap-Nav 540 'library'
Snap 'round5_library'
Tap-Nav 756 'scheduled'
Snap 'round5_scheduled'
Tap-Nav 972 'settings'
Snap 'round5_settings'

Step 'logcat: flutter errors / crashes'
$log = & $adb logcat -d 2>&1
$hits = $log | Select-String -Pattern 'dsh-flutter-error|AndroidRuntime|FATAL|E DshLocal|dsh-schedule|dsh-nav' |
    Select-Object -First 40
if ($hits) { $hits | ForEach-Object { '  ' + $_.Line } } else { Write-Output '  (no matching lines)' }

Step 'DONE'
