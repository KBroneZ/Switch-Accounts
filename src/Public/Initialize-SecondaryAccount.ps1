function Initialize-SecondaryAccount {
    <#
    .SYNOPSIS
        Shares the primary account's rules, skills and agents with a second config dir.
    .DESCRIPTION
        Creates directory links (junctions on Windows, symbolic links elsewhere) from the
        target config dir to the source one, plus a CLAUDE.md that imports the source
        CLAUDE.md. Only allow-listed folders are linked; credentials, account state,
        settings, projects and sessions are never read, copied or linked. Existing items
        are never overwritten: they are reported as Conflict.
    .OUTPUTS
        One object per item: Item, Action (Linked | AlreadyLinked | WouldLink | Conflict | Missing), Target.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourceConfigDir,
        [Parameter(Mandatory)] [string] $TargetConfigDir,
        [string[]] $Items = $script:DefaultSharedItems,
        [switch] $SkipClaudeMd
    )

    $dirs = Resolve-AccountDirs -SourceConfigDir $SourceConfigDir -TargetConfigDir $TargetConfigDir
    Assert-SharedItems -Items $Items

    $results = foreach ($item in $Items) {
        $from = Join-Path $dirs.Source $item
        $to = Join-Path $dirs.Target $item
        $state = Get-LinkState -Path $to -ExpectedTarget $from
        if (-not (Test-Path -LiteralPath $from -PathType Container)) {
            New-ItemResult $item 'Missing' $to
        } elseif ($state -eq 'Linked') {
            New-ItemResult $item 'AlreadyLinked' $to
        } elseif ($state -ne 'Absent') {
            New-ItemResult $item 'Conflict' $to
        } elseif ($PSCmdlet.ShouldProcess($to, "Link to $from")) {
            $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $type -Path $to -Target $from | Out-Null
            New-ItemResult $item 'Linked' $to
        } else {
            New-ItemResult $item 'WouldLink' $to
        }
    }
    if (-not $SkipClaudeMd) {
        $results = @($results) + (Set-ImportedClaudeMd -Dirs $dirs -Cmdlet $PSCmdlet)
    }

    foreach ($bad in @($results | Where-Object Action -In 'Conflict', 'Missing')) {
        Write-Error "$($bad.Item): $($bad.Action) at $($bad.Target). Nothing was changed for this item."
    }
    $results
}

$script:DefaultSharedItems = @('rules', 'skills', 'agents')
$script:AllowedSharedItems = @('agents', 'commands', 'output-styles', 'rules', 'skills')
$script:ClaudeMdMarker = '<!-- Managed by Switch-Accounts: imports the primary account instructions. -->'

function Resolve-AccountDirs {
    param([string] $SourceConfigDir, [string] $TargetConfigDir)
    if (-not (Test-Path -LiteralPath $SourceConfigDir -PathType Container)) {
        throw "Source config dir not found: $SourceConfigDir"
    }
    if (-not (Test-Path -LiteralPath $TargetConfigDir -PathType Container)) {
        throw "Target config dir not found: $TargetConfigDir. Log in to the second account first (CLAUDE_CONFIG_DIR=<dir> claude auth login)."
    }
    $source = (Resolve-Path -LiteralPath $SourceConfigDir).Path.TrimEnd('\', '/')
    $target = (Resolve-Path -LiteralPath $TargetConfigDir).Path.TrimEnd('\', '/')
    if (Test-SamePath $source $target) { throw 'Source and target config dirs are the same folder.' }
    [pscustomobject]@{ Source = $source; Target = $target }
}

function Assert-SharedItems {
    param([string[]] $Items)
    foreach ($item in $Items) {
        if ($item -notin $script:AllowedSharedItems) {
            throw "Item '$item' cannot be shared. Allowed: $($script:AllowedSharedItems -join ', ')."
        }
    }
}

function Get-LinkState {
    # Absent | Linked (points at ExpectedTarget) | Other
    param([string] $Path, [string] $ExpectedTarget)
    $existing = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $existing) { return 'Absent' }
    $linkTarget = $existing.PSObject.Properties['LinkTarget']?.Value
    if ($linkTarget -and (Test-SamePath $linkTarget $ExpectedTarget)) { return 'Linked' }
    'Other'
}

function Test-SamePath {
    param([string] $A, [string] $B)
    $normalize = { param($p) [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    [string]::Equals((& $normalize $A), (& $normalize $B), $comparison)
}

function Get-ImportedClaudeMdContent {
    param([string] $SourceDir)
    # Imports use forward slashes; a space must be escaped or the path ends there.
    $import = (Join-Path $SourceDir 'CLAUDE.md').Replace('\', '/').Replace(' ', '\ ')
    "$script:ClaudeMdMarker`n@$import`n"
}

function Set-ImportedClaudeMd {
    param($Dirs, $Cmdlet)
    $from = Join-Path $Dirs.Source 'CLAUDE.md'
    $to = Join-Path $Dirs.Target 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { return New-ItemResult 'CLAUDE.md' 'Missing' $to }
    $wanted = Get-ImportedClaudeMdContent -SourceDir $Dirs.Source
    if (Test-Path -LiteralPath $to) {
        $current = Get-Content -LiteralPath $to -Raw -ErrorAction SilentlyContinue
        $action = if ($current -eq $wanted) { 'AlreadyLinked' } else { 'Conflict' }
        return New-ItemResult 'CLAUDE.md' $action $to
    }
    if (-not $Cmdlet.ShouldProcess($to, "Write CLAUDE.md importing $from")) {
        return New-ItemResult 'CLAUDE.md' 'WouldLink' $to
    }
    [System.IO.File]::WriteAllText($to, $wanted, [System.Text.UTF8Encoding]::new($false))
    New-ItemResult 'CLAUDE.md' 'Linked' $to
}

function New-ItemResult {
    param([string] $Item, [string] $Action, [string] $Target)
    [pscustomobject]@{ Item = $Item; Action = $Action; Target = $Target }
}
