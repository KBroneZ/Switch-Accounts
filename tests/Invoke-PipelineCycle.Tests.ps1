BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fakeClaude = Get-FakeClaudePath
    $fakeGh = Join-Path $PSScriptRoot 'fakes' 'fake-gh.ps1'

    function Invoke-Git { git @args 2>&1 | Out-String }

    function New-TestRepo {
        $root = Join-Path $TestDrive "repo-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $origin = Join-Path $root 'origin.git'
        $clone = Join-Path $root 'work'
        git init -q --bare -b main $origin
        git clone -q $origin $clone 2>$null
        git -C $clone config user.email 'pipeline@example.invalid'
        git -C $clone config user.name 'Pipeline Test'
        Set-Content -LiteralPath (Join-Path $clone 'README.md') -Value 'demo'
        git -C $clone add -A; git -C $clone commit -q -m 'init'; git -C $clone push -q origin main 2>$null
        $queue = New-Item -ItemType Directory -Path (Join-Path $root 'queue')
        [pscustomobject]@{ Root = $root; Origin = $origin; Clone = $clone; Queue = $queue.FullName; State = (Join-Path $root 'state') }
    }

    function Add-QueueTask {
        param($Repo, [string] $Name, [string] $Body = 'Add a file.')
        Set-Content -LiteralPath (Join-Path $Repo.Queue $Name) -Value "---`nstatus: ready`ntier: R1`nauto: true`ngates: []`n---`n`n$Body`n"
    }

    function New-PipelineAccount {
        param([string] $Name, [string] $Percent = '10')
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "acct-$Name-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent $Percent)
        [pscustomobject]@{ Name = $Name; ConfigDir = $dir; MaxFiveHourPercent = 70 }
    }

    function Set-ImplementerCommits {
        # The fake implementer commits one file per session in its working dir.
        param($Account, [string] $Final = 'Implemented.')
        Set-Content -LiteralPath (Join-Path $Account.ConfigDir 'fake-session-action.ps1') -Value @'
$name = "change-$([guid]::NewGuid().ToString('N').Substring(0, 6)).txt"
Set-Content -LiteralPath $name -Value 'x'
git add -A; git -c user.email=a@example.invalid -c user.name=A commit -q -m "change $name"
'@
        Set-SessionResult -Account $Account -Text $Final
    }

    function Set-SessionResult {
        param($Account, [string] $Text)
        $result = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $Text; num_turns = 2; session_id = "s-$($Account.Name)" }
        Set-Content -LiteralPath (Join-Path $Account.ConfigDir 'fake-session.jsonl') -Value ($result | ConvertTo-Json -Compress)
    }

    function Get-SessionCalls {
        param($Account)
        @(Get-FakeCalls -ConfigDir $Account.ConfigDir | Where-Object { $_.prompt -ne '/usage' })
    }

    function Get-GhCalls { @(Get-Content -LiteralPath (Join-Path $env:FAKE_GH_DIR 'gh-calls.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }

    function Invoke-Cycle {
        param($Repo, $A, $B, [hashtable] $Extra = @{})
        Invoke-PipelineCycle -RepoPath $Repo.Clone -QueueDir $Repo.Queue -StateDir $Repo.State `
            -AccountA $A -AccountB $B -ClaudePath $fakeClaude -GhPath $fakeGh @Extra
    }

    function Get-TaskState {
        param($Repo, [string] $Id)
        (Get-Content -LiteralPath (Join-Path $Repo.State 'state.json') -Raw | ConvertFrom-Json).tasks.$Id
    }
}

Describe 'Invoke-PipelineCycle' {
    BeforeEach {
        $env:FAKE_GH_DIR = (New-Item -ItemType Directory -Path (Join-Path $TestDrive "gh-$([guid]::NewGuid())")).FullName
        $repo = New-TestRepo
        $a = New-PipelineAccount -Name 'A'
        $b = New-PipelineAccount -Name 'B'
        Set-ImplementerCommits -Account $a
        Set-SessionResult -Account $b -Text "VERDICT: APPROVED`nNo findings."
    }
    AfterEach { Remove-Item Env:FAKE_GH_DIR -ErrorAction SilentlyContinue }

    It 'A implements the first task on its own branch, pushes it and opens a PR' {
        Add-QueueTask $repo '001-add-file.md'

        $cycle = Invoke-Cycle $repo $a $b

        $cycle.Implementer.Outcome | Should -Be 'Completed'
        $cycle.Reviewer | Should -BeNullOrEmpty
        git -C $repo.Origin branch --list 'auto/001-add-file' | Should -Not -BeNullOrEmpty
        git -C $repo.Origin rev-parse main | Should -Be (git -C $repo.Clone rev-parse origin/main)
        $state = Get-TaskState $repo '001'
        $state.status | Should -Be 'in-review'
        $state.pr | Should -Be 1
        $create = Get-GhCalls | Where-Object { $_.args[1] -eq 'create' }
        ($create.args -join ' ') | Should -Match '--head auto/001-add-file'
        ($create.args -join ' ') | Should -Match '--base main'
        (Get-SessionCalls $a)[0].prompt | Should -Match 'Add a file\.'
    }

    It 'B reviews task N while A implements task N+1, each in its own worktree and branch' {
        Add-QueueTask $repo '001-first.md'
        Add-QueueTask $repo '002-second.md'
        Invoke-Cycle $repo $a $b | Out-Null

        $cycle = Invoke-Cycle $repo $a $b

        $cycle.Implementer.Task | Should -Be '002'
        $cycle.Reviewer.Task | Should -Be '001'
        $aCall = (Get-SessionCalls $a)[-1]
        $bCall = (Get-SessionCalls $b)[0]
        $aCall.cwd | Should -Not -Be $bCall.cwd
        $bCall.prompt | Should -Match '#1'
        git -C $bCall.cwd rev-parse HEAD | Should -Be (git -C $repo.Origin rev-parse 'auto/001-first')
        (Get-TaskState $repo '001').status | Should -Be 'approved'
        (Get-TaskState $repo '002').status | Should -Be 'in-review'
    }

    It 'gives the reviewer read-only tools and posts its verdict as a PR comment' {
        Add-QueueTask $repo '001-first.md'
        Invoke-Cycle $repo $a $b | Out-Null

        Invoke-Cycle $repo $a $b | Out-Null

        $reviewCall = (Get-SessionCalls $b)[0]
        $reviewArgs = [string[]]$reviewCall.args
        $denied = Get-FlagValues -Arguments $reviewArgs -Flag '--disallowedTools'
        $denied | Should -Contain 'Edit'
        $denied | Should -Contain 'Write'
        $denied | Should -Contain 'Bash'
        $reviewArgs | Should -Not -Contain '--allowedTools'
        $reviewCall.prompt | Should -Match 'change-[0-9a-f]{6}\.txt'
        $comment = Get-GhCalls | Where-Object { $_.args[1] -eq 'comment' }
        $comment.args | Should -Contain '1'
        $comment.body | Should -Match 'VERDICT: APPROVED'
    }

    It 'never merges: an approved PR stays open for the user' {
        Add-QueueTask $repo '001-first.md'
        Invoke-Cycle $repo $a $b | Out-Null
        Invoke-Cycle $repo $a $b | Out-Null

        @(Get-GhCalls | Where-Object { $_.args -contains 'merge' }) | Should -HaveCount 0
        git -C $repo.Origin log --oneline main | Should -HaveCount 1
    }

    It 'sends requested changes back to A on the same branch, up to two rounds, then blocks' {
        Add-QueueTask $repo '001-first.md'
        Set-SessionResult -Account $b -Text "VERDICT: CHANGES_REQUESTED`nHIGH: missing test."
        Invoke-Cycle $repo $a $b | Out-Null   # A implements

        Invoke-Cycle $repo $a $b | Out-Null   # B: round 1
        (Get-TaskState $repo '001').status | Should -Be 'changes-requested'
        Invoke-Cycle $repo $a $b | Out-Null   # A fixes
        (Get-SessionCalls $a)[-1].prompt | Should -Match 'HIGH: missing test'
        (Get-TaskState $repo '001').status | Should -Be 'in-review'
        Invoke-Cycle $repo $a $b | Out-Null   # B: round 2
        Invoke-Cycle $repo $a $b | Out-Null   # A fixes again
        Invoke-Cycle $repo $a $b | Out-Null   # B: round 3 -> stop

        $state = Get-TaskState $repo '001'
        $state.status | Should -Be 'blocked'
        $state.reason | Should -Match 'review rounds'
        git -C $repo.Origin rev-list --count 'auto/001-first' | Should -Be 4
    }

    It 'never rotates: when A is at its cap, B only reviews and A''s task waits' {
        Add-QueueTask $repo '001-first.md'
        $a = New-PipelineAccount -Name 'A' -Percent '90'
        Set-ImplementerCommits -Account $a

        $cycle = Invoke-Cycle $repo $a $b

        $cycle.Implementer.Outcome | Should -Be 'CapWait'
        $cycle.Reviewer | Should -BeNullOrEmpty
        @(Get-SessionCalls $a) | Should -HaveCount 0
        @(Get-SessionCalls $b) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $repo.State 'state.json') | Should -BeFalse
    }

    It 'blocks the task when A leaves no commit' {
        Add-QueueTask $repo '001-first.md'
        Remove-Item -LiteralPath (Join-Path $a.ConfigDir 'fake-session-action.ps1')

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'no commits'
        git -C $repo.Origin branch --list 'auto/001-first' | Should -BeNullOrEmpty
    }

    It 'blocks without pushing when A moves to another branch' {
        Add-QueueTask $repo '001-first.md'
        Set-Content -LiteralPath (Join-Path $a.ConfigDir 'fake-session-action.ps1') -Value @'
git checkout -q -b sneaky
Set-Content -LiteralPath x.txt -Value x; git add -A; git -c user.email=a@example.invalid -c user.name=A commit -q -m x
'@

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        git -C $repo.Origin branch --list 'sneaky' | Should -BeNullOrEmpty
    }

    It 'gives the implementer no unrestricted shell by default and denies push and gh' {
        Add-QueueTask $repo '001-first.md'

        Invoke-Cycle $repo $a $b | Out-Null

        $implArgs = [string[]](Get-SessionCalls $a)[0].args
        $allowed = Get-FlagValues -Arguments $implArgs -Flag '--allowedTools'
        $allowed | Should -Not -Contain 'Bash'
        $allowed | Should -Not -Contain 'Read'
        $allowed | Should -Not -Contain 'Edit'
        $allowed | Should -Not -Match '^Bash\(git (diff|log|show)'
        ($implArgs -join ' ') | Should -Match '--permission-mode acceptEdits'
        $settings = $implArgs[[Array]::IndexOf($implArgs, '--settings') + 1] | ConvertFrom-Json
        $settings.permissions.deny | Should -Contain "Read($(ConvertTo-PermissionPath -Path $b.ConfigDir))"
        $denied = Get-FlagValues -Arguments $implArgs -Flag '--disallowedTools'
        $denied | Should -Contain 'Bash(git push)'
        $denied | Should -Contain 'Bash(git push *)'
        $denied | Should -Contain 'Bash(gh *)'
    }

    It 'blocks without pushing when the change adds <Case>' -TestCases @(
        @{ Case = 'a credentials file'; File = '.credentials.json'; Content = '{"x":1}' }
        @{ Case = 'an Anthropic-style key'; File = 'config.txt'; Content = ('key=sk-' + 'ant-api03-SYNTHETICSYNTHETICSYNTHETIC') }  # split so scanners skip it
        @{ Case = 'an OAuth token field'; File = 'dump.json'; Content = '{"refreshToken":"synthetic-value-0000"}' }
    ) {
        Add-QueueTask $repo '001-first.md'
        Set-Content -LiteralPath (Join-Path $a.ConfigDir 'fake-session-action.ps1') -Value @"
Set-Content -LiteralPath '$File' -Value '$Content'
git add -A; git -c user.email=a@example.invalid -c user.name=A commit -q -m leak
"@

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'secret'
        git -C $repo.Origin branch --list 'auto/001-first' | Should -BeNullOrEmpty
    }

    It 'blocks without pushing when the change touches <File>' -TestCases @(
        @{ File = '.claude/settings.json' }, @{ File = '.mcp.json' }, @{ File = '.github/workflows/x.yml' },
        @{ File = '.githooks/pre-push' }, @{ File = '.gitmodules' }
    ) {
        Add-QueueTask $repo '001-first.md'
        Set-Content -LiteralPath (Join-Path $a.ConfigDir 'fake-session-action.ps1') -Value @"
New-Item -ItemType Directory -Path (Split-Path -Parent './$File') -Force | Out-Null
Set-Content -LiteralPath './$File' -Value 'x'
git add -A -f; git -c user.email=a@example.invalid -c user.name=A commit -q -m protected
"@

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'protected path'
        git -C $repo.Origin branch --list 'auto/001-first' | Should -BeNullOrEmpty
    }

    It 'does not post a review that looks like it contains a secret' {
        Add-QueueTask $repo '001-first.md'
        Set-SessionResult -Account $b -Text ("VERDICT: APPROVED`ntoken " + 'sk-' + 'ant-oat01-SYNTHETICSYNTHETIC')
        Invoke-Cycle $repo $a $b | Out-Null

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'secret'
        @(Get-GhCalls | Where-Object { $_.args[1] -eq 'comment' }) | Should -HaveCount 0
    }

    It 'blocks the review when the diff is larger than MaxReviewDiffBytes' {
        Add-QueueTask $repo '001-first.md'
        Invoke-Cycle $repo $a $b | Out-Null

        Invoke-Cycle $repo $a $b -Extra @{ MaxReviewDiffBytes = 10 } | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'diff'
        @(Get-SessionCalls $b) | Should -HaveCount 0
    }

    It 'stops for the user when A says it needs a human decision' {
        Add-QueueTask $repo '001-first.md'
        Set-ImplementerCommits -Account $a -Final 'NEEDS_USER: which licence?'

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'waiting-user'
        @(Get-GhCalls) | Should -HaveCount 0
    }

    It 'blocks the task when the review has no verdict line' {
        Add-QueueTask $repo '001-first.md'
        Set-SessionResult -Account $b -Text 'Looks fine to me.'
        Invoke-Cycle $repo $a $b | Out-Null

        Invoke-Cycle $repo $a $b | Out-Null

        (Get-TaskState $repo '001').status | Should -Be 'blocked'
        (Get-TaskState $repo '001').reason | Should -Match 'verdict'
    }

    It 'starts no more than MaxTasksPerDay new tasks' {
        1..3 | ForEach-Object { Add-QueueTask $repo ('00{0}-t{0}.md' -f $_) }

        1..3 | ForEach-Object { Invoke-Cycle $repo $a $b -Extra @{ MaxTasksPerDay = 2 } | Out-Null }

        Get-TaskState $repo '003' | Should -BeNullOrEmpty
    }

    It 'logs every session as one JSON line' {
        Add-QueueTask $repo '001-first.md'
        Invoke-Cycle $repo $a $b | Out-Null
        Invoke-Cycle $repo $a $b | Out-Null

        $log = @(Get-Content -LiteralPath (Join-Path $repo.State 'runs.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        $log | Should -HaveCount 2
        $log[0].role | Should -Be 'implementer'
        $log[0].account | Should -Be 'A'
        $log[1].role | Should -Be 'reviewer'
        $log[1].task | Should -Be '001'
        $log[1].outcome | Should -Be 'Completed'
    }

    It 'refuses to use the same config dir for both accounts' {
        { Invoke-Cycle $repo $a ([pscustomobject]@{ Name = 'B'; ConfigDir = $a.ConfigDir; MaxFiveHourPercent = 70 }) } |
            Should -Throw '*same config dir*'
    }

    It 'does nothing when the queue is empty and nothing is in review' {
        $cycle = Invoke-Cycle $repo $a $b

        $cycle.Idle | Should -BeTrue
        @(Get-SessionCalls $a) | Should -HaveCount 0
    }
    It 'with -DryRun reports the planned work without running sessions or touching git' {
        Add-QueueTask $repo '001-first.md'

        $plan = Invoke-Cycle $repo $a $b -Extra @{ DryRun = $true }

        $plan.Implementer.Task | Should -Be '001'
        $plan.Implementer.Status | Should -Be 'planned'
        @(Get-SessionCalls $a) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $repo.State 'worktrees') | Should -BeFalse
    }
}

Describe 'run-pipeline.ps1' {
    BeforeEach {
        $env:FAKE_GH_DIR = (New-Item -ItemType Directory -Path (Join-Path $TestDrive "gh-$([guid]::NewGuid())")).FullName
        $repo = New-TestRepo
        $a = New-PipelineAccount -Name 'A'
        $b = New-PipelineAccount -Name 'B'
        Set-ImplementerCommits -Account $a
        Set-SessionResult -Account $b -Text "VERDICT: APPROVED"
        $script = Join-Path $PSScriptRoot '..' 'scripts' 'run-pipeline.ps1'
        $common = @{
            RepoPath = $repo.Clone; QueueDir = $repo.Queue; StateDir = $repo.State
            AccountAConfigDir = $a.ConfigDir; AccountBConfigDir = $b.ConfigDir
            MaxFiveHourPercentA = 70; MaxFiveHourPercentB = 50
            ClaudePath = $fakeClaude; GhPath = $fakeGh
        }
    }
    AfterEach { Remove-Item Env:FAKE_GH_DIR -ErrorAction SilentlyContinue }

    It 'runs cycles until there is nothing left to do and exits 0' {
        Add-QueueTask $repo '001-first.md'

        & $script @common -MaxCycles 5 *> $null

        $LASTEXITCODE | Should -Be 0
        (Get-TaskState $repo '001').status | Should -Be 'approved'
    }

    It 'exits 3 when no role can run because of usage, without waiting by default' {
        Add-QueueTask $repo '001-first.md'
        New-FakeAccount -Path $a.ConfigDir -UsageText (Get-SampleUsageText -Percent '95') | Out-Null

        & $script @common -MaxCycles 5 *> $null

        $LASTEXITCODE | Should -Be 3
        @(Get-SessionCalls $a) | Should -HaveCount 0
    }

    It 'appends -ExtraImplementerTools to the implementer defaults' {
        Add-QueueTask $repo '001-first.md'

        & $script @common -MaxCycles 1 -ExtraImplementerTools 'Bash(npm test *)' *> $null

        $allowed = Get-FlagValues -Arguments ([string[]](Get-SessionCalls $a)[0].args) -Flag '--allowedTools'
        $allowed | Should -Contain 'Bash(npm test *)'
        $allowed | Should -Contain 'Bash(git commit *)'
    }

    It 'applies each account''s own cap' {
        Add-QueueTask $repo '001-first.md'
        New-FakeAccount -Path $b.ConfigDir -UsageText (Get-SampleUsageText -Percent '60') | Out-Null

        & $script @common -MaxCycles 5 *> $null

        (Get-TaskState $repo '001').status | Should -Be 'in-review'
        @(Get-SessionCalls $b) | Should -HaveCount 0
        $LASTEXITCODE | Should -Be 3
    }
}
