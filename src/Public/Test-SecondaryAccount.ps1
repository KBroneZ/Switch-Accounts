function Test-SecondaryAccount {
    <#
    .SYNOPSIS
        Verifies that the second config dir links each shared item to the primary one.
    .OUTPUTS
        Ok (all items fine) and Items (Item, Ok, Detail).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourceConfigDir,
        [Parameter(Mandatory)] [string] $TargetConfigDir,
        [string[]] $Items = $script:DefaultSharedItems,
        [switch] $SkipClaudeMd
    )

    $dirs = Resolve-AccountDirs -SourceConfigDir $SourceConfigDir -TargetConfigDir $TargetConfigDir
    Assert-SharedItems -Items $Items

    $checks = @(foreach ($item in $Items) {
            $state = Get-LinkState -Path (Join-Path $dirs.Target $item) -ExpectedTarget (Join-Path $dirs.Source $item)
            $detail = switch ($state) {
                'Linked' { 'linked to the primary account' }
                'Absent' { 'missing' }
                default { 'exists but is not a link to the primary account' }
            }
            [pscustomobject]@{ Item = $item; Ok = ($state -eq 'Linked'); Detail = $detail }
        })
    if (-not $SkipClaudeMd) {
        $path = Join-Path $dirs.Target 'CLAUDE.md'
        $current = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw } else { $null }
        $ok = $current -eq (Get-ImportedClaudeMdContent -SourceDir $dirs.Source)
        $detail = if ($ok) { 'imports the primary CLAUDE.md' } elseif ($null -eq $current) { 'missing' } else { 'not managed by Switch-Accounts' }
        $checks += [pscustomobject]@{ Item = 'CLAUDE.md'; Ok = $ok; Detail = $detail }
    }

    [pscustomobject]@{
        Ok    = -not ($checks | Where-Object { -not $_.Ok })
        Items = $checks
    }
}
