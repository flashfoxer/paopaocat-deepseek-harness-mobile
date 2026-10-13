<#
.SYNOPSIS
  Build the on-device (local) DSH APK.

.DESCRIPTION
  Differences from build-apk.ps1 (the remote-client build):
    - ships only ONE ABI (~93 MB of native libs each) via the dshAbi gradle property
    - passes --target-platform so the Flutter engine matches that ABI
    - runtime assets/jniLibs live outside the source tree; build.gradle.kts points at
      D:\dev\android-node\... (see its sourceSets block)

  Prerequisites (checked below):
    1. D:\dev\android-node\app-assets\dsh-runtime.zip   (DSH tree + shims)
    2. D:\dev\android-node\jnilibs\<abi>\libnode.so      (node + its libraries)

  IMPORTANT: this file must stay ASCII-only.
  PowerShell 5.1 reads .ps1 as ANSI unless the file has a BOM; non-ASCII comments
  then decode into stray quote characters and silently break later lines (this
  script previously produced an empty string for a path interpolation because of
  exactly that).
#>
param(
  [ValidateSet('x86_64', 'arm64-v8a')]
  [string]$Abi = 'arm64-v8a',

  [ValidateSet('debug', 'release')]
  [string]$Mode = 'debug',

  # Skip the post-build release check (it runs by default -- the check is a
  # release gate and should not be bypassed casually). Only useful when the
  # local checker has already been run via install\test_check_release.py.
  [switch]$SkipVerify
)

$Root    = Split-Path -Parent $PSScriptRoot
$Source  = Join-Path $Root 'app'
$Target  = 'D:\dev\build\app-local'
$Dist    = Join-Path $Root 'dist'
$Flutter = 'D:\dev\flutter\bin'
$Jdk     = 'D:\dev\jdk\jdk-17.0.20.1+1'
$Sdk     = 'D:\dev\android-sdk'

