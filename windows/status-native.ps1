$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
. (Join-Path $PSScriptRoot 'native-common.ps1')

$cfg = Get-GBFNativeConfig
$compatPort = 0
if (-not [string]::IsNullOrWhiteSpace($cfg.AcgpowerCompatPacPort)) { [void][int]::TryParse($cfg.AcgpowerCompatPacPort, [ref]$compatPort) }
$running = $false
if (Test-Path $cfg.RuntimeFile) {
    try {
        $runtime = Get-Content -Raw $cfg.RuntimeFile | ConvertFrom-Json
        $compatRunning = $compatPort -eq 0 -or (
            ($runtime.PSObject.Properties.Name -contains 'compat_pac_pid') -and
            (Test-GBFOwnedProcess ([int]$runtime.compat_pac_pid) $cfg.RepoRoot) -and
            (Test-GBFTcpPort $compatPort)
        )
        $running = (Test-GBFOwnedProcess ([int]$runtime.pac_pid) $cfg.RepoRoot) -and
                   (Test-GBFOwnedProcess ([int]$runtime.mitm_pid) $cfg.RepoRoot) -and
                   (Test-GBFTcpPort $cfg.PacPort) -and (Test-GBFTcpPort $cfg.ProxyPort) -and $compatRunning
        if ($running) {
            Write-Host "running pac=$($runtime.pac_pid) mitm=$($runtime.mitm_pid)"
        }
    } catch {}
}
if (-not $running) { Write-Host 'stopped' }
Write-Host "proxy=127.0.0.1:$($cfg.ProxyPort) pac=http://127.0.0.1:$($cfg.PacPort)/proxy.pac"
if ($compatPort -ne 0) { Write-Host "acgpower-compat=http://127.0.0.1:$compatPort/proxy.pac" }
Write-Host "primary=$($cfg.CacheRoot)"
if ($cfg.LegacyRoots) { Write-Host "legacy=$($cfg.LegacyRoots)" }
