@{
    RootModule        = 'AdoAsCode.Configuration.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'f5d6e7a8-9102-4dbe-8f20-4b5c6d7e8f94'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Loads declared state: .env files into the process environment, JSON configuration validated against the schema it declares, and membership lists resolved from environment variables rather than from Git.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Import-AdoAsCodeEnvironment',
        'Resolve-AdoAsCodePath',
        'Test-AdoAsCodeConfiguration',
        'Get-AdoAsCodeConfiguration',
        'Get-AdoAsCodeMemberList'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Configuration', 'JsonSchema', 'DotEnv')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
