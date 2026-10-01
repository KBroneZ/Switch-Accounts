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
    $protected = $files | Where-Object { $_ -match $script:ProtectedPathPattern } | Select-Object -First 1
    if ($protected) { return "change touches protected path $protected; review and push it by hand" }
    Find-SecretInChange -Worktree $Worktree -Files $files -BaseBranch $BaseBranch
}

# Files that change how tools, hooks or CI run; an automated session must not ship them.
$script:ProtectedPathPattern = '^(\.claude/|\.mcp\.json$|\.github/|\.githooks/|\.gitmodules$|\.gitattributes$)'

$script:SecretFilePattern = '(^|/)\.credentials\.json$'
$script:SecretLinePatterns = @(
    'sk-ant-[A-Za-z0-9_-]{10,}'
    '"(accessToken|refreshToken)"\s*:'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'gh[pousr]_[A-Za-z0-9]{20,}'
)

function Find-SecretInChange {
    # Defence in depth before a push: refuses credential files and lines that look like tokens.
    # The reason names the file only, never the matched text.
    param([string] $Worktree, [string[]] $Files, [string] $BaseBranch)
    $file = $Files | Where-Object { $_ -match $script:SecretFilePattern } | Select-Object -First 1
    if ($file) { return "possible secret: change adds $file; nothing was pushed" }
    $diff = Invoke-Git -Path $Worktree -Arguments @('diff', '--unified=0', '--no-color', "origin/$BaseBranch...HEAD")
    $current = $null
    foreach ($line in $diff -split '\r?\n') {
        if ($line -match '^\+\+\+ b/(?<f>.+)$') { $current = $Matches['f']; continue }
        if ($line.StartsWith('+') -and (Test-SecretText -Text $line)) { return "possible secret in $current; nothing was pushed" }
    }
    $null
}

function Test-SecretText {
    param([string] $Text)
    foreach ($pattern in $script:SecretLinePatterns) {
        if ($Text -match $pattern) { return $true }
    }
    $false
}
