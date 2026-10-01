function Invoke-PipelineCycle {
    <#
    .SYNOPSIS
        Runs one step of the A -> B pipeline: A implements task N+1 while B reviews task N.
    .DESCRIPTION
        Each role has a fixed account, its own git worktree and its own branch. A commits on
        <prefix>NNN-slug; the pipeline (not A) pushes that branch and opens the pull request.
        B reviews with read-only tools; its verdict is posted as a PR comment. Approved PRs are
        never merged here. Requested changes go back to A, at most MaxReviewRounds times.
        If an account is at its cap or its usage is unknown, its role waits: the other account
        never takes over.
    .OUTPUTS
        Implementer and Reviewer (Task, Outcome, Reason, RetryAfter, Status, or $null when the
        role had nothing to do), and Idle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $QueueDir,
        [Parameter(Mandatory)] [pscustomobject] $AccountA,
        [Parameter(Mandatory)] [pscustomobject] $AccountB,
        [string] $StateDir,
        [string] $BaseBranch = 'main',
        [string] $BranchPrefix = 'auto/',
        [ValidateRange(1, 500)] [int] $MaxTurnsA = 80,
        [ValidateRange(1, 500)] [int] $MaxTurnsB = 30,
        [ValidateRange(0.01, 1440)] [double] $TimeoutMinutes = 60,
        [ValidateRange(0, 10)] [int] $MaxReviewRounds = 2,
        [ValidateRange(1, 100)] [int] $MaxTasksPerDay = 2,
        [ValidateRange(1, 10000)] [int] $MaxChangedFiles = 40,
        [ValidateRange(1, 10000000)] [int] $MaxReviewDiffBytes = 200000,
        # Reads and edits inside the worktree need no rule (acceptEdits / dontAsk); keep these narrow.
        [string[]] $ImplementerTools = @('Bash(git add *)', 'Bash(git commit *)', 'Bash(git status *)'),
        [string[]] $ExtraImplementerTools = @(),
        [string] $ClaudePath = 'claude',
        [string] $GhPath = 'gh',
        [switch] $DryRun
    )

    $ctx = New-PipelineContext -Bound $PSBoundParameters -Defaults @{
        BaseBranch = $BaseBranch; BranchPrefix = $BranchPrefix; MaxTurnsA = $MaxTurnsA; MaxTurnsB = $MaxTurnsB
        TimeoutMinutes = $TimeoutMinutes; MaxReviewRounds = $MaxReviewRounds; MaxTasksPerDay = $MaxTasksPerDay
        MaxChangedFiles = $MaxChangedFiles; ImplementerTools = @($ImplementerTools) + $ExtraImplementerTools
        MaxReviewDiffBytes = $MaxReviewDiffBytes
        ClaudePath = $ClaudePath; GhPath = $GhPath
    }
    $state = Read-PipelineState -StateDir $ctx.StateDir
    $tasks = @(Get-QueueTask -QueueDir $QueueDir)
    $implementerJob = Get-ImplementerJob -Ctx $ctx -State $state -Tasks $tasks
    $reviewerJob = Get-ReviewerJob -Ctx $ctx -State $state -Tasks $tasks
    $jobs = @(@($implementerJob, $reviewerJob) | Where-Object { $_ })
    if ($DryRun) { return Get-CyclePlan -ImplementerJob $implementerJob -ReviewerJob $reviewerJob }

    Invoke-Git -Path $RepoPath -Arguments @('fetch', '--quiet', '--prune', 'origin') | Out-Null
    foreach ($job in $jobs) { Initialize-RoleWorktree -Ctx $ctx -Job $job }
    $result = [ordered]@{ Implementer = $null; Reviewer = $null; Idle = ($jobs.Count -eq 0) }
    if ($reviewerJob -and [Text.Encoding]::UTF8.GetByteCount($reviewerJob.Diff) -gt $MaxReviewDiffBytes) {
        $result.Reviewer = Block-OversizedReview -Ctx $ctx -State $state -Job $reviewerJob
        $reviewerJob = $null
    }

    $running = @(foreach ($job in @($implementerJob, $reviewerJob) | Where-Object { $_ }) { Start-RoleSession -Ctx $ctx -Job $job })
    $sessions = Receive-RoleSessions -Running $running
    if ($implementerJob) { $result.Implementer = Complete-ImplementerJob -Ctx $ctx -State $state -Job $implementerJob -Session $sessions['implementer'] }
    if ($reviewerJob) { $result.Reviewer = Complete-ReviewerJob -Ctx $ctx -State $state -Job $reviewerJob -Session $sessions['reviewer'] }
    if ($state.tasks.Count -gt 0) { Save-PipelineState -StateDir $ctx.StateDir -State $state }
    [pscustomobject]$result
}

