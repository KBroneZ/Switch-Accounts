# Builds the Windows Terminal tab that starts one Claude Code session.

# Variables that a Claude Code session (mostly the desktop app's) leaves to its child processes:
# session markers, identity and OAuth of its own account, host settings. A session started for
# another account must not carry them. CLAUDE_CONFIG_DIR is removed and set again below.
$script:InheritedSessionPattern = '^(CLAUDECODE|CLAUDE_\w*|ANTHROPIC_\w*|MCP_\w*|OTEL_\w*|USE_LOCAL_OAUTH|USE_STAGING_OAUTH|DISABLE_AUTOUPDATER|DISABLE_MICROCOMPACT)$'

function Test-PersistentVariable {
    <# True when the user stored the variable in the Windows user or machine environment. #>
    param([Parameter(Mandatory)] [string] $Name)
    if (-not $IsWindows) { return $false }
    $null -ne [Environment]::GetEnvironmentVariable($Name, 'User') -or $null -ne [Environment]::GetEnvironmentVariable($Name, 'Machine')
}

function Get-InheritedSessionVariable {
    <# Names the launching session passes on that the new tab must drop; the user's own stored ones stay. #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Names,
        [scriptblock] $IsPersistent = { param($n) Test-PersistentVariable -Name $n }
    )
    @($Names | Where-Object { $_ -match $script:InheritedSessionPattern -and -not (& $IsPersistent $_) } | Sort-Object -Unique)
}

function New-LaunchCommand {
    <#
      The script the tab runs and the arguments for `wt`. The script travels as -EncodedCommand
      because wt breaks on ';' and quotes. It first drops inherited session variables, then sets
      the account (a $null ConfigDir means the default dir, so CLAUDE_CONFIG_DIR is removed),
      then starts the CLI. --remote-control always gets an explicit name: without one it would
      swallow the prompt as its optional value.
    #>
    param(
        [Parameter(Mandatory)] [string] $AccountName,
        [AllowNull()] [string] $ConfigDir,
        [Parameter(Mandatory)] [string] $ClaudePath,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $Title,
        [AllowNull()] [string] $RemoteControlName,
        [AllowNull()] [string] $Model,
        [AllowNull()] [string] $Effort,
        [AllowNull()] [string] $SubagentModel,
        [AllowNull()] [string] $InitialPrompt
    )
    $cliArgs = [System.Collections.Generic.List[string]]::new()
    if ($RemoteControlName) { $cliArgs.Add("--remote-control $(ConvertTo-PsLiteral $RemoteControlName)") }
    if ($Model) { $cliArgs.Add("--model $(ConvertTo-PsLiteral $Model)") }
    if ($Effort) { $cliArgs.Add("--effort $(ConvertTo-PsLiteral $Effort)") }
    if ($InitialPrompt) { $cliArgs.Add((ConvertTo-PsLiteral $InitialPrompt)) }

    $dropLine = ("@(Get-ChildItem Env:) | Where-Object {{ `$_.Name -match {0} -and `$null -eq [Environment]::GetEnvironmentVariable(`$_.Name, 'User') " +
        "-and `$null -eq [Environment]::GetEnvironmentVariable(`$_.Name, 'Machine') }} | ForEach-Object {{ Remove-Item -LiteralPath ('Env:' + `$_.Name) }}") -f
        (ConvertTo-PsLiteral $script:InheritedSessionPattern)
    $accountLine = if ($ConfigDir) { "`$env:CLAUDE_CONFIG_DIR = $(ConvertTo-PsLiteral $ConfigDir)" }
    else { 'Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue' }
    $script = @(
        $dropLine
        $accountLine
        if ($SubagentModel) { "`$env:CLAUDE_CODE_SUBAGENT_MODEL = $(ConvertTo-PsLiteral $SubagentModel)" }
        "Set-Location -LiteralPath $(ConvertTo-PsLiteral $WorkingDirectory)"
        "& $(ConvertTo-PsLiteral $ClaudePath) $($cliArgs -join ' ')".TrimEnd()
    ) -join "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    [pscustomobject]@{
        AccountName = $AccountName
        Script      = $script
        WtArguments = @('-w', '0', 'new-tab', '--title', $Title, '--suppressApplicationTitle',
            'pwsh', '-NoExit', '-EncodedCommand', $encoded)
    }
}

function Start-TerminalTab {
    <# Hands the arguments to Windows Terminal. Does not wait for the session. #>
    param([Parameter(Mandatory)] [string] $WtPath, [Parameter(Mandatory)] [string[]] $Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($WtPath)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        # wt hands the tab to its window and exits at once; a hang means something is wrong.
        if (-not $process.WaitForExit(15000)) { throw 'Windows Terminal did not answer within 15 s.' }
        if ($process.ExitCode -ne 0) { throw "Windows Terminal exited with code $($process.ExitCode)." }
    } finally {
        $process.Dispose()
    }
}

function Find-ClaudeCli {
    <# `claude` from PATH; otherwise the newest binary that the desktop app ships. $null if none. #>
    $onPath = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $roots = @()
    if ($env:LOCALAPPDATA) {
        $roots += Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalCache/Roaming/Claude/claude-code' }
    }
    if ($env:APPDATA) { $roots += Join-Path $env:APPDATA 'Claude/claude-code' }
    $found = foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $exe = Join-Path $_.FullName 'claude.exe'
            $version = $null
            if ((Test-Path -LiteralPath $exe) -and [version]::TryParse($_.Name, [ref]$version)) {
                [pscustomobject]@{ Path = $exe; Version = $version }
            }
        }
    }
    ($found | Sort-Object Version -Descending | Select-Object -First 1)?.Path
}
