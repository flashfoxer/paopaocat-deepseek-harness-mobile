# Build ONLY the arm64 real-device release APK, then verify the DELIVERABLE.
#
# Why this file was rewritten (2026-10-09):
#   It used to look for `dist\dsh-local-arm64-v8a-app-release.apk`. That name has
#   not been produced since build-local-apk.ps1 was unified onto
#   `paopaocat-preview-<version>-<abi>.apk` (2026-10-04). So the gate printed
#   "FAIL: arm64 apk not produced" **even when the build had succeeded** -- and
#   nobody ran it again (last docs\logs\build-arm64.log is 2026-10-04, while
#   0.50..0.57 all shipped after that). A verifier that is wrong is worse than
#   none: it trains people to ignore the red light.
#
# Now: locate the artifact by the CURRENT name shape, then hand it to
# install\check-release.py, which only trusts the BYTES inside the package.
#
# RULE: this file must stay 100% PURE ASCII. Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI, so ANY non-ASCII byte in here (e.g. a hard-coded
# Chinese workspace path) gets mangled into garbage. That is exactly how the
# first run of this script failed:
#     D:\?????\?????\...\install\build-local-apk.ps1  -> CommandNotFoundException
# So derive every path at runtime instead of writing it down.
#
# Run:  powershell -File install\rebuild-and-verify.ps1
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot          # <project>\install -> <project>
$logs = Join-Path $root 'docs\logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Step($m) { Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

Step ('project root = ' + $root)

# ---- version comes from the same single source of truth as the packer ----
$VersionFile = Join-Path $root 'app\lib\app_version.dart'
$AppVersion = ''
if (Test-Path $VersionFile) {
    $vm = Select-String -Path $VersionFile -Pattern "kAppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($vm) { $AppVersion = $vm.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($AppVersion)) { Step 'FAIL: cannot read kAppVersion'; exit 1 }

$builder = Join-Path $root 'install\build-local-apk.ps1'
if (-not (Test-Path $builder)) { Step 'FAIL: build-local-apk.ps1 not found'; exit 1 }

# ---- node-side tests (credential boundary + storage discipline) ----
# These guard things `flutter test` CANNOT see, because they live in node
# scripts: the exec shim's shell env allowlist, the rotation proxy's client
# token, and the bridge's device store. All of them fail SILENTLY when broken
# (the app/bridge still runs, it just leaks keys or wipes data again).
# So they must be a gate here, before packing.
# Runs EVERY install\test-*.mjs - adding a new test needs no change to this file.
$nodeTests = @(Get-ChildItem (Join-Path $root 'install') -Filter 'test-*.mjs' -ErrorAction SilentlyContinue)
if ($nodeTests.Count -eq 0) {
    Step 'WARN: no install\test-*.mjs found - node-side boundaries untested'
} else {
    $node = 'node'
    $nodeLog = Join-Path $logs 'test-node.log'
    foreach ($t in $nodeTests) {
        Step ('go: ' + $t.Name)
        & $node $t.FullName 2>&1 | Tee-Object -FilePath $nodeLog -Append
        if ($LASTEXITCODE -ne 0) {
            Step ('FAIL: ' + $t.Name + ' failed (exit ' + $LASTEXITCODE + ') - DO NOT SHIP')
            exit 1
        }
    }
}

# ---- i18n drift check (P0-11) ----
# The three translation tables' headers always said "run check-tables after
# editing" -- and that script DID NOT EXIST, which is how drift grew to
# 48 missing / 77 stale entries (switching language silently shows Chinese).
# It also catches values that lost their newlines (a visible literal \n).
$i18nCheck = Join-Path $root 'install\i18n\check-tables.mjs'
if (Test-Path $i18nCheck) {
    $node = 'node'
    Step 'go: i18n check-tables.mjs (source <-> tables)'
    & $node $i18nCheck 2>&1 | Tee-Object -FilePath (Join-Path $logs 'i18n-check.log')
    if ($LASTEXITCODE -ne 0) {
        Step ('FAIL: i18n tables drifted from source (exit ' + $LASTEXITCODE + ')')
        Step '      Run: node install\i18n\rewrite-tables.mjs  (after adding translations)'
        exit 1
    }
} else {
    Step 'WARN: install\i18n\check-tables.mjs not found - i18n drift unchecked'
}

Step ('go: arm64-v8a release build (version ' + $AppVersion + ')')
Push-Location $root
# build-local-apk.ps1 already runs the post-build check itself and throws on FAIL.
& $builder -Abi arm64-v8a -Mode release 2>&1 |
    Tee-Object -FilePath (Join-Path $logs 'build-arm64.log')
$buildExit = $LASTEXITCODE
Pop-Location

# ---- locate the artifact by the CURRENT name shape ----
$arm = Join-Path $root ('dist\paopaocat-preview-' + $AppVersion + '-arm64-v8a.apk')
if (-not (Test-Path $arm)) {
    Step 'FAIL: arm64 apk not produced (see docs\logs\build-arm64.log)'
    Step ('      expected: ' + $arm)
    exit 1
}

$a = Get-Item $arm
Step ('arm64 apk = ' + $a.Length + ' bytes @ ' + $a.LastWriteTime)
Step ('arm64 sha256 = ' + (Get-FileHash $arm -Algorithm SHA256).Hash)

# ---- the real gate: bytes inside the package, not the source tree ----
$checker = Join-Path $PSScriptRoot 'check-release.py'
$py = 'C:\Python314\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }
Step 'go: check-release.py (deliverable == tested thing)'
& $py $checker $arm '--repo' $root
$checkExit = $LASTEXITCODE

if ($checkExit -ne 0) {
    Step ('FAIL: release check failed (exit ' + $checkExit + ')')
    exit 1
}
if ($buildExit -ne 0) {
    Step ('WARN: build returned exit ' + $buildExit + ' but the artifact checks out')
}

Step 'DONE - the package in dist\ matches this source tree'
