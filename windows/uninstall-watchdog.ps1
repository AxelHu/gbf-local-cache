$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$taskName = 'GBF Local Cache Watchdog'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed watchdog task: $taskName"
} else {
    Write-Host "Watchdog task not installed: $taskName"
}
