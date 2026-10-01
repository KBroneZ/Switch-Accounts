function Get-QueueTask {
    <#
    .SYNOPSIS
        Reads the task queue: one Markdown file per task, named NNN-slug.md, with a YAML header.
    .DESCRIPTION
        Header keys: status (draft | ready | done ...), tier (free text; R3 is never automatic),
        auto (true | false) and gates (list of steps that wait for a human). A task is Eligible
        only when status is ready, auto is true, the tier is not R3 and gates is empty.
        Only flat "key: value" lines are read; anything unexpected makes the task ineligible.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $QueueDir)

    if (-not (Test-Path -LiteralPath $QueueDir -PathType Container)) {
        throw "Queue folder not found: $QueueDir"
    }
    $tasks = foreach ($file in Get-ChildItem -LiteralPath $QueueDir -Filter '*.md' -File) {
        ConvertTo-QueueTask -File $file
    }
    @($tasks) | Sort-Object { if ($null -eq $_.Number) { [int]::MaxValue } else { $_.Number } }, Path
}

function ConvertTo-QueueTask {
    param([System.IO.FileInfo] $File)
    $task = [ordered]@{
        Path = $File.FullName; Id = $null; Number = $null; Slug = $null
        Status = $null; Tier = $null; Auto = $false; Gates = @(); Body = $null
        Eligible = $false; Reason = $null
    }
    if ($File.Name -notmatch '^(?<id>\d{3,})-(?<slug>[a-z0-9][a-z0-9-]*)\.md$') {
        $task.Reason = 'file name is not NNN-slug.md'
        return [pscustomobject]$task
    }
    $task.Id = $Matches['id']; $task.Number = [int]$Matches['id']; $task.Slug = $Matches['slug']

    $text = Get-Content -LiteralPath $File.FullName -Raw
    if ($text -notmatch '(?s)^---\r?\n(?<head>.*?)\r?\n---\r?\n?(?<body>.*)$') {
        $task.Reason = 'no YAML header'
        return [pscustomobject]$task
    }
    $task.Body = $Matches['body'].Trim()
    $header = @{}
    foreach ($line in $Matches['head'] -split '\r?\n') {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -notmatch '^(?<k>[a-z_]+):\s*(?<v>.*?)\s*(#.*)?$') {
            $task.Reason = "unreadable header line: $line"
            return [pscustomobject]$task
        }
        $header[$Matches['k']] = $Matches['v']
    }
    $task.Status = $header['status']
    $task.Tier = $header['tier']
    $gates = ConvertFrom-YamlList $header['gates']
    $task.Gates = $gates
    $task.Auto = $header['auto'] -eq 'true'

    $task.Reason = if ($task.Status -ne 'ready') { "status is '$($task.Status)', not 'ready'" }
    elseif ($header['auto'] -notin 'true', 'false') { 'auto must be true or false' }
    elseif (-not $task.Auto) { 'auto is false' }
    elseif ($task.Tier -eq 'R3') { 'tier R3 is never automatic' }
    elseif ($null -eq $gates) { 'gates is not a [list]' }
    elseif ($gates.Count -gt 0) { "open gates: $($task.Gates -join ', ')" }
    $task.Eligible = $null -eq $task.Reason
    [pscustomobject]$task
}

function ConvertFrom-YamlList {
    # "[]" or "[a, b]" or empty. Returns $null for anything else.
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return , [string[]]@() }
    if ($Value -notmatch '^\[(?<items>.*)\]$') { return $null }
    , [string[]]@($Matches['items'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
