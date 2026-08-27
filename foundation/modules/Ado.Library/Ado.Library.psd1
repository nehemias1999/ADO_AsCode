@{
    RootModule        = 'Ado.Library.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e4c5d6f7-8091-4cad-9e1f-3a4b5c6d7e83'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Pipelines library surface of Azure DevOps: Variable Groups written without destroying their secrets, and SSH Service Connections created without overwriting an existing credential.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('Ado.Rest')

    FunctionsToExport = @(
        'Get-AdoConfigurationSentinel',
        'Get-AdoVariableGroup',
        'New-AdoVariableGroup',
        'Get-AdoVariableGroupSecretSource',
        'Get-AdoVariableGroupUpdate',
        'New-AdoVariableGroupPayload',
        'Set-AdoVariableGroupValue',
        'Rename-AdoVariableGroup',
        'Get-AdoServiceEndpoint',
        'New-AdoSshServiceEndpoint',
        'Get-AdoServiceEndpointStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'VariableGroups', 'ServiceConnections', 'Secrets')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
