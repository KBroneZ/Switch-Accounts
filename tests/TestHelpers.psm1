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

# Synthetic /usage screens. The layout mirrors the plan-usage block of the CLI;
# the numbers, times and zone are invented.
function Get-SampleUsageText {
    param([string] $Percent = '37', [string] $Resets = '4:30pm (UTC)')
    @"
Session
Total cost:            `$0.00
Total duration (API):  0s

Current session
██████████████████▌                                37% used
Resets $Resets

Current week (all models)
████████████████████████████████████████▌          81% used
Resets Oct 9, 9am (UTC)
"@ -replace '37% used', "$Percent% used"
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

Export-ModuleMember -Function *
