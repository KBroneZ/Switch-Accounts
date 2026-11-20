<#
.SYNOPSIS
    Reads one Google account's Antigravity usage (`agy -p /usage`) and keeps it in that account's usage file.
.DESCRIPTION
    For the accounts in ~/.claude-switch/gemini-accounts.json. Under gemini.lock it makes the account's
    aisw profile live, checks the switch, runs `agy -p /usage --output-format json`, saves the answer to
    ~/.claude-switch/gemini-usage-<name>.json (a failure goes to gemini-error-<name>.txt and the last
    answer stays) and puts the default account back. It never reads another account in place of the one
    asked for. Fleet runs it; run it by hand to refresh a reading.

    Exit codes: 0 kept, 1 bad arguments or config, 3 agy failed or answered something else,
    4 another Gemini run holds the lock, 5 agy not found, 6 the account is unavailable (aisw or its
    profile missing, or the switch did not check out).
.EXAMPLE
    pwsh -NoProfile -File gemini-usage.ps1 -Account G2
#>
[CmdletBinding()]
param(
    # An account name of gemini-accounts.json. Default: its default account.
    [string] $Account,
    [string] $AgyPath,
    [string] $AiswPath,
    [string] $ConfigPath,
    [string] $DataDir,
    # How long to wait for a run that holds the lock. Fleet's refresh does not wait.
    [int] $LockWaitSeconds = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gemini-accounts.ps1')

function Stop-With([int] $Code, [string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$lock = $null
$config = $null
$aisw = $null
$agyDir = $null
try {
    if (-not $DataDir) { $DataDir = Get-GeminiDataDir }
    $config = if ($ConfigPath) { Get-GeminiAccountConfig -Path $ConfigPath } else { Get-GeminiAccountConfig -Path (Join-Path $DataDir 'gemini-accounts.json') }
    if (-not $config) { Stop-With 1 'No gemini-accounts.json: there are no Google accounts to read.' }
    $target = if ($Account) { Resolve-GeminiAccount -Config $config -Name $Account } else { $config.Default }

    if (-not $AgyPath) {
        $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData' 'Local' }
        $AgyPath = Join-Path $local 'agy' 'bin' 'agy.exe'
    }
    if (-not (Test-Path -LiteralPath $AgyPath -PathType Leaf)) { Stop-With 5 "agy not found at $AgyPath. Install Antigravity CLI or pass -AgyPath." }
    $agyDir = Split-Path -Parent ([IO.Path]::GetFullPath($AgyPath))
    $aisw = Find-Aisw -Override $AiswPath -Config $config
    if (-not $aisw) { Stop-With 6 "Google account $($target.Name) is unavailable: aisw was not found (put it on PATH, in ~/.aisw/bin, or set aiswPath)." }

    $lock = Enter-GeminiLock -Path (Join-Path $DataDir 'gemini.lock') -WaitSeconds $LockWaitSeconds
    Switch-GeminiAccount -Account $target -Aisw $aisw -AgyDir $agyDir
    $isKept = Update-GeminiUsage -Account $target -AgyPath $AgyPath -DataDir $DataDir
    $warning = Restore-GeminiDefaultAccount -Config $config -Aisw $aisw -AgyDir $agyDir
    if ($warning) { [Console]::Error.WriteLine($warning) }
    if (-not $isKept) { Stop-With 3 (Get-Content -LiteralPath (Get-GeminiUsagePath -DataDir $DataDir -Name $target.Name -ErrorFile) -Raw) }
    Write-Output "Saved: $(Get-GeminiUsagePath -DataDir $DataDir -Name $target.Name)"
    exit 0
} catch {
    # A switch that failed half way still gets the default put back.
    if ($config -and $aisw -and $lock) {
        $warning = Restore-GeminiDefaultAccount -Config $config -Aisw $aisw -AgyDir $agyDir
        if ($warning) { [Console]::Error.WriteLine($warning) }
    }
    Stop-With (Get-GeminiExitCode $_) $_.Exception.Message
} finally {
    Exit-GeminiLock $lock
}
