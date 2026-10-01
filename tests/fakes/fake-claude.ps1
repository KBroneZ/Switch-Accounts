# Test double for the Claude Code CLI. Never contacts any service.
# Behaviour is driven by files inside $env:CLAUDE_CONFIG_DIR, so each fake
# account answers differently and the tests can prove which config dir was used:
#   fake-usage.json     body printed for `-p /usage`
#   fake-session.jsonl  lines printed for any other `-p` prompt (stream-json)
#   fake-exit-code.txt  exit code (default 0)
#   fake-sleep.txt      seconds to sleep before answering
# Every call is appended to fake-calls.jsonl with its arguments and working dir.
$ErrorActionPreference = 'Stop'
$configDir = $env:CLAUDE_CONFIG_DIR
if (-not $configDir) {
    [Console]::Error.WriteLine('fake-claude: CLAUDE_CONFIG_DIR not set')
    exit 97
}

$call = [ordered]@{ args = @($args); cwd = (Get-Location).Path }
Add-Content -LiteralPath (Join-Path $configDir 'fake-calls.jsonl') -Value ($call | ConvertTo-Json -Compress -Depth 5)

$sleepFile = Join-Path $configDir 'fake-sleep.txt'
if (Test-Path -LiteralPath $sleepFile) { Start-Sleep -Seconds ([int](Get-Content -LiteralPath $sleepFile -Raw)) }

$promptIndex = [Array]::IndexOf([string[]]$args, '-p')
$prompt = if ($promptIndex -ge 0 -and $promptIndex + 1 -lt $args.Count) { $args[$promptIndex + 1] } else { '' }
$bodyFile = if ($prompt -eq '/usage') { 'fake-usage.json' } else { 'fake-session.jsonl' }
$bodyPath = Join-Path $configDir $bodyFile
if (Test-Path -LiteralPath $bodyPath) {
    [Console]::Out.Write((Get-Content -LiteralPath $bodyPath -Raw))
}

$exitFile = Join-Path $configDir 'fake-exit-code.txt'
$exitCode = if (Test-Path -LiteralPath $exitFile) { [int](Get-Content -LiteralPath $exitFile -Raw) } else { 0 }
exit $exitCode
