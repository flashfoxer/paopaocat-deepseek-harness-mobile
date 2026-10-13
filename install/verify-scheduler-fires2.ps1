# Prove a scheduled task FIRES. Round 2 of this script: the previous attempt
# never even seeded the file, because
#     run-as pkg sh -c "cat > files/schedules.json"
# gets its DOUBLE QUOTES eaten by adb shell itself, so the ">" redirect was
# applied by the OUTER shell (the `shell` user) instead of inside run-as.
# Fix: single-quote the inner command so the redirect stays inside run-as.
#
# *** PURE ASCII ONLY *** (PowerShell 5.1 reads a BOM-less .ps1 as ANSI; CJK
# bytes in here previously broke quote delimiters and produced bogus parse
# errors. Hence the ASCII task name.)
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$adb  = 'D:\dev\android-sdk\platform-tools\adb.exe'
$pkg  = 'com.dshmobile.dsh_mobile'
$logs = Join-Path $root 'docs\logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

$self = Join-Path $PSScriptRoot 'verify-scheduler-fires2.ps1'
$nonAscii = 0
foreach ($b in [System.IO.File]::ReadAllBytes($self)) { if ($b -gt 127) { $nonAscii++ } }
if ($nonAscii -gt 0) { Write-Output ('FATAL: ' + $nonAscii + ' non-ASCII bytes in this script'); exit 2 }

function Step($m) { Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

Step 'diagnose run-as'
& $adb shell ('run-as ' + $pkg + ' pwd') 2>&1 | Select-Object -First 1
& $adb shell ('run-as ' + $pkg + ' ls files') 2>&1 | Select-Object -First 6

$taskName = 'SMOKE-TASK'
$dueUtc = (Get-Date).ToUniversalTime().AddMinutes(2)
$due = $dueUtc.ToString('yyyy-MM-ddTHH:mm:ss')
Step ('seed task due ' + $due + ' UTC')

$json = '{"schedules":[{"id":"sch-smoke","name":"' + $taskName + '",' +
        '"prompt":"Reply with exactly SCHED-OK",' +
        '"repeat":"once","hour":' + $dueUtc.Hour + ',"minute":' + $dueUtc.Minute + ',' +
        '"weekdays":[1],"enabled":true,"createdAt":"' + $due + '","nextRunAt":"' + $due + '"}],"runs":[]}'

# NOTE the inner single quotes -- they must survive adb shell so that the ">"
# redirect is executed *inside* run-as (as the app user, into its private dir).
$inner = 'run-as ' + $pkg + " sh -c 'cat > files/schedules.json'"
$json | & $adb shell $inner 2>&1 | Select-Object -First 3

Step 'verify the file exists on the device'
& $adb shell ('run-as ' + $pkg + ' ls -l files/schedules.json') 2>&1 | Select-Object -First 2
$back = (& $adb shell ('run-as ' + $pkg + ' cat files/schedules.json') 2>&1 | Out-String).Trim()
Step ('readback: ' + $back.Substring(0, [Math]::Min(220, $back.Length)))

Step 'restart app so the scheduler loads it'
& $adb logcat -c
& $adb shell am force-stop $pkg
& $adb shell am start -n ($pkg + '/.MainActivity') 2>&1 | Select-Object -Last 1

$fired = $false
$startedAt = Get-Date
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 20
    $log = & $adb logcat -d 2>&1
    ($log | Select-String -Pattern 'dsh-schedule' | Select-Object -Last 3) |
        ForEach-Object { '  ' + $_.Line }
    if ($log | Select-String -Pattern 'exit=') { $fired = $true; break }
    Step ('  waiting ' + [int](((Get-Date) - $startedAt).TotalSeconds) + 's')
}

Step ('FIRED = ' + $fired)
Step '--- scheduler lines ---'
(& $adb logcat -d 2>&1) | Select-String -Pattern 'dsh-schedule' |
    Select-Object -First 10 | ForEach-Object { '  ' + $_.Line }

Step '--- history persisted on device ---'
$after = (& $adb shell ('run-as ' + $pkg + ' cat files/schedules.json') 2>&1 | Out-String).Trim()
$after | Select-Object -First 1 | ForEach-Object { '  ' + $_.Substring(0, [Math]::Min(500, $_.Length)) }

Step 'DONE'
