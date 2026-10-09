# Values that end up on a command line. Everything is checked here, before it reaches
# a launch script, and quoted with ConvertTo-PsLiteral.

$script:LaunchModelAliases = @('opus', 'sonnet', 'haiku', 'fable')
$script:LaunchEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
$script:MaxPromptLength = 2000
$script:MaxLabelLength = 80

# Kind -> process exit code of scripts/open-session.ps1. Anything else exits 1.
$script:SwitchErrorExitCodes = @{
    InvalidArgument    = 2
    NoAccountAvailable = 3
    NotReady           = 4
    Environment        = 5
}

function Stop-WithSwitchError {
    <# Throws a terminating error whose FullyQualifiedErrorId is SwitchAccounts.<Kind>. #>
    param(
        [Parameter(Mandatory)] [ValidateSet('InvalidArgument', 'NoAccountAvailable', 'NotReady', 'Environment')] [string] $Kind,
        [Parameter(Mandatory)] [string] $Message
    )
    $category = if ($Kind -eq 'InvalidArgument') { 'InvalidArgument' } else { 'InvalidOperation' }
    throw [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($Message), "SwitchAccounts.$Kind", $category, $null)
}

function ConvertTo-PsLiteral {
    <# Single-quoted PowerShell string. PowerShell also reads the typographic single quotes as quotes. #>
    param([AllowEmptyString()] [string] $Value)
    "'" + [regex]::Replace($Value, "['‘’‚‛]", '$0$0') + "'"
}

function ConvertTo-LaunchModel {
    <# Normalises and checks a model: alias or claude-… id, optional [1m] suffix. $null for an empty value. #>
    param([AllowNull()] [AllowEmptyString()] [string] $Value, [Parameter(Mandatory)] [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $model = $Value.Trim().ToLowerInvariant()
    $base = $model -replace '\[1m\]$', ''
    if ($script:LaunchModelAliases -contains $base -or $base -match '^claude-[a-z0-9]+(-[a-z0-9]+)*$') { return $model }
    Stop-WithSwitchError InvalidArgument "-$Name '$(Get-ShortText $Value 40)' is not a model. Use $($script:LaunchModelAliases -join ', ') or a claude-… id."
}

function ConvertTo-LaunchEffort {
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $effort = $Value.Trim().ToLowerInvariant()
    if ($script:LaunchEfforts -contains $effort) { return $effort }
    Stop-WithSwitchError InvalidArgument "-Effort '$(Get-ShortText $Value 40)' is not valid. Use $($script:LaunchEfforts -join ', ')."
}

function ConvertTo-SessionLabel {
    <# A tab title or a Remote Control name: letters, digits, spaces and a few marks. No ';' (wt splits on it). #>
    param([AllowNull()] [AllowEmptyString()] [string] $Value, [Parameter(Mandatory)] [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $label = $Value.Trim()
    if ($label.Length -gt $script:MaxLabelLength -or $label -notmatch '^[\p{L}\p{N} ._\-#()·:+@]+$') {
        Stop-WithSwitchError InvalidArgument "-$Name must be 1-$($script:MaxLabelLength) characters: letters, digits, spaces and . _ - # ( ) · : + @"
    }
    $label
}

function Assert-InitialPrompt {
    <# Returns the prompt or $null. Control characters (except newline and tab) and a leading '-' are refused. #>
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value.Length -gt $script:MaxPromptLength) {
        Stop-WithSwitchError InvalidArgument "-InitialPrompt is longer than $($script:MaxPromptLength) characters. Put the details in a file and ask the session to read it."
    }
    if ($Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
        Stop-WithSwitchError InvalidArgument '-InitialPrompt contains control characters.'
    }
    if ($Value.TrimStart().StartsWith('-')) {
        Stop-WithSwitchError InvalidArgument "-InitialPrompt cannot start with '-' (the CLI would read it as an option)."
    }
    $Value
}

function Assert-BranchName {
    <# A branch name that is safe on a command line and valid for git. #>
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $branch = $Value.Trim()
    $bad = $branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$' -or $branch -match '\.\.|//|\.lock(/|$)|[./]$'
    if ($bad) {
        Stop-WithSwitchError InvalidArgument "-Worktree '$(Get-ShortText $Value 40)' is not a usable branch name (letters, digits, . _ - /; at most 100 characters)."
    }
    $check = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('check-ref-format', '--branch', $branch) -TimeoutSeconds 30
    if ($check.TimedOut -or $check.ExitCode -ne 0) {
        Stop-WithSwitchError InvalidArgument "-Worktree '$branch' is not a valid git branch name."
    }
    $branch
}
