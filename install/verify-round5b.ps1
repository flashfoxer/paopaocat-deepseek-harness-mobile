# Focused re-verify after fixing the library-page crash.
# Builds the internal x86_64 debug APK, installs it, walks the tabs and dumps
# the semantic tree (Flutter draws its own UI, so the tree is the only proof).
#
# PURE ASCII ONLY (Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI).
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$adb  = 'D:\dev\android-sdk\platform-tools\adb.exe'
$logs = Join-Path $root 'docs\logs'
$shot = Join-Path $root 'docs\screenshots'
New-Item -ItemType Directory -Force -Path $logs, $shot | Out-Null

function Step($m) { Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

function Dump-Texts($tag) {
    # Default path: passing an explicit path silently produced nothing last time.
    & $adb shell uiautomator dump 2>&1 | Out-Null
    $dst = Join-Path $logs ('ui2-' + $tag + '.xml')
    if (Test-Path $dst) { Remove-Item -Force $dst }
    $pull = & $adb pull /sdcard/window_dump.xml $dst 2>&1
    if (-not (Test-Path $dst)) {
        Write-Output ("  (" + $tag + ") PULL FAILED: " + ($pull -join ' '))
        return
    }
    $size = (Get-Item $dst).Length
    $texts = Select-String -Path $dst -Pattern 'text="([^"]*)"' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -and $_.Trim().Length -gt 0 }
    Write-Output ("  (" + $tag + ") bytes=" + $size + " texts=" + $texts.Count)
    Write-Output ("  (" + $tag + ") " + (($texts | Select-Object -Unique -First 20) -join ' | '))
}

function Snap($name) {
    & $adb shell screencap -p /sdcard/s.png 2>&1 | Out-Null
    $tmp = Join-Path $logs ($name + '.png')
    & $adb pull /sdcard/s.png $tmp 2>&1 | Out-Null
    if (Test-Path $tmp) { Copy-Item -Force $tmp (Join-Path $shot ($name + '.png')); Write-Output "  shot: $name" }
}

Step 'build x86_64 debug (internal)'
& (Join-Path $root 'install\build-local-apk.ps1') -Abi x86_64 -Mode debug 2>&1 |
    Tee-Object -FilePath (Join-Path $logs 'build-x86-round5b.log') | Select-Object -Last 3

Step 'install + launch'
$apk = Join-Path $root 'dist\dsh-local-x86_64-app-debug.apk'
& $adb install -r $apk 2>&1 | Select-Object -Last 1
& $adb logcat -c
& $adb shell am force-stop com.dshmobile.dsh_mobile
& $adb shell am start -n com.dshmobile.dsh_mobile/.MainActivity 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds 26

Step 'home'
Dump-Texts 'home'
Snap 'round5b_home'

function Tap-Nav($x, $label, $sleep) {
    Step ('tap nav: ' + $label)
    & $adb shell input tap $x 2280 | Out-Null
    Start-Sleep -Seconds $sleep
    Dump-Texts $label
}

Tap-Nav 540 'library' 6
Snap 'round5b_library'
Tap-Nav 756 'scheduled' 4
Snap 'round5b_scheduled'
Tap-Nav 972 'settings' 5
Snap 'round5b_settings'

Step 'logcat: flutter errors only'
$log = & $adb logcat -d 2>&1
$errs = $log | Select-String -Pattern 'dsh-flutter-error' | Select-Object -First 12
if ($errs) { $errs | ForEach-Object { '  ' + $_.Line } } else { Write-Output '  [dsh-flutter-error] 0 hits' }
$sched = $log | Select-String -Pattern 'dsh-schedule|dsh-nav' | Select-Object -First 12
Write-Output '  --- nav/schedule ---'
if ($sched) { $sched | ForEach-Object { '  ' + $_.Line } }

Step 'DONE'
