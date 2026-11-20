<#
.SYNOPSIS
    Asks Qwen (Alibaba Cloud Model Studio, OpenAI-compatible API) a read-only question and saves the answer for Claude to verify.
.DESCRIPTION
    One HTTPS call to the chat completions endpoint of Alibaba Cloud Model Studio (DashScope), with no tools:
    the model cannot write files or run commands. It sees only the prompt and, with -Directory, the text
    files this script reads from that folder and puts in the prompt (the API has no file access).

    DATA GOES TO ALIBABA CLOUD servers (default endpoint: Singapore, "international"), outside the EU and the US.
    Send nothing you would not send to a third-party cloud.

    The key is read from the user environment variable named by -ApiKeyEnv (default DASHSCOPE_API_KEY). It is
    never printed, logged or written; error text has it removed.

    Privacy gate, before anything is sent: a prompt or file text that matches a secret pattern is refused
    (exit 2); a folder that holds a secret-looking file (.env, keys, credentials) is refused; files under a
    private path are never read. Private paths: ~/.claude-switch/qwen-private.json,
    {"privatePaths": ["hub/", "C:/work/employer"]}; without that file the defaults are any `hub` folder and any
    .env file. A relative entry matches a folder or file name/path suffix at any depth; an absolute one a path prefix.

    The answer goes to -Out with a header marking it unverified (status: UNVERIFIED). Usage and room: Model
    Studio offers no cheap quota read this script relies on, so usage is `unknown` (never 0 %); the header
    carries the token counts of the call.

    Exit codes: 0 saved, 1 bad arguments (or a prompt over the size limit), 2 blocked by the privacy gate,
    3 the call failed, timed out or answered with an error, 5 no API key in the environment.
.EXAMPLE
    pwsh -NoProfile -File ask-qwen.ps1 -Prompt "Summarise this log: ..." -Out answers/log.md
.EXAMPLE
    pwsh -NoProfile -File ask-qwen.ps1 -PromptFile task.md -Out answers/review.md -Directory C:/repo/src -Model qwen3-coder-plus
#>
[CmdletBinding()]
param(
    [string] $Prompt,
    [string] $PromptFile,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Model = 'qwen3-coder-plus',
    # A folder whose text files are added to the prompt (read-only). Empty: the prompt alone.
    [string] $Directory,
    [int] $TimeoutSeconds = 300,
    # Up to this many characters leave in one call (prompt + folder files); more is refused, not cut.
    [int] $MaxPromptChars = 60000,
    # The answer is cut at this many characters (the header says so).
    [int] $MaxResponseChars = 100000,
    [string] $ApiKeyEnv = 'DASHSCOPE_API_KEY',
    # OpenAI-compatible base URL. https only (http only for localhost, for tests).
    [string] $BaseUrl = 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    [string] $PrivateConfigPath,
    [string] $DataDir
)
$ErrorActionPreference = 'Stop'

# The raw HTTP body is never read past this size.
$MaxBodyBytes = 4MB
# Folder files: only text up to this size each, at most this many.
$MaxFileBytes = 200KB
$MaxFiles = 200
$SecretPatterns = [ordered]@{
    'openai_key'          = 'sk-[A-Za-z0-9_\-]{20,}'
    'aws_access_key'      = 'AKIA[0-9A-Z]{16}'
    'github_token'        = 'gh[pousr]_[A-Za-z0-9]{30,}'
    'google_api_key'      = 'AIza[0-9A-Za-z_\-]{30,}'
    'slack_token'         = 'xox[abprs]-[A-Za-z0-9\-]{10,}'
    'private_key'         = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'bearer_token'        = '(?i)bearer\s+[A-Za-z0-9\-._~+/]{20,}=*'
    'password_assignment' = '(?i)(password|passwd|pwd|secret|api[_-]?key)\s*[:=]\s*\S{6,}'
}
$SecretFiles = '^(\.env(\.(?!example$|sample$|template$|dist$)[\w.-]+)?|.*\.(pem|key|pfx|p12|keystore|jks)|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|\.?credentials(\.json)?|\.netrc|\.npmrc|\.pypirc|secrets?\.(json|ya?ml|toml))$'
$SkipFolders = 'node_modules', '.git', '.venv', 'venv', 'dist', 'build', '.next', 'target'
$BinaryExtensions = '\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|7z|exe|dll|so|bin|woff2?|ttf|mp[34]|mov|lock)$'
$DefaultPrivate = @('hub')

