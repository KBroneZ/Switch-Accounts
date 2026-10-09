<#
.SYNOPSIS
    Installs the switch-account skill into a Claude Code config dir (default ~/.claude).
.DESCRIPTION
    Copies skills/switch-account/SKILL.md, scripts/open-session.ps1 and the module (src/) to
    <ConfigDir>/skills/switch-account, so the skill carries what it runs. A skill that is
    already there is moved to <ConfigDir>/backups/switch-account-<timestamp> first (-NoBackup
    deletes it instead). A second account whose skills folder is linked to this config dir
    (Initialize-SecondaryAccount) gets the skill through that link.
    Run it again after pulling a new version of this repository.
.EXAMPLE
    ./scripts/install-skill.ps1 -WhatIf
.EXAMPLE
    ./scripts/install-skill.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigDir = (Join-Path $HOME '.claude'),
    [switch] $NoBackup
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$payload = [ordered]@{
    'SKILL.md'                = Join-Path $repo 'skills' 'switch-account' 'SKILL.md'
    'scripts/open-session.ps1' = Join-Path $repo 'scripts' 'open-session.ps1'
    'src'                     = Join-Path $repo 'src'
}
foreach ($source in $payload.Values) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing in the repository: $source" }
}
if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container)) { throw "Config dir not found: $ConfigDir" }

$skills = Join-Path (Resolve-Path -LiteralPath $ConfigDir).Path 'skills'
$target = Join-Path $skills 'switch-account'
$stage = Join-Path $skills ".switch-account.new-$PID"
$backup = $null
if (-not $PSCmdlet.ShouldProcess($target, 'Install the switch-account skill')) { return }

try {
    foreach ($relative in $payload.Keys) {
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $payload[$relative] -Destination $destination -Recurse -Force
    }
    if (Test-Path -LiteralPath $target) {
        if ($NoBackup) {
            Remove-Item -LiteralPath $target -Recurse -Force
        } else {
            $backups = Join-Path (Split-Path -Parent $skills) 'backups'
            New-Item -ItemType Directory -Path $backups -Force | Out-Null
            $backup = Join-Path $backups "switch-account-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
            Move-Item -LiteralPath $target -Destination $backup
            Write-Host "Previous skill saved at $backup"
        }
    }
    try {
        Move-Item -LiteralPath $stage -Destination $target
    } catch {
        if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $target }
        throw
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
Write-Host "Installed: $target"
