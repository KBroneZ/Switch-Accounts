function Get-UsageReport {
    <#
    .SYNOPSIS
        Summarises usage-history.jsonl per account and day: the highest 5-hour use, the weekly use
        at the end of the day, and how many readings there were.
    .DESCRIPTION
        The history is written by `open-session.ps1 -List` (Save-FleetSnapshot), so a day has as
        many readings as -List ran that day (the Fleet pane runs it every few minutes while open).
        Days are local dates. Lines that do not parse are skipped.
    .OUTPUTS
        Date (yyyy-MM-dd), Account, MaxFiveHourPercent, WeeklyPercent, Readings; newest day first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Join-Path (Split-Path -Parent (Get-SwitchConfigPath)) 'usage-history.jsonl'),
        [ValidateRange(1, 8)] [int] $Days = 7,
        [DateTimeOffset] $Now = [DateTimeOffset]::Now
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $from = $Now.ToLocalTime().Date.AddDays(1 - $Days)
    $rows = foreach ($line in [IO.File]::ReadAllLines($Path)) {
        # The time is read from the text: ConvertFrom-Json would turn it into a local DateTime.
        if ($line -notmatch '"at":"(?<at>[^"]+)"') { continue }
        $at = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($Matches.at, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) { continue }
        try { $doc = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($doc -isnot [pscustomobject] -or -not $doc.PSObject.Properties['name']) { continue }
        $local = $at.ToLocalTime()
        if ($local.Date -lt $from) { continue }
        [pscustomobject]@{
            Day      = $local.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            At       = $at
            Account  = [string]$doc.name
            FiveHour = $doc.PSObject.Properties['fiveHour']?.Value
            Weekly   = $doc.PSObject.Properties['weekly']?.Value
        }
    }
    @($rows) | Group-Object Day, Account | ForEach-Object {
        $group = @($_.Group | Sort-Object At)
        $five = @($group | Where-Object { $null -ne $_.FiveHour } | ForEach-Object { [double]$_.FiveHour })
        $weekly = @($group | Where-Object { $null -ne $_.Weekly } | Select-Object -Last 1)
        [pscustomobject]@{
            Date               = $group[0].Day
            Account            = $group[0].Account
            MaxFiveHourPercent = if ($five.Count) { ($five | Measure-Object -Maximum).Maximum } else { $null }
            WeeklyPercent      = if ($weekly.Count) { [double]$weekly[0].Weekly } else { $null }
            Readings           = $group.Count
        }
    } | Sort-Object @{ Expression = 'Date'; Descending = $true }, Account
}
