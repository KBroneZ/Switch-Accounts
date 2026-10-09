function Get-SwitchAccountConfig {
    <#
    .SYNOPSIS
        Reads ~/.claude-switch/accounts.json, creating it with defaults when it does not exist.
    .DESCRIPTION
        The file lists the accounts: name, configDir, whether Remote Control may be used, the
        5-hour cap and an optional weekly cap, and the default model, effort and subagent model.
        It holds no credentials. Returns Path, Created, ClaudePath and Accounts (config dirs
        resolved to full paths). With -NoCreate a missing file is not written and the defaults
        are returned instead.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $ConfigPath = (Get-SwitchConfigPath),
        [switch] $NoCreate
    )

    if (Test-Path -LiteralPath $ConfigPath -PathType Container) {
        Stop-WithSwitchError InvalidArgument "${ConfigPath} is a folder; the config is a JSON file."
    }
    $created = $false
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Stop-WithSwitchError InvalidArgument "${ConfigPath} is not valid JSON: $($_.Exception.Message)"
        }
    } else {
        $defaults = Get-DefaultSwitchConfig
        if (-not $NoCreate) {
            Write-SwitchConfig -Path $ConfigPath -Config $defaults
            $created = $true
        }
        $raw = $defaults | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    }
    $config = ConvertTo-SwitchConfig -Raw $raw -Source $ConfigPath
    [pscustomobject]@{
        Path       = $ConfigPath
        Created    = $created
        ClaudePath = $config.ClaudePath
        Accounts   = $config.Accounts
    }
}
