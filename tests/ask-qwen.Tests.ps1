BeforeAll {
    $script = Join-Path $PSScriptRoot '..' 'skills' 'fleet-director' 'scripts' 'ask-qwen.ps1'
    $serverScript = Join-Path $PSScriptRoot 'fakes' 'fake-qwen-server.ps1'
    $pwshPath = (Get-Process -Id $PID).Path
    $script:TestKey = 'test-key-not-a-real-one-123'

    function Start-FakeQwen {
        $port = Get-Random -Minimum 20000 -Maximum 60000
        $proc = Start-Process -FilePath $pwshPath -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-File', $serverScript, '-Port', $port, '-ExpectedKey', $script:TestKey)
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            try { $c = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $c.Dispose(); break } catch { Start-Sleep -Milliseconds 200 }
        }
        [pscustomobject]@{ Port = $port; Process = $proc; Url = "http://127.0.0.1:$port" }
    }

    function Invoke-AskQwen {
        param([string[]] $Arguments, [string] $Key = $script:TestKey)
        $names = 'DASHSCOPE_API_KEY', 'NEXUS_QWEN_API_KEY'
        $previous = @{}
        foreach ($n in $names) { $previous[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $(if ($Key) { $Key } else { $null })) }
            $out = & $pwshPath -NoProfile -File $script @Arguments 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out -join "`n") }
        } finally {
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $previous[$n]) }
        }
    }
    $script:NoPrivate = Join-Path $TestDrive 'none.json'
}

