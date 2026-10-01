# Test double for the GitHub CLI. Never contacts GitHub.
# Logs each call to $env:FAKE_GH_DIR/gh-calls.jsonl; `pr create` prints a PR URL with an
# increasing number; `pr comment` stores the body it was given.
$ErrorActionPreference = 'Stop'
$dir = $env:FAKE_GH_DIR
if (-not $dir) { [Console]::Error.WriteLine('fake-gh: FAKE_GH_DIR not set'); exit 97 }

$entry = [ordered]@{ args = @($args); cwd = (Get-Location).Path; body = $null }
$bodyIndex = [Array]::IndexOf([string[]]$args, '--body-file')
if ($bodyIndex -ge 0) { $entry.body = Get-Content -LiteralPath $args[$bodyIndex + 1] -Raw }
Add-Content -LiteralPath (Join-Path $dir 'gh-calls.jsonl') -Value ($entry | ConvertTo-Json -Compress -Depth 5)

if ($args[0] -eq 'pr' -and $args[1] -eq 'create') {
    $counter = Join-Path $dir 'pr-counter.txt'
    $n = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) + 1 } else { 1 }
    Set-Content -LiteralPath $counter -Value $n -NoNewline
    [Console]::Out.WriteLine("https://github.com/example/repo/pull/$n")
}
exit 0
