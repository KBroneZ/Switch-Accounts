@{
    RootModule        = 'SwitchAccounts.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b6f0d7a4-5c1e-4f3b-9a8d-2e7c4b1f6a90'
    Author            = 'Switch-Accounts contributors'
    Copyright         = '(c) Switch-Accounts contributors. MIT License.'
    Description       = 'Run two of your own Claude Code subscriptions as an implement/review pipeline with a per-account cap on the 5-hour usage window.'
    PowerShellVersion = '7.4'
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            LicenseUri = 'https://opensource.org/license/mit'
            Tags       = @('claude-code', 'pipeline', 'usage-limits', 'review')
        }
    }
}
