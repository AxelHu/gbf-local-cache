$ErrorActionPreference = 'Stop'

function Get-GBFRepoRoot {
    $resolved = Resolve-Path (Join-Path $PSScriptRoot '..')
    if ($resolved.ProviderPath) { return $resolved.ProviderPath }
    return $resolved.Path
}

function Read-GBFDotEnv {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }
        $parts = $line.Split('=', 2)
        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = [Environment]::ExpandEnvironmentVariables($value)
    }
    return $values
}

function Get-GBFNativeConfig {
    $repo = Get-GBFRepoRoot
    $fileValues = Read-GBFDotEnv (Join-Path $repo '.env.windows')

    function Pick([string]$Name, [string]$Default) {
        $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if ($null -ne $processValue) { return $processValue }
        if ($fileValues.ContainsKey($Name)) { return [string]$fileValues[$Name] }
        return [Environment]::ExpandEnvironmentVariables($Default)
    }

    $stateRoot = Pick 'GBF_WINDOWS_STATE_ROOT' '%LOCALAPPDATA%\GBFLocalCache'
    return [pscustomobject]@{
        RepoRoot = $repo
        StateRoot = $stateRoot
        CacheRoot = (Pick 'GBF_CACHE_ROOT' '%LOCALAPPDATA%\GBFLocalCache\cache\gbf')
        LegacyRoots = (Pick 'GBF_LEGACY_CACHE_ROOTS' '')
        FreshSeconds = [int](Pick 'GBF_CACHE_FRESH_SECONDS' '21600')
        ProxyPort = [int](Pick 'GBF_CACHE_PROXY_PORT' '18123')
        PacPort = [int](Pick 'GBF_CACHE_PAC_PORT' '18124')
        UpstreamProxy = (Pick 'GBF_UPSTREAM_PROXY' '')
        VenvRoot = (Join-Path $repo '.venv-windows')
        MitmConfRoot = (Join-Path $stateRoot 'mitmproxy')
        RuntimeFile = (Join-Path $stateRoot 'native-runtime.json')
    }
}

function Set-GBFProcessEnvironment {
    param($Config)
    $env:GBF_CACHE_ROOT = $Config.CacheRoot
    $env:GBF_LEGACY_CACHE_ROOTS = $Config.LegacyRoots
    $env:GBF_CACHE_FRESH_SECONDS = [string]$Config.FreshSeconds
    $env:GBF_CACHE_PROXY_PORT = [string]$Config.ProxyPort
    $env:GBF_CACHE_PAC_PORT = [string]$Config.PacPort
    $env:GBF_UPSTREAM_PROXY = $Config.UpstreamProxy
    $env:PYTHONPATH = $Config.RepoRoot
    $env:PYTHONUNBUFFERED = '1'
}

function Test-GBFTcpPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-GBFCompatiblePython {
    $candidates = @()
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($selector in @('-3', '-3.14', '-3.13', '-3.12')) {
            try {
                $version = & $py.Source $selector -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
                if ($LASTEXITCODE -eq 0 -and $version -match '^3\.(1[2-9]|[2-9][0-9])$') {
                    $exe = & $py.Source $selector -c "import sys; print(sys.executable)"
                    if ($LASTEXITCODE -eq 0 -and $exe) { return $exe.Trim() }
                }
            } catch {}
        }
    }
    foreach ($name in @('python.exe', 'python3.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
    }
    foreach ($exe in $candidates | Select-Object -Unique) {
        try {
            $ok = & $exe -c "import sys; raise SystemExit(0 if sys.version_info.major == 3 and sys.version_info.minor >= 12 else 1)"
            if ($LASTEXITCODE -eq 0) { return $exe }
        } catch {}
    }
    return $null
}

function Stop-GBFProcessTree {
    param([int]$PidValue)
    if ($PidValue -le 0) { return }
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PidValue" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-GBFProcessTree ([int]$child.ProcessId)
    }
    Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue
}

function Test-GBFOwnedProcess {
    param([int]$PidValue, [string]$RepoRoot)
    if ($PidValue -le 0) { return $false }
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction Stop
        if (-not $p) { return $false }
        $needle = $RepoRoot.ToLowerInvariant()
        return (($p.CommandLine -as [string]).ToLowerInvariant().Contains($needle))
    } catch {
        return $false
    }
}
