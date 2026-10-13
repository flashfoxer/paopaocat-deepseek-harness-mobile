# uitap.ps1 - dump the Flutter semantics tree and tap a node by its label.
#
# WHY: Flutter is a self-drawn engine, so uiautomator only sees the semantics
# tree that main.dart exposes via ensureSemantics(). That tree IS the reliable
# way to both find elements and prove an interaction happened.
#
# Usage:
#   powershell -File uitap.ps1 -Label <label>            (e.g. an expert chip name)
#   powershell -File uitap.ps1 -Dump                 (just print the tree)
#   powershell -File uitap.ps1 -Label <label> -Long 900   (long press, e.g. hold-to-talk)
#
# PowerShell 5.1 reads .ps1 as ANSI unless BOM -> THIS FILE MUST STAY PURE ASCII,
# which also means the -Label values are passed on the command line (not typed
# here) so Chinese labels do not end up as literals in the file.
# (The examples above used to spell out real Chinese chips -- i.e. the file
#  violated its own rule. Kept as placeholders on purpose.)
param(
  [string]$Label = '',
  [switch]$Dump,
  [int]$Long = 0,
  [int]$Index = 0,
  [string]$Adb = 'D:\dev\android-sdk\platform-tools\adb.exe'
)

$remote = '/sdcard/dsh_ui.xml'

# WHY the rm + retry: `uiautomator dump` sometimes fails with
# "null root node returned by UiTestAutomationBridge" (screen busy / just after
# an activity start). It then leaves the PREVIOUS dump on disk, and `cat` happily
# returns a stale tree - which silently makes verification meaningless.
# Always delete first, and retry a couple of times.
$xml = ''
for ($try = 1; $try -le 3; $try++) {
  & $Adb shell rm -f $remote | Out-Null
  & $Adb shell uiautomator dump $remote 2>&1 | Out-Null
  $xml = (& $Adb shell cat $remote) -join "`n"
  if ($xml.Length -ge 50 -and $xml -notmatch 'null root node') { break }
  Write-Host ("[uitap] dump attempt {0} failed, retrying..." -f $try)
  Start-Sleep -Milliseconds 1200
}
if ($xml -notmatch '<hierarchy') { throw 'uiautomator dump returned nothing' }

$matches = [regex]::Matches($xml, '<node[^>]*/?>')
$found = @()
foreach ($m in $matches) {
  $n = $m.Value
  $d = [regex]::Match($n, 'content-desc="([^"]*)"').Groups[1].Value
  $b = [regex]::Match($n, 'bounds="([^"]*)"').Groups[1].Value
  if ($d -eq '' -or $b -eq '') { continue }
  $plain = ($d -replace '&#10;', '|') -replace '&amp;', '&'
  $found += [pscustomobject]@{ Desc = $plain; Bounds = $b }
}

if ($Dump -or $Label -eq '') {
  foreach ($f in $found) { Write-Host ("{0,-52} {1}" -f $f.Desc, $f.Bounds) }
  if ($Label -eq '') { exit 0 }
}

$hits = @($found | Where-Object { $_.Desc -like ('*' + $Label + '*') })
if ($hits.Count -eq 0) {
  Write-Host "NOT FOUND: $Label"
  foreach ($f in $found) { Write-Host ("  {0,-52} {1}" -f $f.Desc, $f.Bounds) }
  exit 2
}

$hit = $hits[[Math]::Min($Index, $hits.Count - 1)]
$g = [regex]::Match($hit.Bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
$x0 = [int]$g.Groups[1].Value; $y0 = [int]$g.Groups[2].Value
$x1 = [int]$g.Groups[3].Value; $y1 = [int]$g.Groups[4].Value
$cx = [int](($x0 + $x1) / 2)
$cy = [int](($y0 + $y1) / 2)

if ($Long -gt 0) {
  & $Adb shell input swipe $cx $cy $cx $cy $Long | Out-Null
  Write-Host ("LONG {0}ms  {1}  at {2},{3}" -f $Long, $hit.Desc, $cx, $cy)
} else {
  & $Adb shell input tap $cx $cy | Out-Null
  Write-Host ("TAP  {0}  at {1},{2}" -f $hit.Desc, $cx, $cy)
}
