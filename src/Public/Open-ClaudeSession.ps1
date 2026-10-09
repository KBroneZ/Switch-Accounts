function Open-ClaudeSession {
    <#
    .SYNOPSIS
        Opens a Windows Terminal tab with a Claude Code session for one of your accounts.
    .DESCRIPTION
        -Account names an account of ~/.claude-switch/accounts.json, or 'auto' (default) for the
        one with the lowest 5-hour usage that is below its caps and ready. The tab gets the
        account's config dir, an optional model (--model), effort (--effort), subagent model
        (CLAUDE_CODE_SUBAGENT_MODEL), Remote Control (--remote-control, always with a name) and a
        first prompt. Variables inherited from the session that launches it are dropped.

        Nothing starts when the account has not finished its first start or does not trust the
        folder (the tab would wait for someone at the keyboard): the error says what is missing.
        -TrustDirectory marks the folder as trusted in that account on request. The session never
        skips permission checks. -PrintOnly and -WhatIf show the plan and change nothing.
    .OUTPUTS
        Account, Model, Effort, SubagentModel, RemoteControlName, Directory, Title, Opened,
        Count, Sessions, Warnings and Summary (one line for the user).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $Account = 'auto',
        [string] $Directory,
        [string] $Model,
        [string] $Effort,
        [string] $SubagentModel,
        [switch] $RemoteControl,
        [string] $SessionName,
        [string] $InitialPrompt,
        [string] $Title,
        [string] $Worktree,
        [ValidateRange(1, 8)] [int] $Count = 1,
        [switch] $PrintOnly,
        [switch] $TrustDirectory,
        [switch] $NoUsageCheck,
        [string] $ConfigPath = (Get-SwitchConfigPath),
        [string] $ClaudePath,
        [string] $WtPath
    )

    $preview = $PrintOnly -or $WhatIfPreference
    $request = Resolve-SessionRequest -Account $Account -Directory $Directory -Model $Model -Effort $Effort `
        -SubagentModel $SubagentModel -RemoteControl $RemoteControl -SessionName $SessionName `
        -InitialPrompt $InitialPrompt -Title $Title -Worktree $Worktree -TrustDirectory $TrustDirectory
    $config = Get-SwitchAccountConfig -ConfigPath $ConfigPath -NoCreate:$WhatIfPreference
    $plans = @(Get-SessionWorktreePlans -Request $request -Count $Count)
    $checkDir = if ($plans) { $plans[0].Path } else { $request.Directory }
    $trustDir = if ($plans) { $plans[0].RepoRoot } else { $request.Directory }

    $choice = Resolve-SessionAccount -Request $request -Config $config -ConfigPath $ConfigPath `
        -ClaudePath $ClaudePath -CheckDirectory $checkDir -NoUsageCheck $NoUsageCheck
    $entry = $choice.Account
    $warnings = [System.Collections.Generic.List[string]]::new()
    $warnings.AddRange([string[]]$choice.Warnings)
    $tools = Get-LaunchTools -Preview $preview -ClaudePath $ClaudePath -Configured $config.ClaudePath -WtPath $WtPath

    if ($choice.WillTrust) {
        if ($preview) { $warnings.Add("would mark $trustDir as trusted for account $($entry.Name)") }
        else {
            $globalConfig = Get-AccountGlobalConfigPath -ConfigDir $entry.ConfigDir -IsDefault $entry.IsDefaultConfigDir
            Set-DirectoryTrust -GlobalConfigPath $globalConfig -Directory $trustDir -ProtectedPaths @($config.Accounts.ConfigDir) | Out-Null
        }
    }
    $folders = @(Initialize-SessionFolders -Request $request -Plans $plans -Count $Count -Preview $preview -Warnings $warnings)

    $settings = [pscustomobject]@{
        Model         = if ($request.Model) { $request.Model } else { $entry.DefaultModel }
        Effort        = if ($request.Effort) { $request.Effort } else { $entry.DefaultEffort }
        SubagentModel = if ($request.SubagentModel) { $request.SubagentModel } else { $entry.DefaultSubagentModel }
    }
    $sessions = for ($i = 1; $i -le $Count; $i++) {
        $session = New-SessionPlan -Request $request -Account $entry -Settings $settings -Folder $folders[$i - 1] `
            -Index $i -Count $Count -ClaudePath $tools.Claude
        if (-not $PrintOnly -and $PSCmdlet.ShouldProcess("tab '$($session.Title)' ($($entry.Name))", 'Open Claude Code session')) {
            try { Start-TerminalTab -WtPath $tools.Wt -Arguments $session.WtArguments }
            catch {
                $already = if ($i -gt 1) { " $($i - 1) tab(s) were already opened; their worktrees stay." } else { '' }
                Stop-WithSwitchError Environment "Could not open tab $i of ${Count}: $($_.Exception.Message)$already"
            }
            $session.Opened = $true
        }
        $session
    }
    $sessions = @($sessions)
    $opened = @($sessions | Where-Object Opened).Count -gt 0
    $rcName = ($sessions | Select-Object -First 1).RemoteControlName
    $summaryName = if ($rcName -and $Count -gt 1) { $rcName -replace ' #1$', " #1-$Count" } else { $rcName }
    [pscustomobject]@{
        Account           = $entry.Name
        Model             = $settings.Model
        Effort            = $settings.Effort
        SubagentModel     = $settings.SubagentModel
        RemoteControlName = $rcName
        Directory         = $folders[0]
        Title             = $sessions[0].Title
        Opened            = $opened
        Count             = $Count
        Sessions          = $sessions
        Warnings          = $warnings.ToArray()
        Summary           = Format-SessionSummary -AccountName $entry.Name -Model $settings.Model -Effort $settings.Effort `
            -SubagentModel $settings.SubagentModel -RemoteControlName $summaryName -Directory $folders[0] -Count $Count `
            -Mode $(if ($opened) { 'Opened' } else { 'Simulated' })
    }
}
