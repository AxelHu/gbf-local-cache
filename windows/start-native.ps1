$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
. (Join-Path $PSScriptRoot 'native-common.ps1')

$cfg = Get-GBFNativeConfig
$python = Join-Path $cfg.VenvRoot 'Scripts\python.exe'
$mitmdump = Join-Path $cfg.VenvRoot 'Scripts\mitmdump.exe'
if (-not (Test-Path $python) -or -not (Test-Path $mitmdump)) {
    throw 'Windows native venv is missing. Run windows\install-native.ps1 first.'
}

New-Item -ItemType Directory -Force -Path $cfg.StateRoot, $cfg.MitmConfRoot, $cfg.CacheRoot | Out-Null
Set-GBFProcessEnvironment $cfg

if (Test-Path $cfg.RuntimeFile) {
    try {
        $old = Get-Content -Raw $cfg.RuntimeFile | ConvertFrom-Json
        if ((Test-GBFOwnedProcess ([int]$old.pac_pid) $cfg.RepoRoot) -and
            (Test-GBFOwnedProcess ([int]$old.mitm_pid) $cfg.RepoRoot) -and
            (Test-GBFTcpPort $cfg.PacPort) -and (Test-GBFTcpPort $cfg.ProxyPort)) {
            Write-Host "already running pac=$($old.pac_pid) mitm=$($old.mitm_pid)"
            return
        }
    } catch {}
    Remove-Item $cfg.RuntimeFile -Force -ErrorAction SilentlyContinue
}

foreach ($port in @($cfg.ProxyPort, $cfg.PacPort)) {
    if (Test-GBFTcpPort $port) {
        throw "Port $port is already in use. Stop the WSL/native GBF cache instance or change ports in .env.windows."
    }
}

$pacOut = Join-Path $cfg.StateRoot 'pac.out.log'
$pacErr = Join-Path $cfg.StateRoot 'pac.err.log'
$mitmOut = Join-Path $cfg.StateRoot 'mitm.out.log'
$mitmErr = Join-Path $cfg.StateRoot 'mitm.err.log'

$pac = Start-Process -FilePath $python -ArgumentList @(
    (Join-Path $cfg.RepoRoot 'tools\pac_server.py'), '--host', '127.0.0.1',
    '--port', [string]$cfg.PacPort, '--proxy-port', [string]$cfg.ProxyPort
) -WindowStyle Hidden -PassThru -RedirectStandardOutput $pacOut -RedirectStandardError $pacErr

try {
    $mitm = Start-Process -FilePath $mitmdump -ArgumentList @(
        '--mode', 'regular', '--listen-host', '127.0.0.1', '--listen-port', [string]$cfg.ProxyPort,
        '--set', "confdir=$($cfg.MitmConfRoot)", '--set', 'connection_strategy=lazy',
        '--set', 'flow_detail=0', '-s', (Join-Path $cfg.RepoRoot 'gbf_cache\addon.py')
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $mitmOut -RedirectStandardError $mitmErr
} catch {
    Stop-Process -Id $pac.Id -Force -ErrorAction SilentlyContinue
    throw
}

$runtime = [pscustomobject]@{
    pac_pid = $pac.Id
    mitm_pid = $mitm.Id
    repo = $cfg.RepoRoot
    proxy_port = $cfg.ProxyPort
    pac_port = $cfg.PacPort
    started_at = (Get-Date).ToUniversalTime().ToString('o')
}
$runtime | ConvertTo-Json | Set-Content -Encoding UTF8 $cfg.RuntimeFile

$ready = $false
for ($i = 0; $i -lt 80; $i++) {
    if ($pac.HasExited -or $mitm.HasExited) { break }
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Uri "http://127.0.0.1:$($cfg.PacPort)/proxy.pac" | Out-Null
        if (Test-GBFTcpPort $cfg.ProxyPort) { $ready = $true; break }
    } catch {}
    Start-Sleep -Milliseconds 100
}

if (-not $ready) {
    Stop-Process -Id $pac.Id, $mitm.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $cfg.RuntimeFile -Force -ErrorAction SilentlyContinue
    Write-Host 'PAC stderr:'; Get-Content $pacErr -Tail 30 -ErrorAction SilentlyContinue
    Write-Host 'mitmproxy stderr:'; Get-Content $mitmErr -Tail 50 -ErrorAction SilentlyContinue
    throw 'Native GBF cache failed to become ready.'
}

Write-Host "started native Windows cache: proxy=$($cfg.ProxyPort) pac=$($cfg.PacPort)"
Write-Host "primary cache: $($cfg.CacheRoot)"
