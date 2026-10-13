<#
.SYNOPSIS
  在 ASCII 路径下运行 App 的端到端集成测试（需要桥已在本机运行）。

.DESCRIPTION
  与 build-apk.ps1 同样的理由：源码在工作区（非 ASCII 路径），
  但 flutter 工具链需要 ASCII 路径才能稳定工作。

  前置：另开一个终端运行
      node dsh-mobile\bridge\src\bridge.mjs serve
#>
param(
  [string]$TestFile = 'test/bridge_integration_test.dart'
)

$Root       = Split-Path -Parent $PSScriptRoot
$Source     = Join-Path $Root 'app'
$Target     = 'D:\dev\build\app'
$Flutter    = 'D:\dev\flutter\bin'
$Jdk        = 'D:\dev\jdk\jdk-17.0.20.1+1'

$env:Path = "$Flutter;$Jdk\bin;$env:Path"
$env:JAVA_HOME = $Jdk
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

Write-Host "`n--- Sync sources ---" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $Target | Out-Null
$null = robocopy $Source $Target /MIR /XD build .dart_tool .idea .gradle /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

Push-Location $Target
try {
  Write-Host "`n--- flutter pub get ---" -ForegroundColor Cyan
  & "$Flutter\flutter.bat" pub get
  if ($LASTEXITCODE -ne 0) { throw "pub get failed: $LASTEXITCODE" }

  Write-Host "`n--- flutter test $TestFile ---" -ForegroundColor Cyan
  & "$Flutter\flutter.bat" test $TestFile
  $code = $LASTEXITCODE
  Write-Host "`nTEST_EXIT=$code"
  exit $code
}
finally {
  Pop-Location
}