function Stop-With([int] $Code, [string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Hide-Key([string] $Text, [string] $Key) {
    if ($Key -and $Text) { return $Text.Replace($Key, '[key hidden]') }
    $Text
}

function Get-PrivatePath([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $DefaultPrivate }
    try { $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Stop-With 1 "Cannot read $($Path): $($_.Exception.Message)" }
    if ($null -eq $json.privatePaths -or $json.privatePaths -isnot [System.Array]) { Stop-With 1 "$Path needs a `"privatePaths`" list." }
    @($json.privatePaths | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
}

function ConvertTo-Slash([string] $Path) { ($Path -replace '\\', '/').TrimEnd('/') }

# True when the path falls under a private entry (see .DESCRIPTION), or is an .env-type file.
function Test-PrivatePath([string] $FullPath, [string[]] $Private) {
    $p = ConvertTo-Slash $FullPath
    if ((Split-Path -Leaf $FullPath) -match $SecretFiles) { return $true }
    foreach ($entry in $Private) {
        $e = ConvertTo-Slash $entry
        if (-not $e) { continue }
        if ([IO.Path]::IsPathRooted($entry)) {
            if ($p -ieq $e -or $p.StartsWith("$e/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } elseif ("/$p/" -match "(?i)/$([regex]::Escape($e))/") { return $true }
    }
    $false
}

function Find-SecretFile([string] $Root) {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $dir, $depth = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
            if ($item.PSIsContainer) {
                if ($depth -lt 3 -and $item.Name -notin $SkipFolders) { $queue.Enqueue(@($item.FullName, $depth + 1)) }
            } elseif ($item.Name -match $SecretFiles) {
                return $item.FullName
            }
        }
    }
    $null
}

function Find-SecretPattern([string] $Text) {
    foreach ($name in $SecretPatterns.Keys) { if ($Text -match $SecretPatterns[$name]) { return $name } }
    $null
}

# Text files of the folder as one block; private paths skipped; a secret-looking line stops everything.
function Read-FolderContext([string] $Root, [string[]] $Private) {
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    $parts = [System.Collections.Generic.List[string]]::new()
    $skipped = 0
    $count = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
            if ($item.PSIsContainer) {
                if ($item.Name -in $SkipFolders -or (Test-PrivatePath $item.FullName $Private)) { $skipped++; continue }
                $stack.Push($item.FullName)
                continue
            }
            if ((Test-PrivatePath $item.FullName $Private) -or $item.Name -match $BinaryExtensions -or $item.Length -gt $MaxFileBytes) { $skipped++; continue }
            $text = Get-Content -LiteralPath $item.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($text) -or $text.Contains([char]0)) { $skipped++; continue }
            $found = Find-SecretPattern $text
            if ($found) { Stop-With 2 "Blocked: $($item.FullName) looks like it carries a secret ($found). Use a folder without it, or put what Qwen needs in the prompt." }
            if (++$count -gt $MaxFiles) { Stop-With 1 "The folder has more than $MaxFiles text files: point -Directory at a smaller subfolder." }
            $relative = (ConvertTo-Slash $item.FullName).Substring((ConvertTo-Slash $rootFull).Length).TrimStart('/')
            $parts.Add("===== FILE: $relative =====`n$text")
        }
    }
    [pscustomobject]@{ Text = ($parts -join "`n`n"); Files = $count; Skipped = $skipped }
}

if (-not $Prompt -and -not $PromptFile) { Stop-With 1 'Missing -Prompt or -PromptFile.' }
if ($Prompt -and $PromptFile) { Stop-With 1 'Use -Prompt or -PromptFile, not both.' }
if ($Model -notmatch '^[a-z0-9][a-z0-9.\-_]{0,59}$') { Stop-With 1 "Invalid model: $Model (a Model Studio id such as qwen3-coder-plus)." }
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 1800) { Stop-With 1 'TimeoutSeconds goes from 10 to 1800.' }
if ($MaxPromptChars -lt 1000 -or $MaxPromptChars -gt 500000) { Stop-With 1 'MaxPromptChars goes from 1000 to 500000.' }
if ($MaxResponseChars -lt 1000) { Stop-With 1 'MaxResponseChars must be at least 1000.' }
if ($ApiKeyEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$') { Stop-With 1 "Invalid -ApiKeyEnv: $ApiKeyEnv" }
$uri = $null
if (-not [Uri]::TryCreate($BaseUrl.TrimEnd('/') + '/chat/completions', [UriKind]::Absolute, [ref] $uri) -or
    -not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $uri.IsLoopback))) {
    Stop-With 1 'BaseUrl must be an https URL (http only for localhost).'
}
if ($Directory -and -not (Test-Path -LiteralPath $Directory -PathType Container)) { Stop-With 1 "Folder not found: $Directory" }
if (-not $DataDir) { $DataDir = if ($env:SWITCH_DATA_DIR) { $env:SWITCH_DATA_DIR } else { Join-Path $HOME '.claude-switch' } }
if (-not $PrivateConfigPath) { $PrivateConfigPath = Join-Path $DataDir 'qwen-private.json' }
$private = @(Get-PrivatePath $PrivateConfigPath)

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Stop-With 1 "File not found: $PromptFile" }
    if (Test-PrivatePath (Resolve-Path -LiteralPath $PromptFile).Path $private) { Stop-With 2 "Blocked: $PromptFile is under a private path." }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}
