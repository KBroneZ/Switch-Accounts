<#
.SYNOPSIS
    Counts every account's tokens into ~/.claude-switch/tokens/ledger.tsv and writes
    ~/.claude-switch/tokens.json, which the Fleet pane draws.
.DESCRIPTION
    Wrapper of Update-TokenLedger. Reads only what is new since the last run and stops after
    -MaxSeconds (the next run goes on). The Fleet pane runs it every few minutes; run it by hand
    to backfill at once. Nothing leaves the machine and no message text is kept.
.EXAMPLE
    ./scripts/token-ledger.ps1 -MaxSeconds 900
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 3600)] [int] $MaxSeconds = 480,
    [switch] $Json
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

$r = Update-TokenLedger -MaxSeconds $MaxSeconds
if ($Json) { ConvertTo-Json -InputObject $r -Compress; exit 0 }
Write-Output "Tokens: $($r.Status), $($r.Files) files read, $($r.Added) ledger lines added$(if ($r.Skipped) { ", $($r.Skipped) skipped" }). $($r.SummaryPath)"
