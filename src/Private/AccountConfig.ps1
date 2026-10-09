# ~/.claude-switch/accounts.json: which accounts exist and how each one opens.

$script:DefaultFiveHourCap = 80

function Resolve-HomePath {
    param([Parameter(Mandatory)] [string] $Path)
    if ($Path -match '^~(?=$|[\\/])') { return (Join-Path $HOME $Path.Substring(1).TrimStart('\', '/')) }
    $Path
}

function ConvertTo-ComparablePath {
    param([Parameter(Mandatory)] [string] $Path)
    $full = [IO.Path]::GetFullPath((Resolve-HomePath $Path)).TrimEnd('\', '/')
    if ($IsWindows) { $full.ToUpperInvariant() } else { $full }
}

function Get-SwitchConfigPath {
    Join-Path $HOME '.claude-switch' 'accounts.json'
}

function Get-DefaultSwitchConfig {
    $account = {
        param($name, $dir)
        [ordered]@{
            name                 = $name
            configDir            = $dir
            remoteControl        = $true
            maxFiveHourPercent   = $script:DefaultFiveHourCap
            maxWeeklyPercent     = $null
            defaultModel         = $null
            defaultEffort        = $null
            defaultSubagentModel = $null
        }
    }
    [ordered]@{
        claudePath = $null
        accounts   = @((& $account 'A' '~/.claude'), (& $account 'B' '~/.claude-account2'))
    }
}

function Write-SwitchConfig {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Config)
    $folder = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, ($Config | ConvertTo-Json -Depth 6) + "`n", [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-ConfigValue {
    param($Object, [string] $Name)
    $Object.PSObject.Properties[$Name]?.Value
}

function Test-PercentNumber {
    param($Value)
    ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) -and $Value -ge 1 -and $Value -le 100
}

function ConvertTo-AccountEntry {
    <# One validated account. Throws InvalidArgument naming the file and the account. #>
    param([Parameter(Mandatory)] $Raw, [Parameter(Mandatory)] [int] $Index, [Parameter(Mandatory)] [string] $Source)
    $fail = { param($why) Stop-WithSwitchError InvalidArgument "${Source}: account #$($Index + 1) $why" }
    $name = Get-ConfigValue $Raw 'name'
    if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$') {
        & $fail 'needs a "name" of 1-30 letters, digits, . _ -'
    }
    if ($name -ieq 'auto') { & $fail '("auto") cannot be a name: it means "pick the account for me"' }
    $dir = Get-ConfigValue $Raw 'configDir'
    if ($dir -isnot [string] -or [string]::IsNullOrWhiteSpace($dir)) { & $fail "($name) needs a `"configDir`"" }
    $rc = Get-ConfigValue $Raw 'remoteControl'
    if ($null -ne $rc -and $rc -isnot [bool]) { & $fail "($name): remoteControl must be true or false" }
    $cap = Get-ConfigValue $Raw 'maxFiveHourPercent'
    if ($null -ne $cap -and -not (Test-PercentNumber $cap)) { & $fail "($name): maxFiveHourPercent must be a number from 1 to 100" }
    $weekly = Get-ConfigValue $Raw 'maxWeeklyPercent'
    if ($null -ne $weekly -and -not (Test-PercentNumber $weekly)) { & $fail "($name): maxWeeklyPercent must be null or a number from 1 to 100" }
    try {
        $model = ConvertTo-LaunchModel (Get-ConfigValue $Raw 'defaultModel') 'defaultModel'
        $subagent = ConvertTo-LaunchModel (Get-ConfigValue $Raw 'defaultSubagentModel') 'defaultSubagentModel'
        $effort = ConvertTo-LaunchEffort (Get-ConfigValue $Raw 'defaultEffort')
    } catch {
        & $fail "($name): $($_.Exception.Message)"
    }
    $resolved = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Resolve-HomePath $dir.Trim())))
    [pscustomobject]@{
        Name                 = $name
        ConfigDir            = $resolved
        IsDefaultConfigDir   = Test-SamePath $resolved (Join-Path $HOME '.claude')
        RemoteControl        = if ($null -eq $rc) { $true } else { $rc }
        MaxFiveHourPercent   = if ($null -eq $cap) { $script:DefaultFiveHourCap } else { [double]$cap }
        MaxWeeklyPercent     = if ($null -eq $weekly) { $null } else { [double]$weekly }
        DefaultModel         = $model
        DefaultEffort        = $effort
        DefaultSubagentModel = $subagent
    }
}

function ConvertTo-SwitchConfig {
    param([Parameter(Mandatory)] $Raw, [Parameter(Mandatory)] [string] $Source)
    $rawAccounts = @(Get-ConfigValue $Raw 'accounts')
    if ($rawAccounts.Count -eq 0 -or $null -eq $rawAccounts[0]) {
        Stop-WithSwitchError InvalidArgument "${Source}: no accounts in `"accounts`"."
    }
    $accounts = @(for ($i = 0; $i -lt $rawAccounts.Count; $i++) { ConvertTo-AccountEntry -Raw $rawAccounts[$i] -Index $i -Source $Source })
    $names = $accounts.Name | ForEach-Object { $_.ToLowerInvariant() }
    if (@($names | Select-Object -Unique).Count -ne $accounts.Count) {
        Stop-WithSwitchError InvalidArgument "${Source}: account names must be unique (ignoring case)."
    }
    $dirs = $accounts.ConfigDir | ForEach-Object { ConvertTo-ComparablePath $_ }
    if (@($dirs | Select-Object -Unique).Count -ne $accounts.Count) {
        Stop-WithSwitchError InvalidArgument "${Source}: two accounts share the same configDir."
    }
    $claudePath = Get-ConfigValue $Raw 'claudePath'
    if ($null -ne $claudePath -and $claudePath -isnot [string]) {
        Stop-WithSwitchError InvalidArgument "${Source}: claudePath must be null or a path."
    }
    [pscustomobject]@{ ClaudePath = $claudePath; Accounts = $accounts }
}
