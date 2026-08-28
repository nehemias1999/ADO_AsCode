@{
    RootModule        = 'Ado.Rest.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1f2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c50'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Transport layer for the Azure DevOps REST API: connection context, URL construction, request execution with retry, and paged collection reads. Carries no domain knowledge.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-AdoContext',
        'Get-RequiredEnvironmentVariable',
        'New-AdoUri',
        'New-AdoRequestParameter',
        'Invoke-AdoRest',
        'Invoke-AdoRestPaged',
        'Get-AdoProject',
        'Get-AdoAuthenticatedUser',
        'Remove-SecretFromText'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'REST', 'InfrastructureAsCode')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
