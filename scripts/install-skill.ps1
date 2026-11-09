<#
.SYNOPSIS
    Installs the switch-account and fleet-director skills into a Claude Code config dir (default ~/.claude).
.DESCRIPTION
    switch-account: skills/switch-account/SKILL.md, scripts/open-session.ps1, scripts/usage-report.ps1
    and the module (src/), so the skill carries what it runs. fleet-director: SKILL.md, LIMITS.md,
    director.default.json and scripts/ask-gemini.ps1 from skills/fleet-director.
    A skill that is already there is moved to <ConfigDir>/backups/<skill>-<timestamp> first
    (-NoBackup deletes it instead). A second account whose skills folder is linked to this config
    dir (Initialize-SecondaryAccount) gets the skills through that link.
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
$director = Join-Path $repo 'skills' 'fleet-director'
$skillPayloads = [ordered]@{
    'switch-account' = [ordered]@{
        'SKILL.md'                 = Join-Path $repo 'skills' 'switch-account' 'SKILL.md'
        'scripts/open-session.ps1' = Join-Path $repo 'scripts' 'open-session.ps1'
        'scripts/usage-report.ps1' = Join-Path $repo 'scripts' 'usage-report.ps1'
        'src'                      = Join-Path $repo 'src'
    }
    'fleet-director' = [ordered]@{
        'SKILL.md'               = Join-Path $director 'SKILL.md'
        'LIMITS.md'              = Join-Path $director 'LIMITS.md'
        'director.default.json'  = Join-Path $director 'director.default.json'
        'scripts/ask-gemini.ps1' = Join-Path $director 'scripts' 'ask-gemini.ps1'
    }
}
foreach ($payload in $skillPayloads.Values) {
    foreach ($source in $payload.Values) {
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing in the repository: $source" }
    }
}
if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container)) { throw "Config dir not found: $ConfigDir" }

$skills = Join-Path (Resolve-Path -LiteralPath $ConfigDir).Path 'skills'

function Install-OneSkill([string] $Name, [System.Collections.IDictionary] $Payload) {
    $target = Join-Path $skills $Name
    $stage = Join-Path $skills ".$Name.new-$PID"
    $backup = $null
    if (-not $PSCmdlet.ShouldProcess($target, "Install the $Name skill")) { return }
    try {
        foreach ($relative in $Payload.Keys) {
            $destination = Join-Path $stage $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $Payload[$relative] -Destination $destination -Recurse -Force
        }
        if (Test-Path -LiteralPath $target) {
            if ($NoBackup) {
                Remove-Item -LiteralPath $target -Recurse -Force
            } else {
                $backups = Join-Path (Split-Path -Parent $skills) 'backups'
                New-Item -ItemType Directory -Path $backups -Force | Out-Null
                $backup = Join-Path $backups "$Name-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
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
}

foreach ($name in $skillPayloads.Keys) {
    Install-OneSkill -Name $name -Payload $skillPayloads[$name]
}
