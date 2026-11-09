BeforeAll {
    $script = Join-Path $PSScriptRoot '..' 'skills' 'fleet-director' 'scripts' 'ask-gemini.ps1'
    $pwshPath = (Get-Process -Id $PID).Path

    # A stand-in for agy: echoes its arguments back as the answer, or fails as told by FAKE_AGY.
    function New-FakeAgy {
        $dir = Join-Path $TestDrive "agy-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        # Its own process, the way agy.exe runs: a .cmd on Windows, a shell script elsewhere.
        if ($IsWindows) {
            $fake = Join-Path $dir 'agy.cmd'
            Set-Content -LiteralPath $fake -Value "@`"$pwshPath`" -NoProfile -File `"%~dp0agy-impl.ps1`" %*"
        } else {
            $fake = Join-Path $dir 'agy'
            Set-Content -LiteralPath $fake -Value "#!/bin/sh`nexec `"$pwshPath`" -NoProfile -File `"`$(dirname `"`$0`")/agy-impl.ps1`" `"`$@`"`n" -NoNewline
            & chmod +x $fake
        }
        Set-Content -LiteralPath (Join-Path $dir 'agy-impl.ps1') -Value @'
$mode = $env:FAKE_AGY
if ($mode -eq 'fail') { [Console]::Error.WriteLine('You are not logged into Antigravity.'); exit 1 }
if ($mode -eq 'error') { [Console]::Out.Write('{"status":"ERROR","response":"quota exhausted"}'); exit 0 }
$answer = @{ status = 'SUCCESS'; response = "ARGS: $($args -join ' | ')"; usage = @{ total_tokens = 10 } } | ConvertTo-Json -Compress
[Console]::Out.Write($answer)
'@
        $fake
    }

    function Invoke-AskGemini {
        param([string[]] $Arguments, [string] $Mode = '')
        $previous = $env:FAKE_AGY
        try {
            $env:FAKE_AGY = $Mode
            $out = & $pwshPath -NoProfile -File $script @Arguments 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out -join "`n") }
        } finally {
            if ($null -eq $previous) { Remove-Item Env:FAKE_AGY -ErrorAction SilentlyContinue } else { $env:FAKE_AGY = $previous }
        }
    }
}

Describe 'skills/fleet-director/scripts/ask-gemini.ps1' {
    It 'runs agy read-only (plan mode, sandbox) and saves the answer marked as unverified' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'answers' 'one.md'
        $project = Join-Path $TestDrive "project-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $project | Out-Null

        $r = Invoke-AskGemini @('-Prompt', 'Resume este texto', '-Out', $out, '-AgyPath', $agy, '-Directory', $project, '-Effort', 'high')

        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '(?m)^status: UNVERIFIED$'
        $text | Should -Match '(?m)^model: gemini-3\.8-flash-high$'
        $text | Should -Match '--mode \| plan'
        $text | Should -Match '--sandbox'
        $text | Should -Match '--model \| gemini-3\.8-flash-high'
        $text | Should -Match '--effort \| high'
        $text | Should -Match 'Resume este texto'
        $text | Should -Not -Match 'dangerously'
        $text | Should -Match '(?m)^folder: '
    }

    It 'without -Directory, runs in an empty folder' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'nodir.md'

        $r = Invoke-AskGemini @('-Prompt', 'hola', '-Out', $out, '-AgyPath', $agy)

        $r.Exit | Should -Be 0
        Get-Content -LiteralPath $out -Raw | Should -Match '(?m)^folder: none$'
    }

    It 'refuses a folder that holds a secret-looking file, and allows .env.example' {
        $agy = New-FakeAgy
        $repo = Join-Path $TestDrive "repo-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path (Join-Path $repo 'config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.env.example') -Value 'KEY='

        $allowed = Invoke-AskGemini @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'ok.md'), '-AgyPath', $agy, '-Directory', $repo)
        $allowed.Exit | Should -Be 0

        Set-Content -LiteralPath (Join-Path $repo 'config' '.env') -Value 'KEY=x'
        $blocked = Invoke-AskGemini @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'no.md'), '-AgyPath', $agy, '-Directory', $repo)
        $blocked.Exit | Should -Be 2
        $blocked.Text | Should -BeLike '*.env*'
    }

    It 'never lets a prompt that starts with a dash read as a flag' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'dash.md'

        $r = Invoke-AskGemini @('-Prompt:--add-dir C:/', '-Out', $out, '-AgyPath', $agy)

        $r.Exit | Should -Be 0
        Get-Content -LiteralPath $out -Raw | Should -Match '-p \| Task: --add-dir C:/'
    }

    It 'hands a long prompt over as a file the model reads, not on the command line' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'long.md'
        $prompt = Join-Path $TestDrive 'prompt.md'
        Set-Content -LiteralPath $prompt -Value ('x' * 30000)

        $r = Invoke-AskGemini @('-PromptFile', $prompt, '-Out', $out, '-AgyPath', $agy)

        $r.Exit | Should -Be 0
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match '--add-dir'
        $text | Should -Not -Match ('x' * 1000)
    }

    It 'blocks a prompt that looks like it carries a secret' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'secret.md'

        $r = Invoke-AskGemini @('-Prompt', 'usa la clave sk-ant-abcdefghijklmnopqrstuvwxyz123', '-Out', $out, '-AgyPath', $agy)

        $r.Exit | Should -Be 2
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'reports a failed run or an error answer with exit code 3' {
        $agy = New-FakeAgy
        $out = Join-Path $TestDrive 'fail.md'

        $failed = Invoke-AskGemini @('-Prompt', 'hola', '-Out', $out, '-AgyPath', $agy) -Mode 'fail'
        $failed.Exit | Should -Be 3
        $failed.Text | Should -BeLike '*not logged into Antigravity*'

        $error = Invoke-AskGemini @('-Prompt', 'hola', '-Out', $out, '-AgyPath', $agy) -Mode 'error'
        $error.Exit | Should -Be 3
        $error.Text | Should -BeLike '*quota exhausted*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'says when agy is not installed (exit 5) and refuses bad arguments (exit 1)' {
        $missing = Invoke-AskGemini @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'm.md'), '-AgyPath', (Join-Path $TestDrive 'no-agy.exe'))
        $missing.Exit | Should -Be 5

        $agy = New-FakeAgy
        $badModel = Invoke-AskGemini @('-Prompt', 'hola', '-Out', (Join-Path $TestDrive 'b.md'), '-AgyPath', $agy, '-Model', 'x; rm -rf /')
        $badModel.Exit | Should -Be 1
        $noPrompt = Invoke-AskGemini @('-Out', (Join-Path $TestDrive 'c.md'), '-AgyPath', $agy)
        $noPrompt.Exit | Should -Be 1
    }
}
