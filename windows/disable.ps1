param(
    [switch]$RemoveCertificate,
    [string]$PacUrl = 'http://127.0.0.1:18124/proxy.pac',
    [string]$CertPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$StateDir = Join-Path $env:LOCALAPPDATA 'GBFLocalCache'
$Backup = Join-Path $StateDir 'internet-settings-backup.json'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$current = Get-ItemProperty $RegPath

if (-not $CertPath) {
    $portableCopy = Join-Path $StateDir 'mitmproxy-ca-cert.cer'
    $nativeCert = Join-Path $StateDir 'mitmproxy\mitmproxy-ca-cert.cer'
    if (Test-Path $portableCopy) { $CertPath = $portableCopy }
    elseif (Test-Path $nativeCert) { $CertPath = $nativeCert }
    else { $CertPath = $portableCopy }
}

if ($current.AutoConfigURL -eq $PacUrl) {
    if (Test-Path $Backup) {
        $old = Get-Content -Raw $Backup | ConvertFrom-Json
        if ($old.HadAutoConfigURL -and $null -ne $old.AutoConfigURL) {
            Set-ItemProperty -Path $RegPath -Name AutoConfigURL -Value ([string]$old.AutoConfigURL)
        } else {
            Remove-ItemProperty -Path $RegPath -Name AutoConfigURL -ErrorAction SilentlyContinue
        }
    } else {
        Remove-ItemProperty -Path $RegPath -Name AutoConfigURL -ErrorAction SilentlyContinue
    }
}

if ($RemoveCertificate -and (Test-Path $CertPath)) {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
    Get-ChildItem Cert:\CurrentUser\Root | Where-Object Thumbprint -eq $cert.Thumbprint | Remove-Item -Force
    Write-Host "Removed GBF local cache CA: $($cert.Thumbprint)"
}

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
Write-Host "GBF-only PAC disabled/restored."
