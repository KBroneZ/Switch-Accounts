<#
.SYNOPSIS
    Runs the two-account pipeline: account A implements, account B reviews, in parallel.
.DESCRIPTION
    Repeats Invoke-PipelineCycle until there is nothing left to do, MaxCycles is reached, or no
    role can run because of usage. Each account has its own cap on the 5-hour usage window.
    A role whose account is at its cap, or whose usage cannot be read, waits; the other account
    never takes over its work.

    Exit codes: 0 = finished (idle or MaxCycles reached), 3 = stopped because no role could run
    (cap reached or usage unknown); see the output for the reason and the reset time.
.EXAMPLE
    ./scripts/run-pipeline.ps1 -RepoPath ~/src/app -QueueDir ~/src/app/tasks `
        -AccountAConfigDir ~/.claude -AccountBConfigDir ~/.claude-second `
        -MaxFiveHourPercentA 70 -MaxFiveHourPercentB 60
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoPath,
    [Parameter(Mandatory)] [string] $QueueDir,
    [Parameter(Mandatory)] [string] $AccountAConfigDir,
    [Parameter(Mandatory)] [string] $AccountBConfigDir,
    [Parameter(Mandatory)] [ValidateRange(1, 100)] [double] $MaxFiveHourPercentA,
    [Parameter(Mandatory)] [ValidateRange(1, 100)] [double] $MaxFiveHourPercentB,
    [string] $StateDir,
    [ValidateRange(1, 1000)] [int] $MaxCycles = 10,
    [ValidateRange(0, 300)] [int] $MaxWaitMinutes = 0,
    [ValidateRange(1, 100)] [int] $MaxTasksPerDay = 2,
    [ValidateRange(1, 500)] [int] $MaxTurnsA = 80,
    [ValidateRange(1, 500)] [int] $MaxTurnsB = 30,
    [ValidateRange(0.01, 1440)] [double] $TimeoutMinutes = 60,
    [string[]] $ExtraImplementerTools = @(),
    [string] $BaseBranch = 'main',
    [string] $ClaudePath = 'claude',
    [string] $GhPath = 'gh',
    [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

$cycleArgs = @{
    RepoPath = $RepoPath; QueueDir = $QueueDir; BaseBranch = $BaseBranch
    AccountA = [pscustomobject]@{ Name = 'A'; ConfigDir = $AccountAConfigDir; MaxFiveHourPercent = $MaxFiveHourPercentA }
    AccountB = [pscustomobject]@{ Name = 'B'; ConfigDir = $AccountBConfigDir; MaxFiveHourPercent = $MaxFiveHourPercentB }
    MaxTasksPerDay = $MaxTasksPerDay; MaxTurnsA = $MaxTurnsA; MaxTurnsB = $MaxTurnsB
    TimeoutMinutes = $TimeoutMinutes; ClaudePath = $ClaudePath; GhPath = $GhPath; DryRun = $DryRun
    ExtraImplementerTools = $ExtraImplementerTools
}
if ($StateDir) { $cycleArgs.StateDir = $StateDir }

$notStarted = @('CapWait', 'UsageUnknown')
for ($i = 1; $i -le $MaxCycles; $i++) {
    $cycle = Invoke-PipelineCycle @cycleArgs
    foreach ($role in 'Implementer', 'Reviewer') {
        $r = $cycle.$role
        if ($r) { Write-Host ("[{0}] {1,-11} task {2}: {3} {4} {5}" -f $i, $role, $r.Task, $r.Outcome, $r.Status, $r.Reason) }
    }
    if ($cycle.Idle) { Write-Host 'Nothing left to do.'; exit 0 }
    if ($DryRun) { exit 0 }

    $roles = @($cycle.Implementer, $cycle.Reviewer) | Where-Object { $_ }
    if (@($roles | Where-Object { $_.Outcome -notin $notStarted }).Count -gt 0) { continue }

    $retry = @($roles | Where-Object { $_.RetryAfter } | ForEach-Object { [DateTimeOffset]$_.RetryAfter } | Sort-Object) | Select-Object -First 1
    $unknown = @($roles | Where-Object Outcome -EQ 'UsageUnknown').Count -gt 0
    $waitMinutes = if ($retry) { ($retry - [DateTimeOffset]::Now).TotalMinutes } else { [double]::PositiveInfinity }
    if ($unknown -or $waitMinutes -gt $MaxWaitMinutes) {
        $when = if ($retry) { " Earliest reset: $($retry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))." } else { '' }
        Write-Host "No role can run: usage cap reached or usage unknown.$when"
        exit 3
    }
    Write-Host "Waiting $([Math]::Ceiling($waitMinutes)) min for the 5-hour window to reset."
    Start-Sleep -Seconds ([Math]::Max(1, [Math]::Ceiling($waitMinutes * 60)))
}
Write-Host "Stopped after $MaxCycles cycles."
exit 0
