<#
.SYNOPSIS
    Runs the two-account pipeline: account A implements, account B reviews, in parallel.
.DESCRIPTION
    Repeats Invoke-PipelineCycle until there is nothing left to do, MaxCycles is reached, or no
    role can run because of usage. Each account has its own cap on the 5-hour usage window.
    A role whose account is at its cap, or whose usage cannot be read, waits; the other account
    never takes over its work.

    Unless -DryRun, each cycle is also written to -StatusPath (default
    ~/.claude-switch/pipeline.json) for the Fleet pane.

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
    [string] $StatusPath,
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

$module = Get-Module SwitchAccounts
if (-not $StatusPath) { $StatusPath = & $module { Get-PipelineStatusPath } }
function Set-Status {
    param([string] $State, [int] $Cycle, $Result, $WaitUntil, [string] $Message)
    if ($DryRun) { return }
    $statusArgs = @{ Path = $StatusPath; Repo = $RepoPath; State = $State; Cycle = $Cycle; MaxCycles = $MaxCycles; Result = $Result; WaitUntil = $WaitUntil; Message = $Message }
    & $module { param($a) Write-PipelineStatus @a } $statusArgs
}
Set-Status -State running -Cycle 0
# Every way out below writes its own state; anything else (an error, Ctrl+C) leaves the
# pane a 'stopped' state rather than a 'running' one that is no longer true.
$isSettled = $false
try {

    $notStarted = @('CapWait', 'UsageUnknown')
    for ($i = 1; $i -le $MaxCycles; $i++) {
        $cycle = Invoke-PipelineCycle @cycleArgs
        Set-Status -State running -Cycle $i -Result $cycle
        foreach ($role in 'Implementer', 'Reviewer') {
            $r = $cycle.$role
            if ($r) { Write-Host ("[{0}] {1,-11} task {2}: {3} {4} {5}" -f $i, $role, $r.Task, $r.Outcome, $r.Status, $r.Reason) }
        }
        if ($cycle.Idle) { $isSettled = $true; Set-Status -State done -Cycle $i -Result $cycle -Message 'Nothing left to do.'; Write-Host 'Nothing left to do.'; exit 0 }
        if ($DryRun) { $isSettled = $true; exit 0 }

        $roles = @($cycle.Implementer, $cycle.Reviewer) | Where-Object { $_ }
        if (@($roles | Where-Object { $_.Outcome -notin $notStarted }).Count -gt 0) { continue }

        $retry = @($roles | Where-Object { $_.RetryAfter } | ForEach-Object { [DateTimeOffset]$_.RetryAfter } | Sort-Object) | Select-Object -First 1
        $unknown = @($roles | Where-Object Outcome -EQ 'UsageUnknown').Count -gt 0
        $waitMinutes = if ($retry) { ($retry - [DateTimeOffset]::Now).TotalMinutes } else { [double]::PositiveInfinity }
        if ($unknown -or $waitMinutes -gt $MaxWaitMinutes) {
            $when = if ($retry) { " Earliest reset: $($retry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))." } else { '' }
            $isSettled = $true
            Set-Status -State stopped -Cycle $i -Result $cycle -WaitUntil $retry -Message "No role can run: usage cap reached or usage unknown.$when"
            Write-Host "No role can run: usage cap reached or usage unknown.$when"
            exit 3
        }
        Set-Status -State waiting -Cycle $i -Result $cycle -WaitUntil $retry -Message 'Waiting for the 5-hour window to reset.'
        Write-Host "Waiting $([Math]::Ceiling($waitMinutes)) min for the 5-hour window to reset."
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Ceiling($waitMinutes * 60)))
    }
    $isSettled = $true
    Set-Status -State done -Cycle $MaxCycles -Message "Stopped after $MaxCycles cycles."
    Write-Host "Stopped after $MaxCycles cycles."
    exit 0
} catch {
    $isSettled = $true
    Set-Status -State stopped -Message "Stopped by an error: $($_.Exception.Message)"
    throw
} finally {
    if (-not $isSettled) { Set-Status -State stopped -Message 'Interrupted.' }
}
