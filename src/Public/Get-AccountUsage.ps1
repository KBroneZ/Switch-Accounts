function Get-AccountUsage {
    <#
    .SYNOPSIS
        Reads the 5-hour usage of one account by running `claude -p /usage` with its config dir.
    .DESCRIPTION
        /usage is a local command: it reads the plan limits without a model request, so it does
        not spend usage. The CLI runs with --safe-mode (no hooks, plugins or MCP servers) and
        --no-session-persistence, in a temporary working directory. Any failure returns
        Status = Unknown; callers must treat Unknown as "do not start" (see Test-UsageCap).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ConfigDir,
        [string] $ClaudePath = 'claude',
        [ValidateRange(1, 600)] [int] $TimeoutSeconds = 90,
        [DateTimeOffset] $Now = [DateTimeOffset]::Now
    )

    if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container)) {
        return New-UsageResult -Reason "config dir not found: $ConfigDir"
    }

    $arguments = @('-p', '/usage', '--output-format', 'json', '--no-session-persistence', '--safe-mode')
    try {
        $run = Invoke-ExternalCommand -FilePath $ClaudePath -ArgumentList $arguments `
            -Environment @{ CLAUDE_CONFIG_DIR = (Resolve-Path -LiteralPath $ConfigDir).Path } `
            -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds $TimeoutSeconds
    } catch {
        return New-UsageResult -Reason "could not run the CLI: $($_.Exception.Message)"
    }

    if ($run.TimedOut) { return New-UsageResult -Reason "CLI timed out after $TimeoutSeconds s" }
    if ($run.ExitCode -ne 0) { return New-UsageResult -Reason "CLI exited with code $($run.ExitCode)" }

    try {
        $envelope = $run.StdOut | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return New-UsageResult -Reason 'CLI output is not JSON'
    }
    if ($envelope -isnot [pscustomobject]) { return New-UsageResult -Reason 'CLI printed no JSON object' }
    $result = $envelope.PSObject.Properties['result']?.Value
    $isError = $envelope.PSObject.Properties['is_error']?.Value
    if ($isError -ne $false) {
        return New-UsageResult -Reason "CLI reported an error: $(Get-ShortText $result)"
    }
    if ($result -isnot [string]) { return New-UsageResult -Reason 'CLI JSON has no text result' }

    ConvertFrom-UsageText -Text $result -Now $Now
}

function Get-ShortText {
    param($Text, [int] $Max = 200)
    $value = [string]$Text
    if ($value.Length -le $Max) { return $value }
    $value.Substring(0, $Max) + '...'
}
