<#
.SYNOPSIS
  Build the DSH Mobile Android APK from an ASCII-only path.

.DESCRIPTION
  Why this script exists: the Android Gradle Plugin refuses project paths that
  contain non-ASCII characters (this project lives under D:\新建文件夹\...):

      Your project path contains non-ASCII characters. This will most likely
      cause the build to fail on Windows. Please move your project to a
      different directory.

  `flutter analyze` breaks for the same reason (its analysis server LSP channel
  mis-parses the percent-encoded path: FormatException: Unterminated string).

  So: sources stay in the workspace, the build runs on an ASCII copy, and the
  APK is copied back into dist/.

  NOTE: deliberately no `$ErrorActionPreference = 'Stop'` — Flutter writes
  normal warnings to stderr ("Flutter assets will be downloaded from ..."),
  and with Stop that is raised as a fatal NativeCommandError before the build
  even starts. Exit codes are checked explicitly instead.

.PARAMETER Mode
  debug (default) or release.
#>
param(
  [ValidateSet('debug', 'release')]
  [string]$Mode = 'debug'
)

$Root       = Split-Path -Parent $PSScriptRoot          # dsh-mobile/
$Source     = Join-Path $Root 'app'
$Target     = 'D:\dev\build\app'
$Dist       = Join-Path $Root 'dist'
$Flutter    = 'D:\dev\flutter\bin'
$Jdk        = 'D:\dev\jdk\jdk-17.0.20.1+1'
$AndroidSdk = 'D:\dev\android-sdk'

if (-not (Test-Path (Join-Path $Flutter 'flutter.bat'))) { throw "Flutter not found: $Flutter" }
if (-not (Test-Path (Join-Path $Jdk 'bin\java.exe')))     { throw "JDK not found: $Jdk" }
if (-not (Test-Path $AndroidSdk))                          { throw "Android SDK not found: $AndroidSdk" }

# ---------- environment ----------
$env:Path = "$Flutter;$Jdk\bin;$AndroidSdk\platform-tools;$AndroidSdk\cmdline-tools\latest\bin;$env:Path"
$env:JAVA_HOME = $Jdk
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:GRADLE_USER_HOME = 'D:\dev\gradle-home'

function Step($text) { Write-Host "`n--- $text ---" -ForegroundColor Cyan }

Step "Sync sources to ASCII build dir"
Write-Host "  $Source -> $Target"
New-Item -ItemType Directory -Force -Path $Target | Out-Null
$null = robocopy $Source $Target /MIR /XD build .dart_tool .idea .gradle /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

Push-Location $Target
try {
  Step "flutter pub get"
  & "$Flutter\flutter.bat" pub get
  if ($LASTEXITCODE -ne 0) { throw "pub get failed: $LASTEXITCODE" }

  Step "flutter build apk --$Mode"
  & "$Flutter\flutter.bat" build apk "--$Mode"
  if ($LASTEXITCODE -ne 0) { throw "build failed: $LASTEXITCODE" }

  Step "Copy artifacts to dist/"
  New-Item -ItemType Directory -Force -Path $Dist | Out-Null
  $apks = Get-ChildItem (Join-Path $Target 'build\app\outputs\flutter-apk') -Filter *.apk -ErrorAction SilentlyContinue
  if (-not $apks) { throw "no APK produced" }
  foreach ($apk in $apks) {
    Copy-Item $apk.FullName (Join-Path $Dist $apk.Name) -Force
    Write-Host ("  {0}  {1:N1} MB" -f $apk.Name, ($apk.Length / 1MB)) -ForegroundColor Green
  }
  Write-Host "`nDONE. APK is in: $Dist" -ForegroundColor Green
}
finally {
  Pop-Location
}
