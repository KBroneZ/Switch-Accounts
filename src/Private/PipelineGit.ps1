function Invoke-Git {
    # Runs git in $Path and returns trimmed stdout; throws on a non-zero exit.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string[]] $Arguments, [int] $TimeoutSeconds = 300)
    $run = Invoke-ExternalCommand -FilePath 'git' -ArgumentList (@('-C', $Path) + $Arguments) -TimeoutSeconds $TimeoutSeconds
    if ($run.TimedOut -or $run.ExitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed in ${Path}: $($run.StdErr.Trim())"
    }
    $run.StdOut.Trim()
}

function Initialize-Worktree {
    # Creates the role's worktree on first use and refuses to reuse a dirty one.
    param([string] $RepoPath, [string] $Path, [string] $BaseBranch)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Invoke-Git -Path $RepoPath -Arguments @('worktree', 'add', '--detach', $Path, "origin/$BaseBranch") | Out-Null
    }
    $dirty = Invoke-Git -Path $Path -Arguments @('status', '--porcelain')
    if ($dirty) { throw "Worktree $Path has uncommitted changes; clean it up before running the pipeline." }
}

function Assert-TaskBranch {
    param([string] $Branch, [string] $BaseBranch, [string] $BranchPrefix)
    if (-not $Branch.StartsWith($BranchPrefix) -or $Branch -eq $BaseBranch -or $Branch -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "Refusing to use branch '$Branch' (must start with '$BranchPrefix' and differ from '$BaseBranch')."
    }
}

function Test-ImplementerWork {
    # Checks A's worktree after a session. Returns $null when the work can be pushed, or a reason.
    param([string] $Worktree, [string] $Branch, [string] $Since, [int] $MaxChangedFiles, [string] $BaseBranch)
    $current = Invoke-Git -Path $Worktree -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($current -ne $Branch) { return "implementer left branch $Branch (now on $current); nothing was pushed" }
    if (Invoke-Git -Path $Worktree -Arguments @('status', '--porcelain')) {
        return 'implementer left uncommitted changes; nothing was pushed'
    }
    $commits = [int](Invoke-Git -Path $Worktree -Arguments @('rev-list', '--count', "$Since..HEAD"))
    if ($commits -eq 0) { return 'implementer made no commits; nothing was pushed' }
    $files = @((Invoke-Git -Path $Worktree -Arguments @('diff', '--name-only', "origin/$BaseBranch...HEAD")) -split '\r?\n' | Where-Object { $_ })
    if ($files.Count -gt $MaxChangedFiles) {
        return "pull request would change $($files.Count) files (limit $MaxChangedFiles); nothing was pushed"
    }
    $null
}