Describe 'skills/fleet-director/scripts/ask-qwen.ps1' {
    BeforeAll { $script:fake = Start-FakeQwen }
    AfterAll { if ($script:fake.Process -and -not $script:fake.Process.HasExited) { $script:fake.Process.Kill() } }

    It 'sends the prompt with the key, no tools, and saves the answer marked unverified' {
        $out = Join-Path $TestDrive 'answers' 'one.md'
        $r = Invoke-AskQwen @('-Prompt', 'Resume este texto', '-Out', $out, '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)

        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '(?m)^status: UNVERIFIED$'
        $text | Should -Match '(?m)^model: qwen3-coder-plus$'
        $text | Should -Match '(?m)^usage: unknown$'
        $text | Should -Match '(?m)^tokens: 7 in / 3 out$'
        $text | Should -Match 'AUTH_OK'
        $text | Should -Match 'PATH=/chat/completions'
        $text | Should -Match 'TOOLS=False'
        $text | Should -Match 'PROMPT=Resume este texto'
        $text | Should -Not -Match $script:TestKey
        $r.Text | Should -Not -Match $script:TestKey
    }

    It 'adds the text files of -Directory to the prompt, skipping private paths and binaries' {
        $dir = Join-Path $TestDrive "ctx-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path (Join-Path $dir 'src'), (Join-Path $dir 'hub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'src' 'a.txt') -Value 'FILE_A_CONTENT'
        Set-Content -LiteralPath (Join-Path $dir 'hub' 'notes.txt') -Value 'HUB_PRIVATE_NOTE'
        Set-Content -LiteralPath (Join-Path $dir 'image.png') -Value 'PNGDATA'
        $out = Join-Path $TestDrive 'ctx.md'

        $r = Invoke-AskQwen @('-Prompt', 'Revisa', '-Out', $out, '-BaseUrl', $fake.Url, '-Directory', $dir, '-DataDir', $TestDrive)

        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match 'FILE: src/a\.txt'
        $text | Should -Match 'FILE_A_CONTENT'
        $text | Should -Not -Match 'HUB_PRIVATE_NOTE'
        $text | Should -Not -Match 'PNGDATA'
        $text | Should -Match '(?m)^folder: 1 files from '
    }

    It 'refuses a prompt that looks like a secret, and sends nothing' {
        $out = Join-Path $TestDrive 'secret.md'
        $r = Invoke-AskQwen @('-Prompt', 'use key sk-abcdefghijklmnopqrstuvwxyz123456', '-Out', $out, '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 2
        $r.Text | Should -Match 'Blocked'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'refuses a folder with a secret-looking file, allows .env.example' {
        $repo = Join-Path $TestDrive "repo-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.env.example') -Value 'KEY='
        (Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'ok.md'), '-BaseUrl', $fake.Url, '-Directory', $repo, '-DataDir', $TestDrive)).Exit | Should -Be 0
        Set-Content -LiteralPath (Join-Path $repo '.env') -Value 'A=1'
        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'no.md'), '-BaseUrl', $fake.Url, '-Directory', $repo, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 2
        $r.Text | Should -Match '\.env'
    }

    It 'blocks a file in -Directory whose text carries a secret' {
        $repo = Join-Path $TestDrive "repo-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'config.txt') -Value 'password = hunter2hunter2'
        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'p.md'), '-BaseUrl', $fake.Url, '-Directory', $repo, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 2
        $r.Text | Should -Match 'config\.txt'
    }

    It 'honours private paths from the config (folder, subfolder and prompt file)' {
        $dir = Join-Path $TestDrive "priv-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path (Join-Path $dir 'client') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'client' 'x.txt') -Value 'CLIENT_SECRET_DATA'
        Set-Content -LiteralPath (Join-Path $dir 'ok.txt') -Value 'PUBLIC_DATA'
        $config = Join-Path $TestDrive 'private.json'
        Set-Content -LiteralPath $config -Value (@{ privatePaths = @('client', (Join-Path $TestDrive 'secret-area')) } | ConvertTo-Json)
        $out = Join-Path $TestDrive 'priv.md'

        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', $out, '-BaseUrl', $fake.Url, '-Directory', $dir, '-PrivateConfigPath', $config)
        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match 'PUBLIC_DATA'
        $text | Should -Not -Match 'CLIENT_SECRET_DATA'

        $r2 = Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'priv2.md'), '-BaseUrl', $fake.Url, '-Directory', (Join-Path $dir 'client'), '-PrivateConfigPath', $config)
        $r2.Exit | Should -Be 2

        $area = Join-Path $TestDrive 'secret-area'
        New-Item -ItemType Directory -Path $area | Out-Null
        Set-Content -LiteralPath (Join-Path $area 'p.md') -Value 'hola'
        (Invoke-AskQwen @('-PromptFile', (Join-Path $area 'p.md'), '-Out', (Join-Path $TestDrive 'priv3.md'), '-BaseUrl', $fake.Url, '-PrivateConfigPath', $config)).Exit | Should -Be 2
    }

    It 'by default refuses a hub folder' {
        $dir = Join-Path $TestDrive "work-$([guid]::NewGuid())" 'hub'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'h.md'), '-BaseUrl', $fake.Url, '-Directory', $dir, '-PrivateConfigPath', $script:NoPrivate)
        $r.Exit | Should -Be 2
    }

    It 'refuses an oversize request clearly and sends nothing' {
        $r = Invoke-AskQwen @('-Prompt', ('a' * 3000), '-Out', (Join-Path $TestDrive 'big.md'), '-BaseUrl', $fake.Url, '-MaxPromptChars', '1000', '-DataDir', $TestDrive)
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'Split it'
        Test-Path -LiteralPath (Join-Path $TestDrive 'big.md') | Should -BeFalse
    }

    It 'exit 5 with no API key, naming the variable' {
        # A variable name nobody sets, so a key kept in the real User scope cannot leak into the test.
        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'nokey.md'), '-BaseUrl', $fake.Url, '-DataDir', $TestDrive, '-ApiKeyEnv', 'NO_SUCH_QWEN_KEY_VAR') -Key ''
        $r.Exit | Should -Be 5
        $r.Text | Should -Match 'NO_SUCH_QWEN_KEY_VAR'
    }

    It 'provider presets: alibaba is the default, nexus sets URL, key variable and model' {
        $a = Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'a.md'), '-ShowConfig', '-DataDir', $TestDrive)
        $a.Exit | Should -Be 0
        $a.Text | Should -Be 'provider=alibaba url=https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions model=qwen3-coder-plus keyEnv=DASHSCOPE_API_KEY'
        $n = Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'n.md'), '-Provider', 'nexus', '-ShowConfig', '-DataDir', $TestDrive)
        $n.Exit | Should -Be 0
        $n.Text | Should -Be 'provider=nexus url=https://api.nexusapi.co/qwen/v1/chat/completions model=Qwen3.8-Max-fast-agent keyEnv=NEXUS_QWEN_API_KEY'
        $n.Text | Should -Not -Match $script:TestKey
    }

    It 'explicit -BaseUrl, -ApiKeyEnv and -Model override the preset' {
        $r = Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'o.md'), '-Provider', 'nexus', '-BaseUrl', 'https://example.test/v9', '-ApiKeyEnv', 'MY_OTHER_KEY', '-Model', 'Qwen3.8-Max-thinking-agent', '-ShowConfig', '-DataDir', $TestDrive)
        $r.Text | Should -Be 'provider=nexus url=https://example.test/v9/chat/completions model=Qwen3.8-Max-thinking-agent keyEnv=MY_OTHER_KEY'
    }

    It 'accepts mixed-case model ids and still rejects odd characters' {
        foreach ($m in 'Qwen3.8-Max-agent', 'Qwen3.8-Max-fast-agent', 'Qwen3.8-Max-thinking-agent') {
            (Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'm.md'), '-Model', $m, '-ShowConfig', '-DataDir', $TestDrive)).Exit | Should -Be 0
        }
        (Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'm.md'), '-Model', 'Qwen 3;rm', '-DataDir', $TestDrive)).Exit | Should -Be 1
        (Invoke-AskQwen @('-Prompt', 'x', '-Out', (Join-Path $TestDrive 'm.md'), '-Model', ('A' * 61), '-DataDir', $TestDrive)).Exit | Should -Be 1
    }

    It 'nexus route: header names the reseller honestly, key and model reach the server' {
        $out = Join-Path $TestDrive 'nexus.md'
        $r = Invoke-AskQwen @('-Prompt', 'hola', '-Out', $out, '-Provider', 'nexus', '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '(?m)^source: Qwen via third-party reseller nexusapi\.co \(unverified\)$'
        $text | Should -Match '(?m)^status: UNVERIFIED$'
        $text | Should -Match '(?m)^model: Qwen3\.8-Max-fast-agent$'
        $text | Should -Match 'AUTH_OK'
        $text | Should -Not -Match $script:TestKey
    }

    It 'nexus route keeps the privacy gate on' {
        $out = Join-Path $TestDrive 'nexus-secret.md'
        $r = Invoke-AskQwen @('-Prompt', 'password = hunter2hunter2', '-Out', $out, '-Provider', 'nexus', '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 2
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'a 401 says the reseller key was rejected or expired, without a stack trace or the key' {
        $r = Invoke-AskQwen @('-Prompt', 'FAKE_HTTP401', '-Out', (Join-Path $TestDrive 'e401.md'), '-Provider', 'nexus', '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'reseller key rejected or expired \(HTTP 401\)'
        $r.Text | Should -Not -Match 'at <ScriptBlock>|StackTrace'
        $r.Text | Should -Not -Match $script:TestKey
        $a = Invoke-AskQwen @('-Prompt', 'FAKE_HTTP401', '-Out', (Join-Path $TestDrive 'e401b.md'), '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $a.Text | Should -Match 'Alibaba key rejected or expired'
    }

    It 'exit 3 on an HTTP error, and never prints the key' {
        $r = Invoke-AskQwen @('-Prompt', 'FAKE_HTTP500', '-Out', (Join-Path $TestDrive 'e.md'), '-BaseUrl', $fake.Url, '-DataDir', $TestDrive)
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'HTTP 500'
        $r.Text | Should -Not -Match $script:TestKey
        $r.Text | Should -Match 'key hidden'
    }

    It 'cuts an answer over -MaxResponseChars and says so' {
        $out = Join-Path $TestDrive 'cut.md'
        $r = Invoke-AskQwen @('-Prompt', 'FAKE_BIGANSWER', '-Out', $out, '-BaseUrl', $fake.Url, '-MaxResponseChars', '1000', '-DataDir', $TestDrive)
        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '(?m)^cut: yes$'
        $text | Should -Match 'Answer cut at 1000'
    }

    It 'exit 3 on a timeout' {
        $r = Invoke-AskQwen @('-Prompt', 'FAKE_SLOW', '-Out', (Join-Path $TestDrive 't.md'), '-BaseUrl', $fake.Url, '-TimeoutSeconds', '10', '-DataDir', $TestDrive)
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'did not answer'
    }

    It 'rejects bad arguments: plain http to a remote host, both prompts, a bad model' {
        $out = Join-Path $TestDrive 'bad.md'
        (Invoke-AskQwen @('-Prompt', 'x', '-Out', $out, '-BaseUrl', 'http://example.com/v1')).Exit | Should -Be 1
        (Invoke-AskQwen @('-Prompt', 'x', '-PromptFile', 'y', '-Out', $out)).Exit | Should -Be 1
        (Invoke-AskQwen @('-Prompt', 'x', '-Out', $out, '-Model', 'bad model!')).Exit | Should -Be 1
        (Invoke-AskQwen @('-Out', $out)).Exit | Should -Be 1
    }
}
