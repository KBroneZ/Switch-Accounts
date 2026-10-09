# Pure helpers behind Open-ClaudeSession: validate the request, pick the account, word the result.

function Resolve-SessionRequest {
    <# Validates every value of the request before anything else happens. Returns the normalised request. #>
    param(
        [string] $Account, [string] $Directory, [string] $Model, [string] $Effort, [string] $SubagentModel,
        [bool] $RemoteControl, [string] $SessionName, [string] $InitialPrompt, [string] $Title, [string] $Worktree,
        [bool] $TrustDirectory
    )
    $folder = if ($Directory) { $Directory } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Stop-WithSwitchError InvalidArgument "-Directory '$(Get-ShortText $folder 120)' does not exist or is not a folder."
    }
    $name = ConvertTo-SessionLabel $SessionName 'SessionName'
    if ($name -and -not $RemoteControl) { Stop-WithSwitchError InvalidArgument '-SessionName names the Remote Control session; add -RemoteControl.' }
    [pscustomobject]@{
        Account        = if ($Account) { $Account.Trim() } else { 'auto' }
        Directory      = [IO.Path]::TrimEndingDirectorySeparator((Resolve-Path -LiteralPath $folder).ProviderPath)
        Model          = ConvertTo-LaunchModel $Model 'Model'
        Effort         = ConvertTo-LaunchEffort $Effort
        SubagentModel  = ConvertTo-LaunchModel $SubagentModel 'SubagentModel'
        RemoteControl  = $RemoteControl
        SessionName    = $name
        InitialPrompt  = Assert-InitialPrompt $InitialPrompt
        Title          = ConvertTo-SessionLabel $Title 'Title'
        Worktree       = Assert-BranchName $Worktree
        TrustDirectory = $TrustDirectory
    }
}

function Select-AvailableAccount {
    <#
      Among the candidates, the account with the lowest 5-hour usage. A tie goes to the one that
      resets first (unknown reset last), then to the order of the config. Candidates are status
      objects of Get-ClaudeAccountStatus; the caller has already removed the ones that cannot run.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates)
    $index = 0
    $ranked = foreach ($c in $Candidates) {
        [pscustomobject]@{
            Candidate = $c
            Percent   = [double]$c.FiveHourPercent
            Resets    = if ($c.ResetsAt) { ([DateTimeOffset]$c.ResetsAt).UtcTicks } else { [long]::MaxValue }
            Order     = $index++
        }
    }
    ($ranked | Sort-Object Percent, Resets, Order | Select-Object -First 1)?.Candidate
}

function Get-AutoCandidates {
    <# Statuses that can open the session now. Untrusted counts when -TrustDirectory was asked for. #>
    param([Parameter(Mandatory)] [object[]] $Statuses, [bool] $NeedRemoteControl, [bool] $TrustDirectory)
    @($Statuses | Where-Object {
            $_.Decision -eq 'Allow' -and
            ($_.Onboarding -eq 'Ready' -or ($TrustDirectory -and $_.Onboarding -eq 'Untrusted')) -and
            (-not $NeedRemoteControl -or $_.RemoteControl)
        })
}

function Format-SessionSummary {
    <# One line for the user: «Abierta: cuenta B · sonnet · effort high · subagentes haiku · RC «x» · C:\…». #>
    param(
        [Parameter(Mandatory)] [string] $AccountName, $Model, $Effort, $SubagentModel,
        $RemoteControlName, [Parameter(Mandatory)] [string] $Directory,
        [int] $Count = 1, [ValidateSet('Opened', 'Simulated')] [string] $Mode = 'Opened'
    )
    $lead = switch ($Mode) {
        'Opened' { if ($Count -gt 1) { "Abiertas $Count pestañas" } else { 'Abierta' } }
        default { if ($Count -gt 1) { "Simuladas $Count pestañas (no abiertas)" } else { 'Simulada (no abierta)' } }
    }
    $parts = @(
        "cuenta $AccountName"
        if ($Model) { $Model } else { 'modelo por defecto' }
        if ($Effort) { "effort $Effort" } else { 'effort por defecto' }
        if ($SubagentModel) { "subagentes $SubagentModel" }
        if ($RemoteControlName) { "RC «$RemoteControlName»" }
        $Directory
    )
    "${lead}: " + ($parts -join ' · ')
}
