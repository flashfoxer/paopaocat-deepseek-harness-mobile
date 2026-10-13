<#
.SYNOPSIS
  Generate a self-signed TLS certificate for the bridge (wss support).

.DESCRIPTION
  Why this exists: the bridge speaks plain `ws://` today. For any network that is
  not already private (Tailscale counts as private; open Wi-Fi does not), the
  connection must be TLS. Since terminals here are PowerShell 5.1 on .NET Framework,
  the modern RSA.ExportPkcs8PrivateKey() API is unavailable, so we export a PFX
  instead - Node's https/tls supports PFX directly.

  This script is deliberately ASCII-only: PowerShell 5.1 reads .ps1 files as ANSI
  unless they carry a BOM, and non-ASCII comments break parsing.

  The app pins the SHA-256 fingerprint; do NOT install this certificate into the
  system trust store.
#>
param(
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\tls'),
  [string]$PfxPassword = 'dsh-mobile-bridge'
)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cert = New-SelfSignedCertificate `
  -Subject 'CN=dsh-mobile-bridge' `
  -DnsName 'localhost', '127.0.0.1' `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -NotAfter (Get-Date).AddYears(10) `
  -KeyExportPolicy Exportable `
  -KeyAlgorithm RSA `
  -KeyLength 2048 `
  -HashAlgorithm SHA256

$secure = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
$pfxPath = Join-Path $OutDir 'bridge.pfx'
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secure | Out-Null

$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)
$fingerprint = ($hash | ForEach-Object { $_.ToString('X2') }) -join ':'

# Also write the public certificate as PEM: handy for `ca:` in test clients,
# for browsers during manual debugging, and for any non-Node consumer.
$certB64 = [Convert]::ToBase64String($cert.RawData, [Base64FormattingOptions]::InsertLineBreaks)
$certPem = "-----BEGIN CERTIFICATE-----`n$certB64`n-----END CERTIFICATE-----`n"
Set-Content -Path (Join-Path $OutDir 'bridge-cert.pem') -Value $certPem -Encoding ascii

# Leave the machine clean - the PFX is self-contained and the private key
# should not linger in the user's certificate store.
Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue

Set-Content -Path (Join-Path $OutDir 'fingerprint.txt') -Value $fingerprint -Encoding ascii

Write-Output "PFX written   : $pfxPath"
Write-Output "PFX password  : $PfxPassword"
Write-Output "SHA-256 fingerprint (pin this in the app):"
Write-Output "  $fingerprint"
