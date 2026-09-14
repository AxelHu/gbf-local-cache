param([switch]$InstallPython)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
. (Join-Path $PSScriptRoot 'native-common.ps1')

$cfg = Get-GBFNativeConfig
$repoFull = [System.IO.Path]::GetFullPath($cfg.RepoRoot)
if ($repoFull.StartsWith('\\')) {
    throw 'Native Windows deployment requires the repository on a Windows local drive (for example C:\src\gbf-local-cache), not a \\wsl.localhost\... UNC path. Clone/copy the repo to Windows and rerun.'
}
$python = Get-GBFCompatiblePython

if (-not $python -and $InstallPython) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Python 3.12+ is missing and winget is unavailable. Install Python 3.12+ manually, then rerun.'
    }
    Write-Host 'Installing Python 3.12 for the current user via winget...'
    & $winget.Source install --id Python.Python.3.12 -e --scope user --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget Python install failed (exit=$LASTEXITCODE)" }
    $python = Get-GBFCompatiblePython
    if (-not $python) {
        $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
        if (Test-Path $fallback) { $python = $fallback }
    }
}

if (-not $python) {
    throw 'Python 3.12+ is required. Install it, or rerun with -InstallPython (requires winget).'
}

if (-not (Test-Path (Join-Path $cfg.RepoRoot '.env.windows'))) {
    Copy-Item (Join-Path $cfg.RepoRoot '.env.windows.example') (Join-Path $cfg.RepoRoot '.env.windows')
    Write-Host 'Created .env.windows from the example; review legacy cache paths if needed.'
}

if (-not (Test-Path (Join-Path $cfg.VenvRoot 'Scripts\python.exe'))) {
    Write-Host "Creating Windows venv with $python"
    & $python -m venv $cfg.VenvRoot
    if ($LASTEXITCODE -ne 0) { throw 'venv creation failed' }
}

$venvPython = Join-Path $cfg.VenvRoot 'Scripts\python.exe'
& $venvPython -m pip install --disable-pip-version-check -r (Join-Path $cfg.RepoRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'dependency installation failed' }

& (Join-Path $PSScriptRoot 'start-native.ps1')

$ca = Join-Path $cfg.MitmConfRoot 'mitmproxy-ca-cert.cer'
if (-not (Test-Path $ca)) { throw "mitmproxy CA was not generated: $ca" }
$portableCa = Join-Path $cfg.StateRoot 'mitmproxy-ca-cert.cer'
Copy-Item -LiteralPath $ca -Destination $portableCa -Force

Write-Host ''
Write-Host 'Native Windows service is ready.'
Write-Host "CA: $ca"
Write-Host 'Next run:'
Write-Host ('.\windows\enable.ps1 -PacUrl "http://127.0.0.1:{0}/proxy.pac" -CertPath "{1}"' -f $cfg.PacPort, $ca)
Write-Host 'Then fully restart Chrome once.'
