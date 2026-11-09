<#
.SYNOPSIS
    Prints the usage of each account per day from ~/.claude-switch/usage-history.jsonl.
.DESCRIPTION
    Wrapper of Get-UsageReport. One line per day and account: the highest 5-hour use, the weekly
    use at the end of the day and the number of readings. -Json prints the objects instead.
.EXAMPLE
    ./scripts/usage-report.ps1 -Days 3
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 8)] [int] $Days = 7,
    [switch] $Json
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

$rows = @(Get-UsageReport -Days $Days)
if ($Json) { ConvertTo-Json -InputObject $rows -Depth 3; exit 0 }
if ($rows.Count -eq 0) {
    Write-Output 'Sin historial todavía: ejecuta open-session.ps1 -List (o abre el panel /fleet) unas cuantas veces.'
    exit 0
}
Write-Output ("{0,-10}  {1,-8}  {2,9}  {3,8}  {4,8}" -f 'Día', 'Cuenta', 'Máx. 5 h', 'Semanal', 'Lecturas')
foreach ($r in $rows) {
    $five = if ($null -ne $r.MaxFiveHourPercent) { "$([Math]::Round($r.MaxFiveHourPercent))%" } else { '—' }
    $week = if ($null -ne $r.WeeklyPercent) { "$([Math]::Round($r.WeeklyPercent))%" } else { '—' }
    Write-Output ("{0,-10}  {1,-8}  {2,9}  {3,8}  {4,8}" -f $r.Date, $r.Account, $five, $week, $r.Readings)
}
