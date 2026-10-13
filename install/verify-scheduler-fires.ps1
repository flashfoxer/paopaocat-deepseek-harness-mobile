# Prove that a scheduled task actually FIRES (not just that the UI renders).
#
# Approach: seed the app's schedules.json with a task due in ~2.5 minutes, then
# restart the app and watch logcat. This exercises the whole loop:
#   load() -> nextRunAt -> foreground service -> timer tick -> headless(prompt)
#   -> real model call -> run recorded in history
#
# Avoids the material time picker on purpose (fiddly to drive blindly).
#
# DEVICE CLOCK IS UTC on this emulator (logcat 08:27 while local time is 16:27),
# and Dart's DateTime.now() uses the device clock -> the seeded nextRunAt must be
# written in UTC, otherwise it lands 8 hours in the future and never fires.
#
# *** PURE ASCII ONLY ***
# This bit me twice: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so ANY
# non-ASCII byte gets mangled -- and CJK bytes can even break quote delimiters,
# producing bogus "Unexpected token 's'" parse errors far from the real cause.
# Hence an ASCII-only task name here. (The app itself handles CJK fine.)
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$adb  = 'D:\dev\android-sdk\platform-tools\adb.exe'
$pkg  = 'com.dshmobile.dsh_mobile'
$logs = Join-Path $root 'docs\logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Self-check: refuse to run if this file somehow gained non-ASCII bytes.
$self = Join-Path $PSScriptRoot 'verify-scheduler-fires.ps1'
$bytes = [System.IO.File]::ReadAllBytes($self)
$nonAscii = 0
foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
if ($nonAscii -gt 0) {
    Write-Output ('FATAL: this script contains ' + $nonAscii + ' non-ASCII bytes; PowerShell 5.1 will mis-parse it.')
    exit 2
}

function Step($m) { Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

$taskName = 'SMOKE-TASK'
$dueUtc = (Get-Date).ToUniversalTime().AddMinutes(2.5)
$due = $dueUtc.ToString('yyyy-MM-ddTHH:mm:ss')
Step ('seeding a task due at ' + $due + ' (UTC); device clock is UTC')

$json = '{"schedules":[{"id":"sch-smoke","name":"' + $taskName + '",' +
        '"prompt":"Reply with exactly SCHED-OK",' +
        '"repeat":"once","hour":' + $dueUtc.Hour + ',"minute":' + $dueUtc.Minute + ',' +
        '"weekdays":[1],"enabled":true,"createdAt":"' + $due + '","nextRunAt":"' + $due + '"}],"runs":[]}'

# run-as + stdin is the documented way to write into the app's private dir
# (the installed build is the debuggable one, so run-as works).
$json | & $adb shell ('run-as ' + $pkg + ' sh -c "cat > files/schedules.json"') 2>&1 | Out-Null
Step 'seeded; reading it back from the device:'
& $adb shell ('run-as ' + $pkg + ' cat files/schedules.json') 2>&1 | Select-Object -First 2

Step 'restart app so the scheduler loads it'
& $adb logcat -c
& $adb shell am force-stop $pkg
& $adb shell am start -n ($pkg + '/.MainActivity') 2>&1 | Select-Object -Last 1

$fired = $false
$startedAt = Get-Date
for ($i = 0; $i -lt 14; $i++) {
    Start-Sleep -Seconds 20
    $log = & $adb logcat -d 2>&1
    $hit = $log | Select-String -Pattern 'dsh-schedule'
    if ($hit) { $hit | Select-Object -Last 4 | ForEach-Object { '  ' + $_.Line } }
    if ($log | Select-String -Pattern 'exit=') { $fired = $true; break }
    $elapsed = [int](((Get-Date) - $startedAt).TotalSeconds)
    Step ('  ...waiting (' + $elapsed + 's)')
}

Step ('FIRED = ' + $fired)
Step '--- scheduler / service lines ---'
(& $adb logcat -d 2>&1) | Select-String -Pattern 'dsh-schedule|DshLocal' |
    Select-Object -First 16 | ForEach-Object { '  ' + $_.Line }

Step '--- persisted JSON read back from the device (history should have the run) ---'
$back = & $adb shell ('run-as ' + $pkg + ' cat files/schedules.json') 2>&1
$back | Select-Object -First 4 | ForEach-Object { '  ' + $_.Substring(0, [Math]::Min(400, $_.Length)) }

Step 'DONE'
