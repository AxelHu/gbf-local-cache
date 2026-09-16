$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
. (Join-Path $PSScriptRoot 'native-common.ps1')

$cfg = Get-GBFNativeConfig
if (-not (Test-Path $cfg.RuntimeFile)) {
    Write-Host 'native Windows cache is not running'
    return
}

$runtime = Get-Content -Raw $cfg.RuntimeFile | ConvertFrom-Json
$pids = @([int]$runtime.mitm_pid, [int]$runtime.pac_pid)
if ($runtime.PSObject.Properties.Name -contains 'compat_pac_pid') { $pids += [int]$runtime.compat_pac_pid }
foreach ($pidValue in $pids) {
    if (Test-GBFOwnedProcess $pidValue $cfg.RepoRoot) {
        Stop-GBFProcessTree $pidValue
    }
}
Remove-Item $cfg.RuntimeFile -Force -ErrorAction SilentlyContinue
Write-Host 'stopped native Windows cache'
