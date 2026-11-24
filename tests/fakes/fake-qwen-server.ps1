# A stand-in for the Model Studio chat endpoint, for tests: listens on 127.0.0.1:<Port>/chat/completions.
# The prompt picks the behaviour: FAKE_HTTP500, FAKE_SLOW, FAKE_BIGANSWER; else it echoes the request
# (model, prompt, whether the Authorization header carried the expected key) as the answer.
param([Parameter(Mandatory)] [int] $Port, [Parameter(Mandatory)] [string] $ExpectedKey, [int] $Requests = 50)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
try {
    for ($i = 0; $i -lt $Requests; $i++) {
        $ctx = $listener.GetContext()
        $reader = [IO.StreamReader]::new($ctx.Request.InputStream, [Text.Encoding]::UTF8)
        $req = $reader.ReadToEnd() | ConvertFrom-Json
        $prompt = $req.messages[0].content
        $auth = if ($ctx.Request.Headers['Authorization'] -eq "Bearer $ExpectedKey") { 'AUTH_OK' } else { 'AUTH_BAD' }
        $status = 200
        if ($prompt -match 'FAKE_HTTP401') {
            $status = 401
            $payload = 'unauthorized'
        } elseif ($prompt -match 'FAKE_HTTP500') {
            $status = 500
            $payload = "server error, your key was $ExpectedKey"
        } elseif ($prompt -match 'FAKE_BIGANSWER') {
            $payload = @{ choices = @(@{ message = @{ content = ('x' * 5000) } }); usage = @{ prompt_tokens = 1; completion_tokens = 2 } } | ConvertTo-Json -Depth 6 -Compress
        } else {
            if ($prompt -match 'FAKE_SLOW') { Start-Sleep -Seconds 20 }
            $echo = "MODEL=$($req.model) $auth PATH=$($ctx.Request.Url.AbsolutePath) TOOLS=$([bool]$req.tools) PROMPT=$prompt"
            $payload = @{ choices = @(@{ message = @{ content = $echo } }); usage = @{ prompt_tokens = 7; completion_tokens = 3 } } | ConvertTo-Json -Depth 6 -Compress
        }
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $ctx.Response.StatusCode = $status
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        } catch { }
    }
} finally { $listener.Stop() }
