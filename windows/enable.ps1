$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$PacUrl = 'http://127.0.0.1:18124/proxy.pac'
$StateDir = Join-Path $env:LOCALAPPDATA 'GBFLocalCache'
$Backup = Join-Path $StateDir 'internet-settings-backup.json'
$CertPath = 'F:\Programs\gbf-local-cache\mitmproxy-ca-cert.cer'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri $PacUrl | Out-Null
} catch {
    throw "GBF local cache PAC server is not reachable at $PacUrl. Start the WSL service first."
}

if (-not (Test-Path $CertPath)) {
    throw "CA certificate not found: $CertPath"
}
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
$trusted = Get-ChildItem Cert:\CurrentUser\Root | Where-Object Thumbprint -eq $cert.Thumbprint
if (-not $trusted) {
    # Import-Certificate can surface a GUI trust prompt when adding a root CA.
    # certutil with -f performs the same CurrentUser store update non-interactively.
    & "$env:SystemRoot\System32\certutil.exe" -addstore -f -user Root $CertPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "certutil failed to install the GBF local cache CA (exit=$LASTEXITCODE)"
    }
    Write-Host "Installed GBF local cache CA into CurrentUser Trusted Root: $($cert.Thumbprint)"
}

$current = Get-ItemProperty $RegPath
if (-not (Test-Path $Backup)) {
    [pscustomobject]@{
        HadAutoConfigURL = ($null -ne $current.AutoConfigURL)
        AutoConfigURL = $current.AutoConfigURL
    } | ConvertTo-Json | Set-Content -Encoding UTF8 $Backup
}

# Leave ProxyEnable/ProxyServer untouched. Only automatic configuration changes.
Set-ItemProperty -Path $RegPath -Name AutoConfigURL -Value $PacUrl

if (-not ('WinInetSettings' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinInetSettings {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
}
[WinInetSettings]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinInetSettings]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null

Write-Host "Enabled GBF-only PAC: $PacUrl"
Write-Host "All non-GBF-static hosts return DIRECT; GBF static CDN uses local proxy with DIRECT fallback."
