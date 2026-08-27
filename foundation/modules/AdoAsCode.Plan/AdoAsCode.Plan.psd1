@{
    RootModule        = 'AdoAsCode.Plan.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a6e7f809-0213-4ecf-9031-5c6d7e8f9a05'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'The shared plan model: one flat list of operations with a closed action and status vocabulary, plus the gate that stops an apply while any operation is blocked.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-PlanStatusName',
        'Get-PlanActionName',
        'New-Plan',
        'New-PlanOperation',
        'Add-PlanOperation',
        'Get-PlanSummary',
        'Test-PlanBlocked',
        'Assert-PlanApplicable',
        'Write-PlanSummary'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Plan', 'InfrastructureAsCode', 'DryRun')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
