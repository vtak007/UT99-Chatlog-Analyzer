<#
.SYNOPSIS
    Registers a Windows Task Scheduler entry that runs UT99-ChatMonitor.ps1 daily.

.DESCRIPTION
    Creates a scheduled task named "UT99 Chat Monitor - Daily" that runs at the
    chosen local time, every day, in your current Windows user context (so it
    has access to the saved WinSCP session and the ANTHROPIC_API_KEY env var).

.PARAMETER Time
    Local time to run, in HH:mm 24-hour format. Default 08:00.

.PARAMETER TaskName
    Name of the scheduled task. Default "UT99 Chat Monitor - Daily".

.PARAMETER Unregister
    Remove an existing task with this name.

.EXAMPLE
    .\Register-DailyTask.ps1 -Time 07:30
#>
[CmdletBinding()]
param(
    [string] $Time     = '08:00',
    [string] $TaskName = 'UT99 Chat Monitor - Daily',
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "No task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

# Resolve script paths
$BinDir     = $PSScriptRoot
$MainScript = Join-Path $BinDir 'UT99-ChatMonitor.ps1'
if (-not (Test-Path $MainScript)) { throw "Cannot find $MainScript" }

# Use pwsh.exe if available (PowerShell 7), else powershell.exe (5.1)
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) { $pwsh = $pwshCmd.Source } else { $pwsh = 'powershell.exe' }

$argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $MainScript

$action    = New-ScheduledTaskAction    -Execute $pwsh -Argument $argString -WorkingDirectory $BinDir
$trigger   = New-ScheduledTaskTrigger   -Daily -At $Time
$settings  = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -RunOnlyIfNetworkAvailable `
                -DontStopIfGoingOnBatteries `
                -AllowStartIfOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# Run as current user, only when logged in (so env vars and saved sessions are available)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Downloads UT99 server WebChatLog files, analyzes with Claude, generates a daily HTML dashboard."

# Replace existing
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' registered." -ForegroundColor Green
Write-Host "  Runs daily at $Time"
Write-Host "  Uses: $pwsh"
Write-Host "  Script: $MainScript"
Write-Host ""
Write-Host "To run it manually right now:"           -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host ""
Write-Host "To remove it later:" -ForegroundColor Cyan
Write-Host "  .\Register-DailyTask.ps1 -Unregister"   -ForegroundColor Gray