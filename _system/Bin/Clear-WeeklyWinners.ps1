<#
.SYNOPSIS
    Clears the weekly winners state file so the Top 3 Weekly Winners section
    resets on the next run of UT99-ChatMonitor.ps1.

.DESCRIPTION
    Deletes state\weekly-wins.json from the _system folder.
    The next scheduled or manual run of UT99-ChatMonitor.ps1 will start
    fresh tallies for the current week.

.EXAMPLE
    .\Clear-WeeklyWinners.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$StateFolder        = Join-Path (Split-Path $PSScriptRoot -Parent) 'state'
$WeeklyWinsFile     = Join-Path $StateFolder 'weekly-wins.json'
$PrevWeeklyWinsFile = Join-Path $StateFolder 'prev-weekly-winners.json'

$cleared = $false

if (Test-Path $WeeklyWinsFile) {
    if ($PSCmdlet.ShouldProcess($WeeklyWinsFile, 'Delete weekly wins state file')) {
        Remove-Item $WeeklyWinsFile -Force
        Write-Host "Weekly winners data cleared: $WeeklyWinsFile" -ForegroundColor Green
        $cleared = $true
    }
}

if (Test-Path $PrevWeeklyWinsFile) {
    if ($PSCmdlet.ShouldProcess($PrevWeeklyWinsFile, 'Delete previous week winners state file')) {
        Remove-Item $PrevWeeklyWinsFile -Force
        Write-Host "Previous week winners data cleared: $PrevWeeklyWinsFile" -ForegroundColor Green
        $cleared = $true
    }
}

if (-not $cleared) {
    Write-Host "Nothing to clear — no weekly wins files found." -ForegroundColor Yellow
}
