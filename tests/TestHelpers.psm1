Set-StrictMode -Version Latest

function Get-FakeClaudePath {
    Join-Path $PSScriptRoot 'fakes' 'fake-claude.ps1'
}

function New-FakeAccount {
    <# Creates a fake config dir whose fake CLI answers `/usage` with $UsageText. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $UsageText,
        [switch] $IsError,
        [string] $RawUsageBody,
        [int] $ExitCode = 0
    )
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($PSBoundParameters.ContainsKey('RawUsageBody')) {
        Set-Content -LiteralPath (Join-Path $Path 'fake-usage.json') -Value $RawUsageBody -NoNewline
    } elseif ($PSBoundParameters.ContainsKey('UsageText')) {
        $envelope = [ordered]@{
            type           = 'result'
            subtype        = 'success'
            is_error       = [bool]$IsError
            result         = $UsageText
            total_cost_usd = 0
        }
        Set-Content -LiteralPath (Join-Path $Path 'fake-usage.json') -Value ($envelope | ConvertTo-Json -Compress) -NoNewline
    }
    if ($ExitCode -ne 0) {
        Set-Content -LiteralPath (Join-Path $Path 'fake-exit-code.txt') -Value $ExitCode -NoNewline
    }
    $Path
}

function Get-FakeCalls {
    param([Parameter(Mandatory)] [string] $ConfigDir)
    $log = Join-Path $ConfigDir 'fake-calls.jsonl'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json })
}

# Synthetic `claude -p /usage` text. The layout mirrors what CLI 2.1.284 prints
# (one line per limit, "NN% used · resets <when>"); the numbers, times and zone are invented.
function Get-SampleUsageText {
    param(
        [string] $Percent = '37', [string] $Resets = 'Jan 1, 4:30pm (UTC)',
        [string] $Weekly = '81', [string] $WeeklyResets = 'Jan 9, 9am (UTC)'
    )
    $dot = [char]0x00B7
    @"
You are currently using your subscription to power your Claude Code usage

Current session: $Percent% used $dot resets $Resets
Current week (all models): $Weekly% used $dot resets $WeeklyResets

What's contributing to your limits usage?
Approximate, based on local sessions on this machine.

Last 24h $dot 120 requests $dot 4 sessions
  50% of your usage was at >150k context
"@
}

function Get-FlagValues {
    # Values that follow a variadic flag, up to the next flag.
    param([string[]] $Arguments, [string] $Flag)
    $i = [Array]::IndexOf($Arguments, $Flag)
    if ($i -lt 0) { return @() }
    @($Arguments[($i + 1)..($Arguments.Count - 1)] | ForEach-Object -Begin { $stop = $false } -Process {
            if ($stop -or $_.StartsWith('--')) { $stop = $true } else { $_ }
        })
}

function New-ClaudeJson {
    <# The slice of an account's .claude.json that readiness checks read (synthetic values). #>
    param(
        [Parameter(Mandatory)] [string] $ConfigDir,
        [bool] $Onboarded = $true,
        [string[]] $Trusted = @(),
        [string[]] $Untrusted = @()
    )
    $projects = [ordered]@{}
    foreach ($t in $Trusted) { $projects[$t] = [ordered]@{ hasTrustDialogAccepted = $true } }
    foreach ($u in $Untrusted) { $projects[$u] = [ordered]@{ hasTrustDialogAccepted = $false } }
    $doc = [ordered]@{ hasCompletedOnboarding = $Onboarded; userID = 'synthetic-user'; projects = $projects }
    Set-Content -LiteralPath (Join-Path $ConfigDir '.claude.json') -Value ($doc | ConvertTo-Json -Depth 5)
}

function New-SwitchTestAccount {
    <# A fake account: config dir, fake /usage answer and a .claude.json. Returns the config entry. #>
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Percent = '20',
        [string] $Weekly = '10',
        [switch] $UnknownUsage,
        [bool] $Onboarded = $true,
        [string[]] $Trusted = @(),
        [bool] $RemoteControl = $true,
        [hashtable] $Extra = @{}
    )
    $dir = Join-Path $Root "config-$Name"
    if ($UnknownUsage) { New-FakeAccount -Path $dir -UsageText 'No limits to show.' | Out-Null }
    else {
        # Reset times in the future of the real clock, because the account reader uses it.
        $invariant = [cultureinfo]::InvariantCulture
        $resets = ([DateTimeOffset]::UtcNow.AddHours(3).ToString('h:mmtt', $invariant)).ToLowerInvariant() + ' (UTC)'
        $weeklyResets = ([DateTimeOffset]::UtcNow.AddDays(3).ToString('MMM d, htt', $invariant)).ToLowerInvariant().Replace('jan', 'Jan') + ' (UTC)'
        $text = Get-SampleUsageText -Percent $Percent -Weekly $Weekly -Resets $resets -WeeklyResets $weeklyResets
        New-FakeAccount -Path $dir -UsageText $text | Out-Null
    }
    New-ClaudeJson -ConfigDir $dir -Onboarded $Onboarded -Trusted $Trusted
    $entry = [ordered]@{ name = $Name; configDir = $dir; remoteControl = $RemoteControl; maxFiveHourPercent = 80 }
    foreach ($key in $Extra.Keys) { $entry[$key] = $Extra[$key] }
    $entry
}

function Write-SwitchTestConfig {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [object[]] $Accounts)
    Set-Content -LiteralPath $Path -Value ([ordered]@{ claudePath = $null; accounts = $Accounts } | ConvertTo-Json -Depth 5)
    $Path
}

Export-ModuleMember -Function *
