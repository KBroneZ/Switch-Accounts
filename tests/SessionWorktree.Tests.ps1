BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath

    function Invoke-TestGit { git @args 2>&1 | Out-String }

    function New-TestRepo {
        # A local bare "remote" with a main branch and a clone of it, like a real checkout.
        $root = Join-Path $TestDrive "repo-$([guid]::NewGuid())"
        $origin = Join-Path $root 'origin.git'
        $clone = Join-Path $root 'clone'
        New-Item -ItemType Directory -Path $root | Out-Null
        git init -q --bare -b main $origin
        git clone -q $origin $clone 2>$null
        git -C $clone config user.email 'test@example.invalid'
        git -C $clone config user.name 'Test'
        Set-Content -LiteralPath (Join-Path $clone 'a.txt') -Value 'a'
        git -C $clone add -A
        git -C $clone commit -q -m 'init'
        git -C $clone push -q origin main 2>$null
        git -C $clone remote set-head origin main 2>$null | Out-Null
        @{ Root = $root; Origin = $origin; Clone = $clone }
    }
}

Describe 'worktree for a session' {
    BeforeEach {
        $repo = New-TestRepo
    }

    It 'plans <repo>\.claude\worktrees\<branch> with slashes turned into dashes' {
        $plan = InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } { Get-WorktreePlan -Directory $Dir -Branch 'feat/login' }

        $plan.Branch | Should -Be 'feat/login'
        $plan.Path | Should -Be ([IO.Path]::GetFullPath((Join-Path $repo.Clone '.claude' 'worktrees' 'feat-login')))
        $plan.RepoRoot | Should -Be (Resolve-Path $repo.Clone).Path
    }

    It 'plans from the main checkout also when started inside a subfolder or another worktree' {
        New-Item -ItemType Directory -Path (Join-Path $repo.Clone 'src') | Out-Null
        git -C $repo.Clone worktree add -q (Join-Path $repo.Root 'linked') -b linked 2>$null

        foreach ($start in (Join-Path $repo.Clone 'src'), (Join-Path $repo.Root 'linked')) {
            $plan = InModuleScope SwitchAccounts -Parameters @{ Dir = $start } { Get-WorktreePlan -Directory $Dir -Branch 'x' }
            $plan.RepoRoot | Should -Be (Resolve-Path $repo.Clone).Path
        }
    }

    It 'refuses a folder that is not a git repository' {
        $plain = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null

        InModuleScope SwitchAccounts -Parameters @{ Dir = $plain } {
            { Get-WorktreePlan -Directory $Dir -Branch 'x' } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }
    }

    It 'creates the worktree on a new branch from the remote default branch' {
        git -C $repo.Clone commit -q --allow-empty -m 'local only'
        $remoteHead = git -C $repo.Clone rev-parse origin/main

        $made = InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'feat/login')
        }

        $made.Reused | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $made.Plan.Path 'a.txt') | Should -BeTrue
        git -C $made.Plan.Path rev-parse --abbrev-ref HEAD | Should -Be 'feat/login'
        git -C $made.Plan.Path rev-parse HEAD | Should -Be $remoteHead
        git -C $made.Plan.Path config --get branch.feat/login.remote | Should -BeNullOrEmpty
    }

    It 'keeps .claude/worktrees out of git status without touching tracked files' {
        InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'x1') | Out-Null
            New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'x2') | Out-Null
        }

        git -C $repo.Clone status --porcelain | Should -BeNullOrEmpty
        @(Get-Content -LiteralPath (Join-Path $repo.Clone '.git' 'info' 'exclude') | Where-Object { $_ -eq '/.claude/worktrees/' }) | Should -HaveCount 1
    }

    It 'reuses a worktree that already holds the branch' {
        InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            $plan = Get-WorktreePlan -Directory $Dir -Branch 'again'
            New-SessionWorktree -Plan $plan | Out-Null
            (New-SessionWorktree -Plan $plan).Reused | Should -BeTrue
        }
    }

    It 'refuses a branch that already exists elsewhere' {
        git -C $repo.Clone branch taken

        InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            { New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'taken') } | Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*already exists*'
        }
    }

    It 'refuses a folder that holds something else' {
        $other = Join-Path $repo.Clone '.claude' 'worktrees' 'busy'
        New-Item -ItemType Directory -Path $other -Force | Out-Null

        InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            { New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'busy') } | Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*does not hold branch*'
        }
    }

    It 'falls back to origin/main when origin/HEAD is not set, and fails clearly without a remote branch' {
        git -C $repo.Clone remote set-head origin --delete 2>$null | Out-Null

        InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            Get-RemoteDefaultBranch -RepoRoot $Dir | Should -Be 'origin/main'
        }
        $bare = Join-Path $TestDrive "norem-$([guid]::NewGuid())"
        git init -q -b main $bare
        InModuleScope SwitchAccounts -Parameters @{ Dir = $bare } {
            { Get-RemoteDefaultBranch -RepoRoot $Dir } | Should -Throw -ErrorId 'SwitchAccounts.Environment'
        }
    }

    It 'warns and uses the last known remote ref when the fetch fails' {
        git -C $repo.Clone remote set-url origin (Join-Path $repo.Root 'gone.git')

        $made = InModuleScope SwitchAccounts -Parameters @{ Dir = $repo.Clone } {
            New-SessionWorktree -Plan (Get-WorktreePlan -Directory $Dir -Branch 'offline')
        }

        $made.Warnings | Should -HaveCount 1
        $made.Warnings[0] | Should -BeLike 'could not fetch origin/main*'
        Test-Path -LiteralPath $made.Plan.Path | Should -BeTrue
    }
}

