$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8
$target = Join-Path ([Environment]::GetFolderPath('Startup')) 'GBF Local Cache Native.vbs'
if (Test-Path $target) {
    Remove-Item -LiteralPath $target -Force
    Write-Host "Removed native Windows startup: $target"
} else {
    Write-Host 'Native Windows startup entry is not installed.'
}
