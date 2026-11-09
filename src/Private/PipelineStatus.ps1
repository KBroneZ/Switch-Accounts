# What run-pipeline.ps1 is doing, for the Fleet pane: ~/.claude-switch/pipeline.json.

function Get-PipelineStatusPath {
    Join-Path $HOME '.claude-switch' 'pipeline.json'
}

function ConvertTo-PipelineRole {
    param([Parameter(Mandatory)] [string] $Role, $Result, [string] $Account)
    if (-not $Result) { return $null }
    [ordered]@{
        role    = $Role
        account = $Account
        task    = [string]$Result.Task
        outcome = [string]$Result.Outcome
        status  = [string]$Result.Status
        reason  = if ($Result.Reason) { ([string]$Result.Reason).Substring(0, [Math]::Min(200, ([string]$Result.Reason).Length)) } else { $null }
    }
}

function Write-PipelineStatus {
    <#
      Schema 1: { schema, repo, state (running | waiting | done | stopped), cycle, maxCycles,
      updatedAt, waitUntil, message, roles: [{ role, account, task, outcome, status, reason }] }.
      Swapped in whole. A failure to write never stops the pipeline: it is a warning.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [ValidateSet('running', 'waiting', 'done', 'stopped')] [string] $State,
        [int] $Cycle, [int] $MaxCycles, $Result, $WaitUntil, [string] $Message
    )
    $roles = @()
    if ($Result) {
        $roles = @(
            ConvertTo-PipelineRole -Role 'implementer' -Result $Result.Implementer -Account 'A'
            ConvertTo-PipelineRole -Role 'reviewer' -Result $Result.Reviewer -Account 'B'
        ) | Where-Object { $_ }
    }
    $doc = [ordered]@{
        schema    = 1
        repo      = Split-Path -Leaf ([IO.Path]::TrimEndingDirectorySeparator($Repo))
        state     = $State
        cycle     = $Cycle
        maxCycles = $MaxCycles
        updatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        waitUntil = if ($WaitUntil) { ([DateTimeOffset]$WaitUntil).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) } else { $null }
        message   = if ($Message) { $Message } else { $null }
        roles     = @($roles)
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $temp = "$Path.$PID.tmp"
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } catch {
        Write-Warning "Could not write the pipeline status: $($_.Exception.Message)"
    }
}
