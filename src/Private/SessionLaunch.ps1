# Helpers of Open-ClaudeSession: worktrees, tools and the plan of each tab.

function Get-SessionWorktreePlans {
    <# One worktree plan per tab when -Worktree is set (branch-1, branch-2 … for several tabs); none otherwise. #>
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] [int] $Count)
    if (-not $Request.Worktree) { return }
    for ($i = 1; $i -le $Count; $i++) {
        $branch = if ($Count -gt 1) { "$($Request.Worktree)-$i" } else { $Request.Worktree }
        Get-WorktreePlan -Directory $Request.Directory -Branch $branch
    }
}

function Initialize-SessionFolders {
    <# The folder of each tab; creates the worktrees unless this is only a preview. #>
    param($Request, [object[]] $Plans, [int] $Count, [bool] $Preview, $Warnings)
    if (-not $Plans) { return @(1..$Count | ForEach-Object { $Request.Directory }) }
    foreach ($plan in $Plans) {
        if (-not $Preview) {
            $made = New-SessionWorktree -Plan $plan
            foreach ($w in $made.Warnings) { $Warnings.Add($w) }
        }
        $plan.Path
    }
}

function Get-LaunchTools {
    <# Paths of the CLI and of Windows Terminal. Both are only required when a tab will open. #>
    param([bool] $Preview, [string] $ClaudePath, [string] $Configured, [string] $WtPath)
    $claude = Resolve-ClaudePath -Override $ClaudePath -Configured $Configured
    $wt = if ($WtPath) { $WtPath } else { (Get-Command wt -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source }
    if (-not $Preview) {
        if (-not (Get-Command -Name $claude -ErrorAction SilentlyContinue)) {
            Stop-WithSwitchError Environment "Claude Code CLI not found ($claude). Set claudePath in accounts.json or pass -ClaudePath."
        }
        if (-not $wt) { Stop-WithSwitchError Environment 'Windows Terminal (wt) not found. Use -PrintOnly to see the command.' }
    }
    [pscustomobject]@{ Claude = $claude; Wt = $wt }
}

function ConvertTo-SafeLabel {
    <# Makes folder names fit the label rules (no ';', no control characters). #>
    param([string] $Value)
    $label = [regex]::Replace($Value, '[^\p{L}\p{N} ._\-#()·:+@]', '-')
    if ($label.Length -gt 50) { $label.Substring(0, 50) } else { $label }
}

function New-SessionPlan {
    <# The tab of one session: title, Remote Control name, script and wt arguments. #>
    param($Request, $Account, $Settings, [string] $Folder, [int] $Index, [int] $Count, [string] $ClaudePath)
    $suffix = if ($Count -gt 1) { " #$Index" } else { '' }
    $baseTitle = if ($Request.Title) { $Request.Title } else { "Claude $($Account.Name)" }
    $baseRc = if ($Request.SessionName) { $Request.SessionName }
    elseif ($Request.Title) { $Request.Title }
    else { "$(ConvertTo-SafeLabel (Split-Path -Leaf $Folder)) · $($Account.Name)" }
    $rcName = if ($Request.RemoteControl) { $baseRc + $suffix } else { $null }
    $configDir = if ($Account.IsDefaultConfigDir) { $null } else { $Account.ConfigDir }
    $command = New-LaunchCommand -AccountName $Account.Name -ConfigDir $configDir -ClaudePath $ClaudePath `
        -WorkingDirectory $Folder -Title ($baseTitle + $suffix) -RemoteControlName $rcName -Model $Settings.Model `
        -Effort $Settings.Effort -SubagentModel $Settings.SubagentModel -InitialPrompt $Request.InitialPrompt
    [pscustomobject]@{
        Title             = $baseTitle + $suffix
        RemoteControlName = $rcName
        Directory         = $Folder
        Opened            = $false
        Script            = $command.Script
        WtArguments       = $command.WtArguments
    }
}