# ---- Release name: read the version from app_version.dart (single source of truth) ----
# User requirement (2026-10-04): the packaged artifact name must be unified as
# "paopaocat preview + version". So we read kAppVersion (the very same string the
# home page / About page shows) and emit exactly one name shape:
#     paopaocat-preview-<version>-<abi>[-debug].apk
# The old mixed names (dsh-local-*, app-release.apk) are gone on purpose.
# NOTE: keep this file ASCII-only. PowerShell 5.1 mis-reads BOM-less UTF-8 files
# that contain CJK text, which used to break these scripts.
$VersionFile = Join-Path $Source 'lib\app_version.dart'
$AppVersion  = ''
if (Test-Path $VersionFile) {
  $vm = Select-String -Path $VersionFile -Pattern "kAppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
  if ($vm) { $AppVersion = $vm.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($AppVersion)) {
  throw "Cannot read app version: no kAppVersion match in $VersionFile"
}
$Suffix = if ($Mode -eq 'release') { '' } else { '-debug' }
$BaseName = "paopaocat-preview-$AppVersion-$Abi$Suffix"
Write-Host "Package name  : $BaseName.apk" -ForegroundColor Cyan

# Cross-check pubspec version against kAppVersion (warning only, never blocks a build):
# if they drift, the installed versionName and the version shown in the UI disagree.
$PubspecFile = Join-Path $Source 'pubspec.yaml'
if (Test-Path $PubspecFile) {
  $pm = Select-String -Path $PubspecFile -Pattern '^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)' | Select-Object -First 1
  if ($pm) {
    $g = $pm.Matches[0].Groups
    $pubDisplay = '{0}.{1}{2}' -f $g[1].Value, $g[2].Value, $g[3].Value
    if ($pubDisplay -ne $AppVersion) {
      Write-Host "WARN pubspec version ($pubDisplay) != kAppVersion ($AppVersion)" -ForegroundColor Yellow
    }
    # versionCode must increase every release or Android refuses to overwrite-install.
    # Convention: display 0.09 -> versionCode 9 (drop the dot, parse as int).
    $expectedCode = 0
    if ([int]::TryParse(($AppVersion -replace '\.', ''), [ref]$expectedCode)) {
      if ([int]$g[4].Value -ne $expectedCode) {
        Write-Host "WARN versionCode=$($g[4].Value) does not match version $AppVersion (expected $expectedCode)" -ForegroundColor Yellow
      }
    }
  }
}

$AssetZip = 'D:\dev\android-node\app-assets\dsh-runtime.zip'
$JniDir   = Join-Path 'D:\dev\android-node\jnilibs' $Abi

# Resolve these before Push-Location; keeps behaviour independent of the current dir.
$GradleProps = Join-Path $Target 'android\gradle.properties'
$GradlewBat  = Join-Path $Target 'android\gradlew.bat'

$targetPlatform = if ($Abi -eq 'x86_64') { 'android-x64' } else { 'android-arm64' }

# ---- preflight ----
if (-not (Test-Path $AssetZip)) {
  throw "Missing runtime zip: $AssetZip`nRun: install\build-app-assets.ps1"
}
if (-not (Test-Path (Join-Path $JniDir 'libnode.so'))) {
  throw "Missing jniLibs for $Abi : $JniDir`nRun: install\prepare-jnilibs.mjs $Abi"
}

$env:Path = "$Flutter;$Jdk\bin;$Sdk\platform-tools;$Sdk\cmdline-tools\latest\bin;$env:Path"
$env:JAVA_HOME = $Jdk
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:GRADLE_USER_HOME = 'D:\dev\gradle-home'

function Step($text) { Write-Host "`n--- $text ---" -ForegroundColor Cyan }

Step "Sync sources to ASCII build dir"
Write-Host ("  {0} -> {1}" -f $Source, $Target)
New-Item -ItemType Directory -Force -Path $Target | Out-Null
$null = robocopy $Source $Target /MIR /XD build .dart_tool .idea .gradle /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

# Write the target ABI into gradle.properties.
# Why not an environment variable: the Gradle daemon caches its process environment,
# so ORG_GRADLE_PROJECT_dshAbi is not re-read when the daemon is reused, and the
# default ABI silently wins.
$kept = @(Get-Content -Path $GradleProps | Where-Object { $_ -notmatch '^\s*dshAbi\s*=' })
$kept += "dshAbi=$Abi"
Set-Content -Path $GradleProps -Value $kept -Encoding ascii
Write-Host "  gradle.properties: dshAbi=$Abi"

# Stop any leftover daemon so the next build definitely reads the new property.
if (Test-Path $GradlewBat) { & $GradlewBat --stop 2>&1 | Out-Null }

Push-Location $Target
try {
  Step "flutter pub get"
  & "$Flutter\flutter.bat" pub get
  if ($LASTEXITCODE -ne 0) { throw "pub get failed" }

  Step "flutter build apk --$Mode  (abi=$Abi, target=$targetPlatform)"
  Write-Host ("  assets: {0:N1} MB   jniLibs: {1:N1} MB" -f `
    ((Get-Item $AssetZip).Length / 1MB), `
    ((Get-ChildItem $JniDir | Measure-Object Length -Sum).Sum / 1MB))

  # Clear previous outputs first: the flutter-apk folder keeps leftovers from earlier
  # builds, and blindly copying "*.apk" once produced a file NAMED arm64 that actually
  # contained x86_64 native libs.
  Remove-Item -Recurse -Force (Join-Path $Target 'build\app\outputs\flutter-apk') -ErrorAction SilentlyContinue

  & "$Flutter\flutter.bat" build apk "--$Mode" "--target-platform" $targetPlatform
  if ($LASTEXITCODE -ne 0) { throw "build failed" }

  Step "Copy artifacts to dist/"
  New-Item -ItemType Directory -Force -Path $Dist | Out-Null

  # Move artifacts from the old naming scheme aside so dist/ shows one name style
  # (the user asked for a single unified package name). Move, never delete: the
  # previously delivered dsh-local-* release package must stay retrievable.
  $oldDir = Join-Path $Dist '_old-names'
  foreach ($pattern in @('dsh-local-*.apk', 'app-*.apk')) {
    Get-ChildItem $Dist -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
      New-Item -ItemType Directory -Force -Path $oldDir | Out-Null
      Move-Item $_.FullName (Join-Path $oldDir $_.Name) -Force
      Write-Host "  moved old-named: $($_.Name) -> _old-names\"
    }
  }

  # Only take the artifact this invocation produced.
  $apks = Get-ChildItem (Join-Path $Target 'build\app\outputs\flutter-apk') -Filter "app-$Mode.apk" -ErrorAction SilentlyContinue
  if (-not $apks) { throw "no APK produced for mode=$Mode" }
  foreach ($apk in $apks) {
    $dest = Join-Path $Dist "$BaseName.apk"
    Copy-Item $apk.FullName $dest -Force
    Write-Host ("  {0}  {1:N1} MB" -f (Split-Path $dest -Leaf), ($apk.Length / 1MB)) -ForegroundColor Green
  }

  # ---- Post-build release check (P0-1): the deliverable must BE the tested thing ----
  # This is where 0.57 shipped broken: libapp.so was missing one string
  # (open-app.mjs), all 273 tests were green, and "open an app on the phone" was
  # NOTE: that feature (and open-app.mjs) was removed on 2026-10-10 by request.
  # dead on the device. The check trusts only the BYTES inside the package --
  # not the source tree, not the existing tests, not anyone's judgement.
  if ($SkipVerify) {
    Write-Host "`n[SKIP] post-build release check skipped (-SkipVerify)" -ForegroundColor Yellow
  } else {
    $checker = Join-Path $PSScriptRoot 'check-release.py'
    if (-not (Test-Path $checker)) { throw "Missing release checker: $checker" }
    $py = 'C:\Python314\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Host "`n--- post-build release check (check-release.py) ---" -ForegroundColor Cyan
    & $py $checker $dest '--repo' $Root
    if ($LASTEXITCODE -ne 0) {
      throw ("Post-build release check FAILED (exit $LASTEXITCODE): DO NOT SHIP this package.`n" +
             "  package: $dest`n" +
             "  See the FAIL items above. After fixing the source you MUST rebuild --`n" +
             "  the check re-runs only on a fresh package.")
    }
  }

  Write-Host "`nDone. APK in: $Dist" -ForegroundColor Green
}
finally {
  Pop-Location
}