Describe 'Open-ClaudeSession -Worktree' {
    BeforeEach {
        Mock -ModuleName SwitchAccounts Start-TerminalTab {}
        $repo = New-TestRepo
        $account = New-SwitchTestAccount -Root $repo.Root -Name A -Trusted @($repo.Clone)
        $config = Write-SwitchTestConfig -Path (Join-Path $repo.Root 'accounts.json') -Accounts @($account)
        $common = @{ Directory = $repo.Clone; ConfigPath = $config; ClaudePath = $fake; WtPath = 'wt-not-used' }
    }

    It 'opens the session inside the new worktree, which a trusted repo covers' {
        $result = Open-ClaudeSession @common -Worktree 'feat/login'

        $expected = [IO.Path]::GetFullPath((Join-Path $repo.Clone '.claude' 'worktrees' 'feat-login'))
        $result.Directory | Should -Be $expected
        $result.Sessions[0].Script | Should -Match ([regex]::Escape("Set-Location -LiteralPath '$expected'"))
        git -C $expected rev-parse --abbrev-ref HEAD | Should -Be 'feat/login'
        $result.Opened | Should -BeTrue
    }

    It 'creates nothing under -PrintOnly or -WhatIf' {
        $print = Open-ClaudeSession @common -Worktree 'feat/print' -PrintOnly
        $whatIf = Open-ClaudeSession @common -Worktree 'feat/whatif' -WhatIf

        $print.Directory | Should -BeLike '*feat-print'
        Test-Path -LiteralPath $print.Directory | Should -BeFalse
        Test-Path -LiteralPath $whatIf.Directory | Should -BeFalse
        git -C $repo.Clone branch --list 'feat/*' | Should -BeNullOrEmpty
    }

    It 'gives every tab its own numbered branch and worktree' {
        $result = Open-ClaudeSession @common -Worktree 'fix' -Count 2

        $result.Sessions.Directory | Should -Be @(
            [IO.Path]::GetFullPath((Join-Path $repo.Clone '.claude' 'worktrees' 'fix-1'))
            [IO.Path]::GetFullPath((Join-Path $repo.Clone '.claude' 'worktrees' 'fix-2')))
        git -C $repo.Clone branch --list 'fix-*' | Should -HaveCount 2
    }

    It 'creates no worktree when the account is not ready' {
        $json = Join-Path (Split-Path -Parent $common.ConfigPath) 'config-A' '.claude.json'
        New-ClaudeJson -ConfigDir (Split-Path -Parent $json) -Trusted @()

        { Open-ClaudeSession @common -Worktree 'nope' } | Should -Throw -ErrorId 'SwitchAccounts.NotReady'

        Test-Path -LiteralPath (Join-Path $repo.Clone '.claude' 'worktrees') | Should -BeFalse
        git -C $repo.Clone branch --list 'nope' | Should -BeNullOrEmpty
    }

    It 'trusts the repo, not the worktree folder, with -TrustDirectory' {
        $configDir = Join-Path (Split-Path -Parent $common.ConfigPath) 'config-A'
        New-ClaudeJson -ConfigDir $configDir -Trusted @()

        Open-ClaudeSession @common -Worktree 'wt1' -TrustDirectory | Out-Null

        $projects = (Get-Content -LiteralPath (Join-Path $configDir '.claude.json') -Raw | ConvertFrom-Json).projects
        $names = @($projects.PSObject.Properties | Where-Object { $_.Value.hasTrustDialogAccepted } | ForEach-Object Name)
        $names | Should -HaveCount 1
        $names[0] | Should -Be (Resolve-Path $repo.Clone).Path
    }
}
