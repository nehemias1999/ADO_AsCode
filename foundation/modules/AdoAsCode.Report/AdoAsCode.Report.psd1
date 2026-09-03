@{
    RootModule        = 'AdoAsCode.Report.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7f8091a-1324-4fd0-8142-6d7e8f9a0b16'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Evidence writing: plan reports as JSON and Markdown, incremental apply receipts that survive an interrupted run, and redaction applied at the writer.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('AdoAsCode.Plan')

    FunctionsToExport = @(
        'Remove-SensitiveValue',
        'New-AdoAsCodeProvenance',
        'Write-AdoAsCodeLog',
        'Write-AdoAsCodeReport',
        'Format-AdoAsCodeReportMarkdown',
        'Save-AdoAsCodeReceipt',
        'Get-AdoAsCodeReceiptPath'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Reporting', 'Evidence', 'Redaction')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
