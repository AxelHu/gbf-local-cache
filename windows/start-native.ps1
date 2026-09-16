$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
. (Join-Path $PSScriptRoot 'native-common.ps1')

$cfg = Get-GBFNativeConfig
$compatPort = 0
if (-not [string]::IsNullOrWhiteSpace($cfg.AcgpowerCompatPacPort)) {
    if (-not [int]::TryParse($cfg.AcgpowerCompatPacPort, [ref]$compatPort) -or $compatPort -lt 1 -or $compatPort -gt 65535) {
        throw "Invalid GBF_ACGPOWER_COMPAT_PAC_PORT: $($cfg.AcgpowerCompatPacPort)"
    }
}
$mitmMode = if ([string]::IsNullOrWhiteSpace($cfg.UpstreamProxy)) {
    'regular'
} else {
    "upstream:$($cfg.UpstreamProxy)"
}
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
        $compatAlive = $compatPort -eq 0 -or (
            ($old.PSObject.Properties.Name -contains 'compat_pac_pid') -and
            (Test-GBFOwnedProcess ([int]$old.compat_pac_pid) $cfg.RepoRoot) -and
            (Test-GBFTcpPort $compatPort)
        )
        if ((Test-GBFOwnedProcess ([int]$old.pac_pid) $cfg.RepoRoot) -and
            (Test-GBFOwnedProcess ([int]$old.mitm_pid) $cfg.RepoRoot) -and
            (Test-GBFTcpPort $cfg.PacPort) -and (Test-GBFTcpPort $cfg.ProxyPort) -and $compatAlive) {
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
if ($compatPort -ne 0) {
    if ($compatPort -eq $cfg.ProxyPort -or $compatPort -eq $cfg.PacPort) {
        throw "Compatibility PAC port $compatPort conflicts with the main GBF cache ports."
    }
    if (Test-GBFTcpPort $compatPort) {
        throw "Compatibility PAC port $compatPort is already in use."
    }
}

$pacOut = Join-Path $cfg.StateRoot 'pac.out.log'
$pacErr = Join-Path $cfg.StateRoot 'pac.err.log'
$mitmOut = Join-Path $cfg.StateRoot 'mitm.out.log'
$mitmErr = Join-Path $cfg.StateRoot 'mitm.err.log'
$quotedBrowserFallback = '"' + $cfg.BrowserFallbackProxy.Replace('"', '\"') + '"'

$pac = Start-Process -FilePath $python -ArgumentList @(
    (Join-Path $cfg.RepoRoot 'tools\pac_server.py'), '--host', '127.0.0.1',
    '--port', [string]$cfg.PacPort, '--proxy-port', [string]$cfg.ProxyPort,
    '--browser-fallback', $quotedBrowserFallback
) -WindowStyle Hidden -PassThru -RedirectStandardOutput $pacOut -RedirectStandardError $pacErr

$compatPac = $null
if ($compatPort -ne 0) {
    $compatOut = Join-Path $cfg.StateRoot 'compat-pac.out.log'
    $compatErr = Join-Path $cfg.StateRoot 'compat-pac.err.log'
    $compatPac = Start-Process -FilePath $python -ArgumentList @(
        (Join-Path $cfg.RepoRoot 'tools\pac_server.py'), '--host', '127.0.0.1',
        '--port', [string]$compatPort, '--proxy-port', [string]$cfg.ProxyPort,
        '--browser-fallback', $quotedBrowserFallback, '--root-browser-pac'
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $compatOut -RedirectStandardError $compatErr
}

try {
    $mitm = Start-Process -FilePath $mitmdump -ArgumentList @(
        '--mode', $mitmMode, '--listen-host', '127.0.0.1', '--listen-port', [string]$cfg.ProxyPort,
        '--set', "confdir=$($cfg.MitmConfRoot)", '--set', 'connection_strategy=lazy',
        '--set', 'flow_detail=0', '-s', (Join-Path $cfg.RepoRoot 'gbf_cache\addon.py')
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $mitmOut -RedirectStandardError $mitmErr
} catch {
    if ($compatPac) { Stop-GBFProcessTree ([int]$compatPac.Id) }
    Stop-GBFProcessTree ([int]$pac.Id)
    throw
}

$runtime = [pscustomobject]@{
    pac_pid = $pac.Id
    compat_pac_pid = if ($compatPac) { $compatPac.Id } else { 0 }
    mitm_pid = $mitm.Id
    repo = $cfg.RepoRoot
    proxy_port = $cfg.ProxyPort
    pac_port = $cfg.PacPort
    started_at = (Get-Date).ToUniversalTime().ToString('o')
}
$runtime | ConvertTo-Json | Set-Content -Encoding UTF8 $cfg.RuntimeFile

$ready = $false
for ($i = 0; $i -lt 80; $i++) {
    if ($pac.HasExited -or $mitm.HasExited -or ($compatPac -and $compatPac.HasExited)) { break }
    if ((Test-GBFTcpPort $cfg.PacPort) -and (Test-GBFTcpPort $cfg.ProxyPort) -and
        ($compatPort -eq 0 -or (Test-GBFTcpPort $compatPort))) {
        $ready = $true
        break
    }
    Start-Sleep -Milliseconds 100
}

if (-not $ready) {
    Stop-GBFProcessTree ([int]$mitm.Id)
    if ($compatPac) { Stop-GBFProcessTree ([int]$compatPac.Id) }
    Stop-GBFProcessTree ([int]$pac.Id)
    Remove-Item $cfg.RuntimeFile -Force -ErrorAction SilentlyContinue
    Write-Host 'PAC stderr:'; Get-Content $pacErr -Tail 30 -ErrorAction SilentlyContinue
    if ($compatPac) { Write-Host 'compat PAC stderr:'; Get-Content $compatErr -Tail 30 -ErrorAction SilentlyContinue }
    Write-Host 'mitmproxy stderr:'; Get-Content $mitmErr -Tail 50 -ErrorAction SilentlyContinue
    throw 'Native GBF cache failed to become ready.'
}

Write-Host "started native Windows cache: proxy=$($cfg.ProxyPort) pac=$($cfg.PacPort)"
if ($compatPort -ne 0) { Write-Host "ACGPower compatibility PAC: http://127.0.0.1:$compatPort/proxy.pac" }
Write-Host "primary cache: $($cfg.CacheRoot)"
if ($cfg.UpstreamProxy) { Write-Host 'cache miss upstream: configured' }
