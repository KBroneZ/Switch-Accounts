# A git worktree for one session: <repo>\.claude\worktrees\<branch>, branched from the
# remote's default branch.

function Get-MainCheckoutRoot {
    <# Top folder of the main checkout, also when Path is inside a linked worktree. #>
    param([Parameter(Mandatory)] [string] $Path)
    $run = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $Path, 'rev-parse', '--path-format=absolute', '--git-common-dir') -TimeoutSeconds 30
    if ($run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.StdOut.Trim()) {
        Stop-WithSwitchError InvalidArgument "-Worktree needs a git repository, and '$Path' is not inside one."
    }
    $common = $run.StdOut.Trim()
    if ((Split-Path -Leaf $common) -ne '.git') {
        Stop-WithSwitchError InvalidArgument "-Worktree does not support a bare repository ($common)."
    }
    (Resolve-Path -LiteralPath (Split-Path -Parent $common)).Path
}

function Get-RemoteDefaultBranch {
    <# 'origin/<branch>' of the remote's default branch, from the local remote HEAD or main/master. #>
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $head = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD') -TimeoutSeconds 30
    if ($head.ExitCode -eq 0 -and $head.StdOut.Trim() -match '^origin/[A-Za-z0-9._/-]+$') { return $head.StdOut.Trim() }
    foreach ($name in 'main', 'master') {
        $check = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$name") -TimeoutSeconds 30
        if ($check.ExitCode -eq 0) { return "origin/$name" }
    }
    Stop-WithSwitchError Environment "No default branch found for the remote of $RepoRoot (no origin/HEAD, origin/main or origin/master). Run: git fetch origin"
}

function Get-WorktreePlan {
    <# Where the worktree of a branch goes and from what; no side effects. #>
    param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string] $Branch)
    $root = Get-MainCheckoutRoot -Path $Directory
    $folder = $Branch.Replace('/', '-')
    [pscustomobject]@{
        RepoRoot = $root
        Branch   = $Branch
        Path     = [IO.Path]::GetFullPath((Join-Path $root '.claude' 'worktrees' $folder))
    }
}

function Add-LocalGitExclude {
    <# Keeps .claude/worktrees out of `git status` through .git/info/exclude (not committed). #>
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $run = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude') -TimeoutSeconds 30
    if ($run.ExitCode -ne 0) { return }
    $file = $run.StdOut.Trim()
    $entry = '/.claude/worktrees/'
    $existing = if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file) } else { @() }
    if ($existing -contains $entry) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    Add-Content -LiteralPath $file -Value $entry
}

function New-SessionWorktree {
    <#
      Creates the worktree of a plan (or reuses it when it already holds the branch). Refuses a
      branch that exists elsewhere or a folder that holds something else. Returns the plan and
      Warnings (for example when the fetch failed and the local remote ref was used).
    #>
    param([Parameter(Mandatory)] $Plan)
    $warnings = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Plan.Path) {
        $current = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $Plan.Path, 'rev-parse', '--abbrev-ref', 'HEAD') -TimeoutSeconds 30
        if ($current.ExitCode -eq 0 -and $current.StdOut.Trim() -eq $Plan.Branch) {
            return [pscustomobject]@{ Plan = $Plan; Reused = $true; Warnings = @() }
        }
        Stop-WithSwitchError Environment "$($Plan.Path) already exists and does not hold branch '$($Plan.Branch)'."
    }
    $exists = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $Plan.RepoRoot, 'rev-parse', '--verify', '--quiet', "refs/heads/$($Plan.Branch)") -TimeoutSeconds 30
    if ($exists.ExitCode -eq 0) {
        Stop-WithSwitchError Environment "Branch '$($Plan.Branch)' already exists. Pick a new name, or open the session in that branch's folder."
    }
    $base = Get-RemoteDefaultBranch -RepoRoot $Plan.RepoRoot
    $fetch = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $Plan.RepoRoot, 'fetch', '--quiet', 'origin', $base.Substring('origin/'.Length)) -TimeoutSeconds 120
    if ($fetch.TimedOut -or $fetch.ExitCode -ne 0) {
        $warnings.Add("could not fetch $base; the worktree starts from the last known $base")
    }
    Add-LocalGitExclude -RepoRoot $Plan.RepoRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $Plan.Path) -Force | Out-Null
    $add = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('-C', $Plan.RepoRoot, 'worktree', 'add', '--no-track', '-b', $Plan.Branch, $Plan.Path, $base) -TimeoutSeconds 120
    if ($add.TimedOut -or $add.ExitCode -ne 0) {
        Stop-WithSwitchError Environment "git worktree add failed: $(Get-ShortText $add.StdErr.Trim())"
    }
    [pscustomobject]@{ Plan = $Plan; Reused = $false; Warnings = $warnings.ToArray() }
}
