@{
    RootModule        = 'Ado.Work.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd3b4c5e6-7f80-4b9c-8d0e-2f3a4b5c6d72'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Work-tracking surface of Azure DevOps: Area and Iteration Paths, team work settings, and the Board column reconciliation engine that never deletes a column.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('Ado.Rest')

    FunctionsToExport = @(
        'Get-AdoClassificationNode',
        'Initialize-AdoClassificationPath',
        'Rename-AdoAreaPath',
        'Get-AdoTeamSetting',
        'Get-AdoTeamFieldValue',
        'Get-AdoTeamIteration',
        'Add-AdoTeamIteration',
        'Get-AdoWorkItemTypeState',
        'Initialize-AdoTeamWorkConfiguration',
        'Get-AdoBoard',
        'Get-AdoBoardColumn',
        'Set-AdoBoardColumn',
        'Test-AdoBoardColumnTemplate',
        'Get-AdoBoardColumnRenameConflict',
        'Test-AdoBoardColumnDrift',
        'New-AdoBoardColumnPayload',
        'Get-AdoBoardColumnStatus',
        'Sync-AdoBoardColumn'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'Boards', 'WorkTracking')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