$found = Find-SecretPattern $Prompt
if ($found) { Stop-With 2 "Blocked: the prompt looks like it carries a secret ($found). Remove it and try again." }

$context = $null
if ($Directory) {
    $dirFull = (Resolve-Path -LiteralPath $Directory).Path
    if (Test-PrivatePath $dirFull $private) { Stop-With 2 "Blocked: $dirFull is under a private path." }
    $secretFile = Find-SecretFile -Root $dirFull
    if ($secretFile) { Stop-With 2 "Blocked: the folder holds a file that may keep secrets ($secretFile). Use a subfolder without it, or put what Qwen needs in the prompt." }
    $context = Read-FolderContext -Root $dirFull -Private $private
}

$content = if ($context -and $context.Text) { "$Prompt`n`n(Read-only context: files from the folder follow.)`n`n$($context.Text)" } else { $Prompt }
if ($content.Length -gt $MaxPromptChars) {
    Stop-With 1 "The request is $($content.Length) characters; the limit is $MaxPromptChars. Split it (a smaller folder, one part of the diff per call) or raise -MaxPromptChars. Nothing was sent."
}

$apiKey = [Environment]::GetEnvironmentVariable($ApiKeyEnv)
if (-not $apiKey) { Stop-With 5 "No API key: set the user environment variable $ApiKeyEnv (see README, 'Qwen'). Nothing was sent." }

$body = @{
    model    = $Model
    messages = @(@{ role = 'user'; content = $content })
    stream   = $false
} | ConvertTo-Json -Depth 5 -Compress

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
try {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $apiKey)
    $request.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $stream = $response.Content.ReadAsStream()
        $buffer = [IO.MemoryStream]::new()
        $chunk = [byte[]]::new(65536)
        while (($n = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
            $buffer.Write($chunk, 0, $n)
            if ($buffer.Length -gt $MaxBodyBytes) { Stop-With 3 "The answer is over $($MaxBodyBytes / 1MB) MB; it was dropped." }
        }
        $raw = [Text.Encoding]::UTF8.GetString($buffer.ToArray())
    } catch [System.Threading.Tasks.TaskCanceledException] {
        Stop-With 3 "Qwen did not answer in $TimeoutSeconds s."
    } catch [System.Net.Http.HttpRequestException] {
        Stop-With 3 "The call failed: $(Hide-Key $_.Exception.Message $apiKey)"
    }
    if (-not $response.IsSuccessStatusCode) {
        $why = Hide-Key $raw $apiKey
        if ($why.Length -gt 600) { $why = $why.Substring(0, 600) }
        Stop-With 3 "Qwen answered HTTP $([int]$response.StatusCode): $why"
    }
    try { $answer = $raw | ConvertFrom-Json } catch { Stop-With 3 'Qwen answered with something that is not JSON.' }
    $text = $answer.choices[0].message.content
    if (-not $text) { Stop-With 3 'Qwen answered with no text.' }
} finally {
    $client.Dispose()
}

$cut = $text.Length -gt $MaxResponseChars
if ($cut) { $text = $text.Substring(0, $MaxResponseChars) + "`n`n[Answer cut at $MaxResponseChars characters.]" }
$tokens = if ($answer.usage) { "$($answer.usage.prompt_tokens) in / $($answer.usage.completion_tokens) out" } else { 'unknown' }
$header = @(
    '---'
    'source: Qwen (Alibaba Cloud Model Studio)'
    "model: $Model"
    "folder: $(if ($Directory) { "$($context.Files) files from $dirFull ($($context.Skipped) skipped)" } else { 'none' })"
    "tokens: $tokens"
    'usage: unknown'
    "cut: $(if ($cut) { 'yes' } else { 'no' })"
    "date: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))"
    'status: UNVERIFIED'
    '---'
    ''
) -join "`n"
$outDir = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Set-Content -LiteralPath $Out -Value ($header + $text) -Encoding utf8NoBOM
Write-Output "Saved: $Out ($Model; tokens: $tokens)"
exit 0
