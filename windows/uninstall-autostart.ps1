$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$Target = Join-Path ([Environment]::GetFolderPath('Startup')) 'GBF Local Cache.vbs'
if (Test-Path $Target) {
    Remove-Item -LiteralPath $Target -Force
    Write-Host "Removed per-user startup: $Target"
} else {
    Write-Host "GBF local cache startup entry was not installed."
}
