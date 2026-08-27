<#
    Shared fixtures for the test suite.

    Every fixture here is invented. That is a rule, not a convenience: a test that
    borrows a real Team name, host name or credential turns the test suite into
    another place sensitive data can leak from, and test files are the last place
    anyone thinks to look for it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    <#
    .SYNOPSIS
        Returns the repository root, from the location of this file.

    .EXAMPLE
        Get-RepositoryRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function New-BoardColumnFixture {
    <#
    .SYNOPSIS
        Builds one Board column, shaped like the API response.

    .PARAMETER Name
        Column name.

    .PARAMETER ColumnType
        incoming, inProgress or outgoing.

    .PARAMETER StateMapping
        Work Item type to state.

    .PARAMETER Id
        Existing column id. Omit for a declared column, which has none yet.

    .PARAMETER ItemLimit
        Work-in-progress limit.

    .PARAMETER PreviousName
        Names this column used to have.

    .EXAMPLE
        New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-1'
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('incoming', 'inProgress', 'outgoing')] [string] $ColumnType,
        [Parameter(Mandatory)] [hashtable] $StateMapping,
        [string] $Id,
        [int] $ItemLimit = 0,
        [string[]] $PreviousName
    )

    $column = [ordered]@{
        name          = $Name
        columnType    = $ColumnType
        stateMappings = [pscustomobject]$StateMapping
        isSplit       = $false
        description   = ''
    }
    # Emitted only when asked for, so a fixture can represent a column that
    # declares no limit - which is what lets a test prove an undeclared limit is
    # preserved rather than reset to zero.
    if ($PSBoundParameters.ContainsKey('ItemLimit')) { $column.itemLimit = $ItemLimit }
    if ($Id) { $column.id = $Id }
    if ($PreviousName) { $column.previousNames = @($PreviousName) }

    return [pscustomobject]$column
}

function New-BoardFixture {
    <#
    .SYNOPSIS
        Builds the canonical four-column Board used across the column tests.

    .DESCRIPTION
        Two shapes from one function, so a test never has to state which columns it
        expects to be unchanged - only what it is actually testing.

    .PARAMETER Live
        Return the live shape, with ids, instead of the declared shape.

    .EXAMPLE
        New-BoardFixture -Live
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch] $Live)

    if ($Live) {
        return @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming   -StateMapping @{ Issue = 'To Do' } -Id 'col-todo')
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-doing')
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing   -StateMapping @{ Issue = 'Done' }  -Id 'col-done')
        )
    }

    return @(
        (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming   -StateMapping @{ Issue = 'To Do' })
        (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
        (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing   -StateMapping @{ Issue = 'Done' })
    )
}

function New-VariableGroupFixture {
    <#
    .SYNOPSIS
        Builds a Variable Group, shaped like the API response.

    .PARAMETER Variable
        Key to @{ value; isSecret }.

    .PARAMETER Name
        Group name.

    .EXAMPLE
        New-VariableGroupFixture -Variable @{ HOST = @{ value = 'h'; isSecret = $false } }
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Variable,
        [string] $Name = 'Credentials_APP_TEST_DEV'
    )

    $variables = [ordered]@{}
    foreach ($key in $Variable.Keys) {
        $variables[$key] = [pscustomobject]@{
            value    = $Variable[$key].value
            isSecret = [bool]$Variable[$key].isSecret
        }
    }

    return [pscustomobject]@{
        id                             = 42
        name                           = $Name
        description                    = 'Fixture.'
        type                           = 'Vsts'
        variables                      = [pscustomobject]$variables
        variableGroupProjectReferences = @(
            [pscustomobject]@{
                projectReference = [pscustomobject]@{ id = 'project-id'; name = 'Platform' }
                name             = $Name
                description      = 'Fixture.'
            }
        )
    }
}
