function Get-AccountAuth {
    <#
    .SYNOPSIS
        Reads whether one account is logged in, with which plan and until when, by running
        `claude auth status --json` with its config dir.
    .DESCRIPTION
        `auth status` is local: it makes no model request. Only five facts are kept from its
        answer (logged in, method, subscription type, plan tier, login expiry); the email,
        organization and ids it also prints are dropped here and never returned.

        Status is LoggedIn, LoggedOut or Unknown. Unknown (an old CLI without --json, a timeout,
        output that is not the expected JSON) says nothing either way: callers then read /usage
        as before and must not treat Unknown as logged out.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ConfigDir,
        [string] $ClaudePath = 'claude',
        [ValidateRange(1, 600)] [int] $TimeoutSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container)) {
        return New-AuthResult -Status Unknown -Reason "config dir not found: $ConfigDir"
    }
    try {
        $run = Invoke-ExternalCommand -FilePath $ClaudePath -ArgumentList @('auth', 'status', '--json') `
            -Environment @{ CLAUDE_CONFIG_DIR = (Resolve-Path -LiteralPath $ConfigDir).Path } `
            -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds $TimeoutSeconds
    } catch {
        return New-AuthResult -Status Unknown -Reason "could not run the CLI: $($_.Exception.Message)"
    }
    if ($run.TimedOut) { return New-AuthResult -Status Unknown -Reason "auth status timed out after $TimeoutSeconds s" }

    # `auth status` may exit non-zero when logged out, so the JSON is read whatever the exit code.
    try { $doc = $run.StdOut | ConvertFrom-Json -ErrorAction Stop }
    catch { return New-AuthResult -Status Unknown -Reason 'auth status printed no JSON' }
    if ($doc -isnot [pscustomobject] -or $null -eq $doc.PSObject.Properties['loggedIn']) {
        return New-AuthResult -Status Unknown -Reason 'auth status JSON has no loggedIn field'
    }
    $loggedIn = $doc.PSObject.Properties['loggedIn'].Value
    if ($loggedIn -isnot [bool]) { return New-AuthResult -Status Unknown -Reason 'auth status loggedIn is not true or false' }

    $expires = $null
    $rawExpiry = $doc.PSObject.Properties['loginExpiresAt']?.Value
    if ($rawExpiry -is [datetime]) {
        # ConvertFrom-Json already read an ISO date; keep its instant instead of reparsing its text.
        $expires = [DateTimeOffset]$rawExpiry.ToUniversalTime()
    } elseif ($rawExpiry) {
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$rawExpiry, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            $expires = $parsed
        }
    }
    New-AuthResult -Status $(if ($loggedIn) { 'LoggedIn' } else { 'LoggedOut' }) `
        -Method (Get-AuthText $doc 'authMethod') -Plan (Get-AuthText $doc 'subscriptionType') `
        -Tier (Get-AuthText $doc 'planTier') -ExpiresAt $expires `
        -Reason $(if ($loggedIn) { $null } else { 'not logged in (the login expired or was never made)' })
}

function Get-AuthText {
    # A short plain value of the auth JSON, or $null. Keeps only [A-Za-z0-9._-] so nothing odd is echoed.
    param($Doc, [string] $Name)
    $value = $Doc.PSObject.Properties[$Name]?.Value
    if ($value -isnot [string] -or $value -notmatch '^[A-Za-z0-9._-]{1,40}$') { return $null }
    $value
}

function New-AuthResult {
    param(
        [Parameter(Mandatory)] [ValidateSet('LoggedIn', 'LoggedOut', 'Unknown')] [string] $Status,
        [string] $Method, [string] $Plan, [string] $Tier, $ExpiresAt, [string] $Reason
    )
    [pscustomobject]@{
        Status    = $Status
        Method    = if ($Method) { $Method } else { $null }
        Plan      = if ($Plan) { $Plan } else { $null }
        Tier      = if ($Tier) { $Tier } else { $null }
        ExpiresAt = $ExpiresAt
        Reason    = if ($Reason) { $Reason } else { $null }
    }
}
