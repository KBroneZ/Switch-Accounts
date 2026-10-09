# Test double for the Claude Code CLI. Never contacts any service.
# Behaviour is driven by files inside $env:CLAUDE_CONFIG_DIR, so each fake
# account answers differently and the tests can prove which config dir was used:
#   fake-usage.json           body printed for `-p /usage`
#   fake-session.jsonl        lines printed for any other prompt; a line "#sleep N" sleeps N seconds
#   fake-session-action.ps1   script run in the working dir before printing (e.g. make a commit)
#   fake-exit-code.txt        exit code (default 0)
#   fake-sleep.txt            seconds to sleep before answering
# Every call is appended to fake-calls.jsonl with its arguments, working dir and prompt.
$ErrorActionPreference = 'Stop'
# The callers read stdout as UTF-8; without this a non-UTF-8 console code page garbles the middle dot of /usage.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$configDir = $env:CLAUDE_CONFIG_DIR
if (-not $configDir) {
    [Console]::Error.WriteLine('fake-claude: CLAUDE_CONFIG_DIR not set')
    exit 97
}

$printIndex = [Array]::IndexOf([string[]]$args, '-p')
$prompt = if ($printIndex -ge 0 -and $printIndex + 1 -lt $args.Count -and -not "$($args[$printIndex + 1])".StartsWith('-')) {
    $args[$printIndex + 1]
} else {
    [Console]::In.ReadToEnd()
}

$call = [ordered]@{ args = @($args); cwd = (Get-Location).Path; prompt = $prompt }
Add-Content -LiteralPath (Join-Path $configDir 'fake-calls.jsonl') -Value ($call | ConvertTo-Json -Compress -Depth 5)

$sleepFile = Join-Path $configDir 'fake-sleep.txt'
if (Test-Path -LiteralPath $sleepFile) { Start-Sleep -Seconds ([int](Get-Content -LiteralPath $sleepFile -Raw)) }

if ($prompt -eq '/usage') {
    $usage = Join-Path $configDir 'fake-usage.json'
    if (Test-Path -LiteralPath $usage) { [Console]::Out.Write((Get-Content -LiteralPath $usage -Raw)) }
} else {
    $action = Join-Path $configDir 'fake-session-action.ps1'
    if (Test-Path -LiteralPath $action) { & $action | Out-Null }
    $session = Join-Path $configDir 'fake-session.jsonl'
    if (Test-Path -LiteralPath $session) {
        foreach ($line in Get-Content -LiteralPath $session) {
            if ($line -match '^#sleep (\d+)$') { Start-Sleep -Seconds ([int]$Matches[1]); continue }
            [Console]::Out.WriteLine($line)
            [Console]::Out.Flush()
        }
    }
}

$exitFile = Join-Path $configDir 'fake-exit-code.txt'
$exitCode = if (Test-Path -LiteralPath $exitFile) { [int](Get-Content -LiteralPath $exitFile -Raw) } else { 0 }
exit $exitCode