function Receive-RoleSessions {
    # Waits for every role before reading results, so a failure in one never orphans the other.
    param([object[]] $Running)
    if ($Running.Count -gt 0) { Wait-Job -Job $Running.Job | Out-Null }
    $sessions = @{}
    foreach ($thread in $Running) {
        try {
            $sessions[$thread.Role] = Receive-Job -Job $thread.Job -ErrorAction Stop | Select-Object -Last 1
        } catch {
            $sessions[$thread.Role] = New-SessionResult -Account $thread.Role -StartedAt ([DateTimeOffset]::Now) `
                -Outcome 'Failed' -Reason "session runner error: $($_.Exception.Message)"
        } finally {
            Remove-Job -Job $thread.Job -Force
        }
    }
    $sessions
}

function Get-CyclePlan {
    param($ImplementerJob, $ReviewerJob)
    $describe = {
        param($job)
        if (-not $job) { return $null }
        $kind = if ($job.Role -eq 'reviewer') { "review PR #$($job.Pr)" } elseif ($job.IsFix) { 'fix review findings' } else { 'implement' }
        [pscustomobject]@{ Task = $job.Task.Id; Outcome = $null; Reason = "$kind on $($job.Branch)"; RetryAfter = $null; Status = 'planned' }
    }
    [pscustomobject]@{
        Implementer = & $describe $ImplementerJob
        Reviewer    = & $describe $ReviewerJob
        Idle        = -not ($ImplementerJob -or $ReviewerJob)
    }
}

function New-PipelineContext {
    param([hashtable] $Bound, [hashtable] $Defaults)
    $repo = (Resolve-Path -LiteralPath $Bound.RepoPath).Path
    if (Test-SamePath $Bound.AccountA.ConfigDir $Bound.AccountB.ConfigDir) {
        throw 'Account A and account B use the same config dir; the pipeline needs two separate accounts.'
    }
    $stateDir = if ($Bound.StateDir) { $Bound.StateDir } else {
        Join-Path (Split-Path -Parent $repo) "$(Split-Path -Leaf $repo).switch-accounts"
    }
    $ctx = @{ RepoPath = $repo; StateDir = $stateDir; AccountA = $Bound.AccountA; AccountB = $Bound.AccountB }
    foreach ($key in $Defaults.Keys) { $ctx[$key] = $Defaults[$key] }
    $ctx.WorktreeA = Join-Path $stateDir 'worktrees' 'implementer'
    $ctx.WorktreeB = Join-Path $stateDir 'worktrees' 'reviewer'
    $ctx
}

function Get-ImplementerJob {
    param($Ctx, $State, $Tasks)
    $byId = @{}; foreach ($t in $Tasks) { if ($t.Id) { $byId[$t.Id] = $t } }
    $fix = $State.tasks.Keys | Sort-Object | Where-Object { $State.tasks[$_].status -eq 'changes-requested' -and $byId[$_] } | Select-Object -First 1
    if ($fix) {
        $record = $State.tasks[$fix]
        return @{ Role = 'implementer'; Task = $byId[$fix]; Branch = $record.branch; Findings = $record.findings; IsFix = $true }
    }
    if ((Get-TasksStartedToday -State $State) -ge $Ctx.MaxTasksPerDay) { return $null }
    $next = $Tasks | Where-Object { $_.Eligible -and -not $State.tasks.ContainsKey($_.Id) } | Select-Object -First 1
    if (-not $next) { return $null }
    $branch = "$($Ctx.BranchPrefix)$($next.Id)-$($next.Slug)"
    Assert-TaskBranch -Branch $branch -BaseBranch $Ctx.BaseBranch -BranchPrefix $Ctx.BranchPrefix
    @{ Role = 'implementer'; Task = $next; Branch = $branch; Findings = $null; IsFix = $false }
}

function Get-ReviewerJob {
    param($Ctx, $State, $Tasks)
    $byId = @{}; foreach ($t in $Tasks) { if ($t.Id) { $byId[$t.Id] = $t } }
    $id = $State.tasks.Keys | Sort-Object | Where-Object { $State.tasks[$_].status -eq 'in-review' -and $byId[$_] } | Select-Object -First 1
    if (-not $id) { return $null }
    $record = $State.tasks[$id]
    @{ Role = 'reviewer'; Task = $byId[$id]; Branch = $record.branch; Pr = [int]$record.pr }
}

function Initialize-RoleWorktree {
    param($Ctx, $Job)
    Assert-TaskBranch -Branch $Job.Branch -BaseBranch $Ctx.BaseBranch -BranchPrefix $Ctx.BranchPrefix
    if ($Job.Role -eq 'reviewer') {
        Initialize-Worktree -RepoPath $Ctx.RepoPath -Path $Ctx.WorktreeB -BaseBranch $Ctx.BaseBranch
        Invoke-Git -Path $Ctx.WorktreeB -Arguments @('checkout', '--quiet', '--detach', "origin/$($Job.Branch)") | Out-Null
        # The reviewer gets no shell: the pipeline computes the diff and puts it in the prompt.
        $Job.Diff = Invoke-Git -Path $Ctx.WorktreeB -Arguments @('diff', '--no-color', '--no-ext-diff', "origin/$($Ctx.BaseBranch)...HEAD")
        return
    }
    Initialize-Worktree -RepoPath $Ctx.RepoPath -Path $Ctx.WorktreeA -BaseBranch $Ctx.BaseBranch
    $start = if ($Job.IsFix) { "origin/$($Job.Branch)" } else { "origin/$($Ctx.BaseBranch)" }
    Invoke-Git -Path $Ctx.WorktreeA -Arguments @('checkout', '--quiet', '-B', $Job.Branch, $start) | Out-Null
    $Job.Since = Invoke-Git -Path $Ctx.WorktreeA -Arguments @('rev-parse', 'HEAD')
}

function Start-RoleSession {
    param($Ctx, $Job)
    $params = if ($Job.Role -eq 'implementer') {
        @{ Account = $Ctx.AccountA; WorkingDirectory = $Ctx.WorktreeA; MaxTurns = $Ctx.MaxTurnsA; PermissionMode = 'acceptEdits'
            Prompt = (New-ImplementerPrompt -Task $Job.Task -Branch $Job.Branch -Findings $Job.Findings)
            AllowedTools = $Ctx.ImplementerTools; DisallowedTools = @('Bash(git push)', 'Bash(git push *)', 'Bash(gh *)') }
    } else {
        @{ Account = $Ctx.AccountB; WorkingDirectory = $Ctx.WorktreeB; MaxTurns = $Ctx.MaxTurnsB; PermissionMode = 'dontAsk'
            Prompt = (New-ReviewerPrompt -Task $Job.Task -Branch $Job.Branch -BaseBranch $Ctx.BaseBranch -Pr $Job.Pr -Diff $Job.Diff)
            AllowedTools = @(); DisallowedTools = @('Edit', 'Write', 'NotebookEdit', 'Bash', 'PowerShell') }
    }
    $params += @{ StateDir = $Ctx.StateDir; TimeoutMinutes = $Ctx.TimeoutMinutes; ClaudePath = $Ctx.ClaudePath
        DenyPaths = @($Ctx.AccountA.ConfigDir, $Ctx.AccountB.ConfigDir) }
    $manifest = Join-Path $PSScriptRoot '..' 'SwitchAccounts.psd1'
    $thread = Start-ThreadJob -ScriptBlock {
        Import-Module $using:manifest -Force
        $p = $using:params
        Invoke-AccountSession @p
    }
    [pscustomobject]@{ Role = $Job.Role; Job = $thread }
}
