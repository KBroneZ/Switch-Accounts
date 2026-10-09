@{
    RootModule        = 'SwitchAccounts.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b6f0d7a4-5c1e-4f3b-9a8d-2e7c4b1f6a90'
    Author            = 'Switch-Accounts contributors'
    Copyright         = '(c) Switch-Accounts contributors. MIT License.'
    Description       = 'Open Claude Code sessions on one of your own accounts (model, effort, Remote Control, worktree) and run two of your own subscriptions as an implement/review pipeline with a per-account cap on the 5-hour usage window.'
    PowerShellVersion = '7.4'
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            LicenseUri = 'https://opensource.org/license/mit'
            Tags       = @('claude-code', 'pipeline', 'usage-limits', 'review', 'windows-terminal', 'remote-control')
        }
    }
}
