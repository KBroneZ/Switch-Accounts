<#
.SYNOPSIS
    Opens a Windows Terminal tab with a Claude Code session for one of your accounts.
.DESCRIPTION
    Wrapper of Open-ClaudeSession with fixed exit codes, for the switch-account skill and for
    scripts. Prints one summary line (Spanish) and, with -PrintOnly, the launch script.

    -List             show the accounts with 5-hour and weekly usage, caps, reset times and readiness
    -ShowConfig       print ~/.claude-switch/accounts.json (created with defaults when missing)
    -Json             print the result object as JSON instead of the summary line

    Exit codes: 0 done (or listed) | 1 unexpected error | 2 invalid arguments or config |
    3 no account can start now (cap reached or usage unknown) |
    4 the account is not ready (first start unfinished, or folder not trusted) |
    5 the environment is missing something (CLI, Windows Terminal, git, worktree).
.EXAMPLE
    ./scripts/open-session.ps1 -Account auto -Model sonnet -Effort high -RemoteControl
.EXAMPLE
    ./scripts/open-session.ps1 -Account B -Directory ~/src/app -Worktree fix/login -Model opus -PrintOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Account = 'auto',
    [string] $Directory,
    [string] $Model,
    [string] $Effort,
    [string] $SubagentModel,
    [switch] $RemoteControl,
    [string] $SessionName,
    [string] $InitialPrompt,
    [string] $Title,
    [string] $Worktree,
    [string] $Count = '1',
    [switch] $PrintOnly,
    [switch] $TrustDirectory,
    [switch] $NoUsageCheck,
    [switch] $List,
    [switch] $ShowConfig,
    [switch] $Json,
    [string] $ConfigPath,
    [string] $ClaudePath
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

$exitCodes = @{
    'SwitchAccounts.InvalidArgument'    = 2
    'SwitchAccounts.NoAccountAvailable' = 3
    'SwitchAccounts.NotReady'           = 4
    'SwitchAccounts.Environment'        = 5
}

function Get-ExitCode {
    param([System.Management.Automation.ErrorRecord] $ErrorRecord)
    $id = $ErrorRecord.FullyQualifiedErrorId
    if ($exitCodes.ContainsKey($id)) { return $exitCodes[$id] }
    if ($id -like 'ParameterArgument*' -or $id -like 'ParameterBinding*') { return 2 }
    1
}

try {
    $common = @{}
    if ($ConfigPath) { $common.ConfigPath = $ConfigPath }
    if ($ClaudePath) { $common.ClaudePath = $ClaudePath }

    if ($ShowConfig) {
        $configArgs = @{}
        if ($ConfigPath) { $configArgs.ConfigPath = $ConfigPath }
        $config = Get-SwitchAccountConfig @configArgs
        Write-Host "Config file: $($config.Path)$(if ($config.Created) { ' (created with defaults)' })"
        Get-Content -LiteralPath $config.Path
        exit 0
    }
    if ($List) {
        $listArgs = $common.Clone()
        if ($Directory) { $listArgs.Directory = $Directory }
        $statuses = @(Get-ClaudeAccountStatus @listArgs)
        if ($Json) { $statuses | Select-Object -ExcludeProperty Line | ConvertTo-Json -Depth 4 }
        else { $statuses | ForEach-Object { $_.Line } }
        exit 0
    }

    $number = 0
    if (-not [int]::TryParse($Count, [ref]$number) -or $number -lt 1 -or $number -gt 8) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new('-Count must be a whole number from 1 to 8.'),
            'SwitchAccounts.InvalidArgument', 'InvalidArgument', $null)
    }
    $openArgs = $common.Clone()
    foreach ($name in 'Account', 'Directory', 'Model', 'Effort', 'SubagentModel', 'SessionName', 'InitialPrompt', 'Title', 'Worktree') {
        if ($PSBoundParameters.ContainsKey($name)) { $openArgs[$name] = $PSBoundParameters[$name] }
    }
    foreach ($name in 'RemoteControl', 'PrintOnly', 'TrustDirectory', 'NoUsageCheck') {
        if ((Get-Variable $name).Value) { $openArgs[$name] = $true }
    }
    $openArgs.Count = $number
    $result = Open-ClaudeSession @openArgs -WhatIf:$WhatIfPreference

    if ($Json) {
        $result | Select-Object -ExcludeProperty Sessions | ConvertTo-Json -Depth 4
    } else {
        foreach ($warning in $result.Warnings) { Write-Warning $warning }
        Write-Output $result.Summary
        if ($PrintOnly -or $WhatIfPreference) {
            foreach ($s in $result.Sessions) { Write-Output "--- $($s.Title) ---`n$($s.Script)" }
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit (Get-ExitCode $_)
}
