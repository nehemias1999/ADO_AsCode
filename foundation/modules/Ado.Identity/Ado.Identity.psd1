@{
    RootModule        = 'Ado.Identity.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c2a3b4d5-6e7f-4a8b-9c0d-1e2f3a4b5c61'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Identity surface of Azure DevOps: identity resolution, Teams, memberships, Team administrators and project security groups.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('Ado.Rest')

    FunctionsToExport = @(
        'Get-AdoIdentity',
        'Get-AdoGraphDescriptor',
        'Get-AdoTeam',
        'New-AdoTeam',
        'Rename-AdoTeam',
        'Get-AdoTeamMember',
        'Add-AdoTeamMember',
        'Set-AdoTeamAdministrator',
        'Get-AdoSecurityGroup',
        'New-AdoSecurityGroup',
        'Rename-AdoSecurityGroup'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'Identity', 'Teams')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
