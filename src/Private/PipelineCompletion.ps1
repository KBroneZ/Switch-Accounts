$script:NotStartedOutcomes = @('CapWait', 'UsageUnknown')

function New-RoleResult {
    param($Job, $Session, [string] $Status, [string] $Reason)
    [pscustomobject]@{
        Task       = $Job.Task.Id
        Outcome    = $Session.Outcome
        Reason     = if ($Reason) { $Reason } else { $Session.Reason }
        RetryAfter = $Session.RetryAfter
        Status     = $Status
    }
}

function Complete-ImplementerJob {
    param($Ctx, $State, $Job, $Session)
    $id = $Job.Task.Id
    Add-RunLog -StateDir $Ctx.StateDir -Role 'implementer' -Task $id -Session $Session -Pr $State.tasks[$id]?.pr
    if ($Session.Outcome -in $script:NotStartedOutcomes) { return New-RoleResult $Job $Session $null }

    $record = @{ branch = $Job.Branch }
    if ($Session.Outcome -ne 'Completed') {
        $record += @{ status = 'blocked'; reason = "implementer session $($Session.Outcome): $($Session.Reason)" }
    } elseif (Test-NeedsUser $Session.ResultText) {
        $record += @{ status = 'waiting-user'; reason = (Get-ShortText $Session.ResultText 500) }
    } else {
        $since = if ($Job.IsFix) { $Job.Since } else { "origin/$($Ctx.BaseBranch)" }
        $problem = Test-ImplementerWork -Worktree $Ctx.WorktreeA -Branch $Job.Branch -Since $since `
            -MaxChangedFiles $Ctx.MaxChangedFiles -BaseBranch $Ctx.BaseBranch
        $outcome = if ($problem) { @{ status = 'blocked'; reason = $problem } } else { Publish-ImplementerWork -Ctx $Ctx -Job $Job }
        $record += $outcome
    }
    Set-TaskRecord -State $State -Id $id -Values $record
    New-RoleResult $Job $Session $record.status $record['reason']
}

function Publish-ImplementerWork {
    # Pushes A's branch (never force, never the base branch) and opens the PR for a new task.
    param($Ctx, $Job)
    Assert-TaskBranch -Branch $Job.Branch -BaseBranch $Ctx.BaseBranch -BranchPrefix $Ctx.BranchPrefix
    Invoke-Git -Path $Ctx.WorktreeA -Arguments @('push', '--quiet', 'origin', "HEAD:refs/heads/$($Job.Branch)") | Out-Null
    if ($Job.IsFix) { return @{ status = 'in-review'; reason = $null } }

    $body = "Automated implementation of task $($Job.Task.Id) ($($Job.Task.Slug)).`n`nReview pending by the second account."
    $run = Invoke-Gh -Ctx $Ctx -Arguments @('pr', 'create', '--base', $Ctx.BaseBranch, '--head', $Job.Branch,
        '--title', "$($Job.Task.Id): $($Job.Task.Slug)") -Body $body
    if ($run.ExitCode -ne 0 -or $run.StdOut -notmatch '/pull/(?<n>\d+)') {
        return @{ status = 'blocked'; reason = "branch pushed but the pull request could not be created: $(Get-ShortText $run.StdErr)" }
    }
    @{ status = 'in-review'; pr = [int]$Matches['n']; reason = $null }
}

function Complete-ReviewerJob {
    param($Ctx, $State, $Job, $Session)
    $id = $Job.Task.Id
    Add-RunLog -StateDir $Ctx.StateDir -Role 'reviewer' -Task $id -Session $Session -Pr $Job.Pr
    if ($Session.Outcome -in $script:NotStartedOutcomes) { return New-RoleResult $Job $Session $null }

    $verdict = if ($Session.Outcome -eq 'Completed') { Get-ReviewVerdict $Session.ResultText } else { $null }
    $record = if ($Session.Outcome -ne 'Completed') {
        @{ status = 'blocked'; reason = "reviewer session $($Session.Outcome): $($Session.Reason)" }
    } elseif (-not $verdict) {
        @{ status = 'blocked'; reason = 'review has no verdict line; nothing was posted' }
    } else {
        Submit-Review -Ctx $Ctx -State $State -Job $Job -Verdict $verdict -Text $Session.ResultText
    }
    Set-TaskRecord -State $State -Id $id -Values $record
    New-RoleResult $Job $Session $record.status $record['reason']
}

function Block-OversizedReview {
    param($Ctx, $State, $Job)
    $reason = "diff is larger than MaxReviewDiffBytes ($($Ctx.MaxReviewDiffBytes)); review it by hand"
    Set-TaskRecord -State $State -Id $Job.Task.Id -Values @{ status = 'blocked'; reason = $reason }
    [pscustomobject]@{ Task = $Job.Task.Id; Outcome = $null; Reason = $reason; RetryAfter = $null; Status = 'blocked' }
}

$script:MaxCommentChars = 60000

function Submit-Review {
    param($Ctx, $State, $Job, [string] $Verdict, [string] $Text)
    if (Test-SecretText -Text $Text) {
        return @{ status = 'blocked'; reason = 'review text looks like it contains a secret; nothing was posted' }
    }
    $body = if ($Text.Length -gt $script:MaxCommentChars) { $Text.Substring(0, $script:MaxCommentChars) + "`n`n[truncated]" } else { $Text }
    $run = Invoke-Gh -Ctx $Ctx -Arguments @('pr', 'comment', [string]$Job.Pr) -Body $body
    if ($run.ExitCode -ne 0) { return @{ status = 'blocked'; reason = "could not post the review: $(Get-ShortText $run.StdErr)" } }
    if ($Verdict -eq 'APPROVED') { return @{ status = 'approved'; reason = $null } }
    $rounds = [int]$State.tasks[$Job.Task.Id].rounds + 1
    if ($rounds -gt $Ctx.MaxReviewRounds) {
        return @{ status = 'blocked'; rounds = $rounds; reason = "changes still requested after $($Ctx.MaxReviewRounds) review rounds" }
    }
    @{ status = 'changes-requested'; rounds = $rounds; findings = $Text; reason = $null }
}

function Invoke-Gh {
    # Runs gh in the main clone; long text goes through a temporary --body-file.
    param($Ctx, [string[]] $Arguments, [string] $Body)
    $file = New-TemporaryFile
    try {
        [System.IO.File]::WriteAllText($file.FullName, $Body, [System.Text.UTF8Encoding]::new($false))
        Invoke-ExternalCommand -FilePath $Ctx.GhPath -ArgumentList ($Arguments + @('--body-file', $file.FullName)) `
            -WorkingDirectory $Ctx.RepoPath -TimeoutSeconds 120
    } finally {
        Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    }
}
