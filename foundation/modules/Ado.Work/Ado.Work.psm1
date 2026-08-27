<#
    Ado.Work - the work-tracking surface: classification nodes (Area and Iteration
    Paths), team work settings, and Board column reconciliation.

    The Board column reconciliation engine is the most load-bearing logic in this
    repository, and the reason is worth stating once here. Azure DevOps has no
    per-column endpoint: the only way to change a Board is to PUT the complete
    column collection. A naive implementation therefore destroys anything it did
    not know about, and a column carries Work Items - so a lost column is lost
    work in a place people can see.

    Three invariants hold across every write path:

    1. No column is ever deleted. A column that exists but is not declared is
       preserved.
    2. Exactly one 'incoming' column, first, and exactly one 'outgoing' column,
       last. Azure DevOps rejects the whole PUT otherwise, so a preserved column
       of either type is re-typed to 'inProgress' and inserted before the outgoing
       one.
    3. An existing column's id is reused whenever the engine can prove which
       declared column it corresponds to. Reusing the id renames the column and
       keeps its Work Items; allocating a new id moves them to a new column and
       leaves a duplicate behind forever, because of invariant 1.

    One naming rule, learned the hard way: collection parameters here are PLURAL
    ($DesiredColumns, $ExistingColumns) and loop variables are singular. PowerShell
    variable names are case insensitive, so a loop written as
    `foreach ($existingColumn in $existing)` against a parameter declared
    `[object[]] $ExistingColumn` assigns each item to the TYPED parameter variable,
    which silently wraps it in a one-element array. Property reads keep working
    through member enumeration, so nothing throws - but
    `$column.PSObject.Properties.Name -contains 'previousNames'` becomes false,
    and rename-by-previous-name stops firing without a single error.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Azure DevOps returns this for a Team whose backlog iteration was never set.
$script:EmptyGuid = '00000000-0000-0000-0000-000000000000'

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Reads an optional property, returning a default when it is absent.

    .DESCRIPTION
        This module runs under Set-StrictMode, where touching a missing property is
        a terminating error rather than $null. That strictness is worth keeping - it
        catches typos in property names - but the pure column functions must also
        accept partial objects: a hand-built test fixture, or a response from a
        future API version that stopped emitting an optional field.

    .PARAMETER Object
        Object to read from.

    .PARAMETER Name
        Property name.

    .PARAMETER Default
        Value returned when the property is absent or null.

    .EXAMPLE
        Get-PropertyValue -Object $column -Name 'itemLimit' -Default 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

#region Classification nodes (Area and Iteration Paths)

function Get-AdoClassificationNode {
    <#
    .SYNOPSIS
        Reads one Area or Iteration Path node, or $null when it does not exist.

    .DESCRIPTION
        A missing node is an expected outcome, not a failure - the whole point of a
        plan is to discover what is absent - so a 404 is translated to $null while
        any other status still throws.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER StructureGroup
        'Areas' or 'Iterations'.

    .PARAMETER RelativePath
        Backslash-separated path below the project root, for example
        'APP_ALPHA_Team\Development'. An empty value returns the root node.

    .EXAMPLE
        Get-AdoClassificationNode -Context $context -StructureGroup Areas -RelativePath 'APP_ALPHA_Team'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [ValidateSet('Areas', 'Iterations')] [string] $StructureGroup,
        [AllowEmptyString()] [string] $RelativePath = ''
    )

    $path = "_apis/wit/classificationnodes/$StructureGroup"
    if (-not [string]::IsNullOrWhiteSpace($RelativePath)) {
        $segments = @(
            $RelativePath.Trim('\') -split '\\' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { [Uri]::EscapeDataString($_) }
        )
        $path = "$path/$($segments -join '/')"
    }

    $uri = New-AdoUri -Context $Context -Path $path -IncludeProject
    return Invoke-AdoRest -Context $Context -Method Get -Uri $uri -AllowNotFound
}

function Initialize-AdoClassificationPath {
    <#
    .SYNOPSIS
        Creates every missing segment of an Area or Iteration Path and returns the
        leaf node.

    .DESCRIPTION
        Azure DevOps creates one node at a time, under a named parent, so a nested
        path has to be walked segment by segment. The walk is idempotent: a segment
        that already exists is left alone, which is what makes it safe to call on
        every apply.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER StructureGroup
        'Areas' or 'Iterations'.

    .PARAMETER RelativePath
        Backslash-separated path below the project root.

    .EXAMPLE
        Initialize-AdoClassificationPath -Context $context -StructureGroup Iterations -RelativePath 'APP_ALPHA_Team\Sprint 01'

    .OUTPUTS
        The leaf node object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [ValidateSet('Areas', 'Iterations')] [string] $StructureGroup,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $segments = @($RelativePath.Trim('\') -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return Get-AdoClassificationNode -Context $Context -StructureGroup $StructureGroup -RelativePath ''
    }

    $node = $null
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $currentPath = ($segments[0..$index] -join '\')
        $node = Get-AdoClassificationNode -Context $Context -StructureGroup $StructureGroup -RelativePath $currentPath
        if ($null -ne $node) { continue }

        if (-not $PSCmdlet.ShouldProcess($currentPath, "Create $StructureGroup node")) { continue }

        $parentPath = "_apis/wit/classificationnodes/$StructureGroup"
        if ($index -gt 0) {
            $parentSegments = @($segments[0..($index - 1)] | ForEach-Object { [Uri]::EscapeDataString($_) })
            $parentPath = "$parentPath/$($parentSegments -join '/')"
        }

        $uri = New-AdoUri -Context $Context -Path $parentPath -IncludeProject
        $node = Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{ name = $segments[$index] }
        Write-Verbose "Created $StructureGroup node '$currentPath'."
    }

    return $node
}

function Rename-AdoAreaPath {
    <#
    .SYNOPSIS
        Renames an Area Path node.

    .DESCRIPTION
        This is the least reversible operation in the repository. Azure DevOps
        rewrites System.AreaPath on every Work Item under the node, so queries,
        dashboards and saved charts that filter on the old path stop matching, and
        the change cannot be undone by renaming back - the revision history keeps
        both entries.

        It is therefore never part of a routine apply: the caller must ask for a
        rename explicitly.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER RelativePath
        Current path of the node, below the project root.

    .PARAMETER NewName
        New leaf name. The parent is not changed.

    .EXAMPLE
        Rename-AdoAreaPath -Context $context -RelativePath 'APP_OLD_Team' -NewName 'APP_ALPHA_Team'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [string] $NewName
    )

    if (-not $PSCmdlet.ShouldProcess($RelativePath, "Rename Area Path to '$NewName' (rewrites System.AreaPath on every Work Item below it)")) { return }

    $segments = @(
        $RelativePath.Trim('\') -split '\\' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [Uri]::EscapeDataString($_) }
    )
    $uri = New-AdoUri -Context $Context -Path "_apis/wit/classificationnodes/Areas/$($segments -join '/')" -IncludeProject
    return Invoke-AdoRest -Context $Context -Method Patch -Uri $uri -Body @{ name = $NewName }
}

#endregion

#region Team work settings

function Get-AdoTeamSetting {
    <#
    .SYNOPSIS
        Reads the work settings of a Team: backlog iteration, visible backlogs,
        working days.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .EXAMPLE
        (Get-AdoTeamSetting -Context $context -TeamName 'APP_ALPHA_Team').backlogIteration.id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings' -IncludeProject -TeamName $TeamName
    return Invoke-AdoRest -Context $Context -Method Get -Uri $uri
}

function Get-AdoTeamFieldValue {
    <#
    .SYNOPSIS
        Reads the Area Path values assigned to a Team.

    .DESCRIPTION
        `defaultValue` is the Area Path stamped on Work Items the Team creates;
        `values` is the set of paths whose items appear on its Board. A Team with an
        empty team field has a Board that shows nothing.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .EXAMPLE
        Get-AdoTeamFieldValue -Context $context -TeamName 'APP_ALPHA_Team'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings/teamfieldvalues' -IncludeProject -TeamName $TeamName
    return Invoke-AdoRest -Context $Context -Method Get -Uri $uri
}

function Get-AdoTeamIteration {
    <#
    .SYNOPSIS
        Lists the iterations subscribed by a Team.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .EXAMPLE
        Get-AdoTeamIteration -Context $context -TeamName 'APP_ALPHA_Team'
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings/iterations' -IncludeProject -TeamName $TeamName
    return @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)
}

function Add-AdoTeamIteration {
    <#
    .SYNOPSIS
        Subscribes a Team to an existing project iteration.

    .DESCRIPTION
        Creating the iteration node and subscribing a Team to it are two different
        operations. A node that exists but is not subscribed does not appear in the
        Team's sprint list, which reads as "the automation did nothing".

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER IterationId
        Identifier of the iteration node, from Initialize-AdoClassificationPath.

    .EXAMPLE
        Add-AdoTeamIteration -Context $context -TeamName 'APP_ALPHA_Team' -IterationId $node.identifier
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $IterationId
    )

    if (-not $PSCmdlet.ShouldProcess($TeamName, "Subscribe Team to iteration $IterationId")) { return }

    $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings/iterations' -IncludeProject -TeamName $TeamName
    return Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{ id = $IterationId }
}

function Get-AdoWorkItemTypeState {
    <#
    .SYNOPSIS
        Lists the valid states of a Work Item type in the project's process.

    .DESCRIPTION
        Board columns map to states, and the state names come from the process
        template, not from this repository. Validating a declared mapping against
        the live states turns an opaque HTTP 400 on the column PUT into a specific
        message naming the state that does not exist.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER WorkItemType
        Work Item type name, for example 'Issue'.

    .EXAMPLE
        (Get-AdoWorkItemTypeState -Context $context -WorkItemType 'Issue').name
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $WorkItemType
    )

    $uri = New-AdoUri -Context $Context `
        -Path "_apis/wit/workitemtypes/$([Uri]::EscapeDataString($WorkItemType))/states" -IncludeProject
    return @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)
}

function Initialize-AdoTeamWorkConfiguration {
    <#
    .SYNOPSIS
        Makes a newly created Team's Board usable.

    .DESCRIPTION
        Creating a Team through the API produces a Team whose Board fails to open
        with TF400509, because three things are still missing:

        * a backlog iteration - copied from a template Team, since there is no way
          to invent a sensible default;
        * an Area Path node named after the Team;
        * a team field value pointing at that Area Path.

        Each step is skipped when already correct, so the function is safe to run on
        every apply and reports which steps it actually performed.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team to configure.

    .PARAMETER AreaPath
        Full Area Path to set as the Team default, including the project segment.

    .PARAMETER TemplateTeamName
        Team to copy the backlog iteration from. Any established Team in the project
        works; the value belongs in project-context.json rather than in code.

    .PARAMETER WorkingDays
        Working days to set alongside the backlog iteration.

    .PARAMETER DefaultIterationMacro
        Macro for the default iteration, normally '@currentIteration'.

    .EXAMPLE
        Initialize-AdoTeamWorkConfiguration -Context $context -TeamName 'APP_ALPHA_Team' `
            -AreaPath 'Platform\APP_ALPHA_Team' -TemplateTeamName 'Platform Team'

    .OUTPUTS
        PSCustomObject with the boolean results BacklogIterationSet, AreaPathCreated
        and TeamFieldSet.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $AreaPath,
        [Parameter(Mandatory)] [string] $TemplateTeamName,
        [string[]] $WorkingDays = @('monday', 'tuesday', 'wednesday', 'thursday', 'friday'),
        [string] $DefaultIterationMacro = '@currentIteration'
    )

    $result = [ordered]@{
        BacklogIterationSet = $false
        AreaPathCreated     = $false
        TeamFieldSet        = $false
    }

    # The Area Path node has to exist before it can be assigned as a team field.
    $areaRelativePath = $AreaPath
    $projectPrefix = "$($Context.ProjectName)\"
    if ($areaRelativePath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $areaRelativePath = $areaRelativePath.Substring($projectPrefix.Length)
    }

    if (-not (Get-AdoClassificationNode -Context $Context -StructureGroup Areas -RelativePath $areaRelativePath)) {
        Initialize-AdoClassificationPath -Context $Context -StructureGroup Areas -RelativePath $areaRelativePath | Out-Null
        $result.AreaPathCreated = $true
    }

    $settings = Get-AdoTeamSetting -Context $Context -TeamName $TeamName
    $backlogIterationId = "$($settings.backlogIteration.id)"
    if ([string]::IsNullOrWhiteSpace($backlogIterationId) -or $backlogIterationId -eq $script:EmptyGuid) {
        $templateSettings = Get-AdoTeamSetting -Context $Context -TeamName $TemplateTeamName
        $templateBacklogIteration = "$($templateSettings.backlogIteration.id)"
        if ([string]::IsNullOrWhiteSpace($templateBacklogIteration) -or $templateBacklogIteration -eq $script:EmptyGuid) {
            throw "Template Team '$TemplateTeamName' has no backlog iteration to copy. Point defaults.boardTemplateTeam at a Team whose Board already works."
        }

        if ($PSCmdlet.ShouldProcess($TeamName, 'Set backlog iteration')) {
            $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings' -IncludeProject -TeamName $TeamName
            Invoke-AdoRest -Context $Context -Method Patch -Uri $uri -Body @{
                backlogIteration      = $templateBacklogIteration
                defaultIterationMacro = $DefaultIterationMacro
                workingDays           = @($WorkingDays)
            } | Out-Null
            $result.BacklogIterationSet = $true
        }
    }

    $fieldValues = Get-AdoTeamFieldValue -Context $Context -TeamName $TeamName
    if ("$($fieldValues.defaultValue)" -ne $AreaPath -or @($fieldValues.values).Count -eq 0) {
        if ($PSCmdlet.ShouldProcess($TeamName, "Set team field to '$AreaPath'")) {
            $uri = New-AdoUri -Context $Context -Path '_apis/work/teamsettings/teamfieldvalues' -IncludeProject -TeamName $TeamName
            Invoke-AdoRest -Context $Context -Method Patch -Uri $uri -Body @{
                defaultValue = $AreaPath
                values       = @(@{ value = $AreaPath; includeChildren = $false })
            } | Out-Null
            $result.TeamFieldSet = $true
        }
    }

    return [pscustomobject]$result
}

#endregion

#region Board column reconciliation

function Get-AdoBoard {
    <#
    .SYNOPSIS
        Lists the Boards of a Team, or returns one Board by name.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER Name
        Exact Board name. When supplied, returns that Board or $null.

    .EXAMPLE
        Get-AdoBoard -Context $context -TeamName 'APP_ALPHA_Team' -Name 'Issues'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [string] $Name
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/work/boards' -IncludeProject -TeamName $TeamName
    $boards = @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)

    if (-not $PSBoundParameters.ContainsKey('Name')) { return $boards }
    return @($boards | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Get-AdoBoardColumn {
    <#
    .SYNOPSIS
        Reads the current columns of a Board, in order.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER BoardId
        Board identifier.

    .EXAMPLE
        Get-AdoBoardColumn -Context $context -TeamName 'APP_ALPHA_Team' -BoardId $board.id
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $BoardId
    )

    $uri = New-AdoUri -Context $Context `
        -Path "_apis/work/boards/$([Uri]::EscapeDataString($BoardId))/columns" -IncludeProject -TeamName $TeamName
    return @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)
}

function Set-AdoBoardColumn {
    <#
    .SYNOPSIS
        Writes the complete column collection of a Board.

    .DESCRIPTION
        Azure DevOps has no per-column route: this PUT replaces the whole
        collection. Always build the payload with New-AdoBoardColumnPayload, which
        preserves what is not declared. Passing a hand-built array here deletes
        every column missing from it.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER BoardId
        Board identifier.

    .PARAMETER Columns
        Complete, ordered column collection.

    .EXAMPLE
        Set-AdoBoardColumn -Context $context -TeamName 'APP_ALPHA_Team' -BoardId $board.id -Columns $payload
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $BoardId,
        [Parameter(Mandatory)] [object[]] $Columns
    )

    if (-not $PSCmdlet.ShouldProcess($BoardId, "Replace $(@($Columns).Count) Board column(s)")) { return }

    $uri = New-AdoUri -Context $Context `
        -Path "_apis/work/boards/$([Uri]::EscapeDataString($BoardId))/columns" -IncludeProject -TeamName $TeamName
    return Invoke-AdoRest -Context $Context -Method Put -Uri $uri -Body @($Columns)
}

function Test-AdoBoardColumnTemplate {
    <#
    .SYNOPSIS
        Validates a declared column template before anything is read from Azure
        DevOps.

    .DESCRIPTION
        A pure function, so it runs during `validate` with no network access. It
        enforces the shape Azure DevOps requires plus the shape this repository
        requires, and it fails on the ambiguities the reconciler could not resolve
        later:

        * `preserveUndeclaredColumns` must be true - the automation never deletes.
        * Exactly one incoming column, first; exactly one outgoing column, last.
        * No duplicate declared names, and every column has a state mapping.
        * A `previousNames` entry may not also be a declared column name, and two
          columns may not claim the same previous name. Either case would need a
          deletion to resolve.

    .PARAMETER Template
        Parsed board-columns configuration.

    .EXAMPLE
        Test-AdoBoardColumnTemplate -Template $boardColumns

    .OUTPUTS
        The validated template, so the call can be chained.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Template
    )

    if ($null -eq $Template) {
        throw 'The Board column template is empty.'
    }
    if ([string]::IsNullOrWhiteSpace("$($Template.name)")) {
        throw 'The Board column template requires "name" with the target Board.'
    }
    if (-not [bool]$Template.preserveUndeclaredColumns) {
        throw 'The Board column template must declare preserveUndeclaredColumns = true. This automation never deletes a column.'
    }

    $columns = @($Template.columns)
    if ($columns.Count -eq 0) {
        throw 'The Board column template requires at least one column.'
    }

    $names = @($columns | ForEach-Object { "$($_.name)" })
    $duplicates = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw "The Board column template declares duplicate names: $(@($duplicates | ForEach-Object { $_.Name }) -join ', ')."
    }

    foreach ($column in $columns) {
        if ([string]::IsNullOrWhiteSpace("$($column.name)")) {
            throw 'Every column in the template requires "name".'
        }
        if (@('incoming', 'inProgress', 'outgoing') -notcontains "$($column.columnType)") {
            throw "Column '$($column.name)' requires columnType incoming, inProgress or outgoing."
        }
        if (@($column.stateMappings.PSObject.Properties).Count -eq 0) {
            throw "Column '$($column.name)' requires stateMappings."
        }
    }

    # Azure DevOps rejects the entire PUT when these two rules are broken, with a
    # message that does not say which column is at fault.
    $incoming = @($columns | Where-Object { $_.columnType -eq 'incoming' })
    if ($incoming.Count -ne 1 -or $columns[0].columnType -ne 'incoming') {
        throw 'The Board column template requires exactly one incoming column, and it must be first.'
    }
    $outgoing = @($columns | Where-Object { $_.columnType -eq 'outgoing' })
    if ($outgoing.Count -ne 1 -or $columns[$columns.Count - 1].columnType -ne 'outgoing') {
        throw 'The Board column template requires exactly one outgoing column, and it must be last.'
    }

    # previousNames is transitional: it names columns that should no longer exist
    # under their old name. Validating it more strictly than the matcher does would
    # let a collision through that only explodes later, while building the payload.
    $claimedPreviousNames = New-Object System.Collections.Generic.List[string]
    foreach ($column in $columns) {
        if ($column.PSObject.Properties.Name -notcontains 'previousNames') { continue }
        foreach ($previousName in @($column.previousNames)) {
            if ([string]::IsNullOrWhiteSpace("$previousName")) {
                throw "Column '$($column.name)' declares an empty previousNames entry."
            }
            if ($names -contains "$previousName") {
                throw "Column '$($column.name)' declares previous name '$previousName', which is also a declared column name. That rename cannot be resolved without deleting a column."
            }
            if ($claimedPreviousNames -contains "$previousName") {
                throw "Previous name '$previousName' is declared by more than one column. Two declared columns cannot claim the same existing column."
            }
            $claimedPreviousNames.Add("$previousName")
        }
    }

    return $Template
}

function Get-AdoBoardColumnRenameConflict {
    <#
    .SYNOPSIS
        Detects a Board that holds both the new and the old name of a renamed column.

    .DESCRIPTION
        This happens when someone creates the new column by hand without retiring
        the old one. The state cannot be reconciled: the declared column claims the
        new name by exact match, and the old column would be preserved as a
        permanent duplicate, because the reconciler never deletes. Blocking is the
        honest outcome; silently duplicating is not.

        Pure function.

    .PARAMETER DesiredColumns
        Declared columns.

    .PARAMETER ExistingColumns
        Columns currently on the Board.

    .EXAMPLE
        Get-AdoBoardColumnRenameConflict -DesiredColumns $desired -ExistingColumns $existing

    .OUTPUTS
        An array of human-readable conflict descriptions; empty when there are none.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DesiredColumns,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingColumns
    )

    $conflicts = New-Object System.Collections.Generic.List[string]
    $existing = @($ExistingColumns)

    foreach ($desired in @($DesiredColumns)) {
        if ($desired.PSObject.Properties.Name -notcontains 'previousNames') { continue }
        if (@($existing | Where-Object { $_.name -eq $desired.name }).Count -eq 0) { continue }

        foreach ($previousName in @($desired.previousNames)) {
            if ([string]::IsNullOrWhiteSpace("$previousName")) { continue }
            if (@($existing | Where-Object { $_.name -eq "$previousName" }).Count -gt 0) {
                $conflicts.Add("the Board has both '$($desired.name)' and '$previousName'; retire the old column by hand before reconciling")
            }
        }
    }

    return @($conflicts.ToArray())
}

function Test-AdoBoardColumnDrift {
    <#
    .SYNOPSIS
        Reports whether reconciling the Board would change anything.

    .DESCRIPTION
        Drift is defined as "the write would produce a different collection than the
        one that is live". The comparison is therefore made against the payload the
        reconciler would actually send, not against the declaration on its own.

        That definition matters for two reasons.

        * Idempotency. A Board can legitimately carry columns nobody declared, and
          the reconciler preserves them by inserting them before the outgoing
          column. A naive position-by-position comparison of declaration against
          live state sees the shifted positions as drift forever, so every apply
          rewrites the Board and no run is ever a no-op. Comparing against the
          payload makes a second apply genuinely do nothing, which is what allows
          idempotency to be used as the acceptance criterion for a change.
        * Renames still fire. The payload reuses the existing id under the new name,
          so a Board still carrying the old name differs from the payload and is
          correctly reported as drift. Comparing declaration against live state by
          name would have worked here too, but only by accident.

        Pure function. Warnings from the payload builder are suppressed: this is a
        comparison, and the caller that performs the write emits them.

    .PARAMETER DesiredColumns
        Declared columns, in order.

    .PARAMETER ExistingColumns
        Columns currently on the Board, in order.

    .EXAMPLE
        (Test-AdoBoardColumnDrift -DesiredColumns $desired -ExistingColumns $existing).hasDrift

    .OUTPUTS
        PSCustomObject with hasDrift and reasons.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DesiredColumns,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingColumns
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $existing = @($ExistingColumns)

    try {
        $payload = @(New-AdoBoardColumnPayload -DesiredColumns $DesiredColumns -ExistingColumns $ExistingColumns -WarningAction SilentlyContinue)
    }
    catch {
        # An unresolvable Board - the new and the old name of a renamed column both
        # present - is drift that a human has to clear. Report it rather than
        # throwing, so a plan can show it alongside everything else.
        return [pscustomobject]@{
            hasDrift = $true
            reasons  = @("$($_.Exception.Message)")
        }
    }

    if ($payload.Count -ne $existing.Count) {
        $reasons.Add("the Board would go from $($existing.Count) to $($payload.Count) column(s)")
    }

    for ($index = 0; $index -lt $payload.Count; $index++) {
        $target = $payload[$index]
        if ($index -ge $existing.Count) {
            $reasons.Add("column '$($target.name)' would be added at position $($index + 1)")
            continue
        }

        $current = $existing[$index]
        $position = $index + 1

        if ("$($current.name)" -ne "$($target.name)") {
            $reasons.Add("position $position would change from '$($current.name)' to '$($target.name)'")
        }
        if ("$($current.columnType)" -ne "$($target.columnType)") {
            $reasons.Add("columnType of '$($target.name)' would change from '$($current.columnType)' to '$($target.columnType)'")
        }

        $currentLimit = [int](Get-PropertyValue -Object $current -Name 'itemLimit' -Default 0)
        if ($currentLimit -ne [int]$target.itemLimit) {
            $reasons.Add("itemLimit of '$($target.name)' would change from $currentLimit to $($target.itemLimit)")
        }

        foreach ($mapping in $target.stateMappings.PSObject.Properties) {
            $currentState = Get-PropertyValue -Object (Get-PropertyValue -Object $current -Name 'stateMappings') -Name $mapping.Name -Default ''
            if ("$currentState" -ne "$($mapping.Value)") {
                $reasons.Add("state mapping of '$($target.name)' for '$($mapping.Name)' would change from '$currentState' to '$($mapping.Value)'")
            }
        }
    }

    return [pscustomobject]@{
        hasDrift = $reasons.Count -gt 0
        reasons  = @($reasons.ToArray())
    }
}

function New-AdoBoardColumnPayload {
    <#
    .SYNOPSIS
        Builds the complete column collection to PUT, reusing existing ids and
        preserving undeclared columns.

    .DESCRIPTION
        The heart of the engine, and a pure function so every rule below is covered
        by an offline test.

        Each declared column is matched to an existing column in three stages, in
        this order:

        1. Exact name. The common case.
        2. A declared `previousNames` entry. Checked before stage 3 because many
           columns can share one state mapping, and the stage 3 fallback would pick
           the first free one - possibly a column the platform owner added.
        3. An identical state mapping. This renames an existing column instead of
           creating a new one, which keeps its id and its Work Items. It is a guess
           when several columns share a mapping, so it warns when it fires.

        A matched id is recorded so no existing column is claimed twice.

        Columns that survive unmatched are preserved: re-typed to 'inProgress' when
        needed and inserted immediately before the declared outgoing column, so the
        outgoing column stays last.

    .PARAMETER DesiredColumns
        Declared columns, in order.

    .PARAMETER ExistingColumns
        Columns currently on the Board, in order.

    .EXAMPLE
        $payload = New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing

    .OUTPUTS
        The ordered column collection ready for Set-AdoBoardColumn.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DesiredColumns,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingColumns
    )

    $desired = @($DesiredColumns)
    $existing = @($ExistingColumns)

    # Every write path funnels through here, so this is where a Board holding both
    # the new and the old column name gets stopped.
    $conflicts = @(Get-AdoBoardColumnRenameConflict -DesiredColumns $desired -ExistingColumns $existing)
    if ($conflicts.Count -gt 0) {
        throw "Board columns cannot be reconciled: $($conflicts -join '; ')."
    }

    $payload = New-Object System.Collections.Generic.List[object]
    $claimedIds = New-Object System.Collections.Generic.List[string]

    foreach ($desiredColumn in $desired) {
        # Stage 1: exact name.
        $match = @($existing | Where-Object {
            $_.name -eq $desiredColumn.name -and ($claimedIds -notcontains $_.id)
        }) | Select-Object -First 1

        # Stage 2: declared previous name.
        if ($null -eq $match -and $desiredColumn.PSObject.Properties.Name -contains 'previousNames') {
            foreach ($previousName in @($desiredColumn.previousNames)) {
                if ([string]::IsNullOrWhiteSpace("$previousName")) { continue }
                $match = @($existing | Where-Object {
                    $_.name -eq "$previousName" -and ($claimedIds -notcontains $_.id)
                }) | Select-Object -First 1
                if ($null -ne $match) { break }
            }
        }

        # Stage 3: identical state mapping.
        if ($null -eq $match -and @($desiredColumn.stateMappings.PSObject.Properties).Count -gt 0) {
            $match = @($existing | Where-Object {
                if ($claimedIds -contains $_.id -or $null -eq $_.stateMappings) { return $false }
                $expected = @($desiredColumn.stateMappings.PSObject.Properties)
                $actual = @($_.stateMappings.PSObject.Properties)
                if ($expected.Count -ne $actual.Count) { return $false }
                foreach ($mapping in $expected) {
                    if ($_.stateMappings.PSObject.Properties.Name -notcontains $mapping.Name) { return $false }
                    if ($_.stateMappings.($mapping.Name) -ne $mapping.Value) { return $false }
                }
                return $true
            }) | Select-Object -First 1

            if ($null -ne $match) {
                Write-Warning "Column '$($desiredColumn.name)': no match by name or previousNames, so the existing column '$($match.name)' was reused because its state mapping is identical. Verify its Work Items."
            }
        }

        $column = [ordered]@{
            name          = $desiredColumn.name
            columnType    = $desiredColumn.columnType
            stateMappings = $desiredColumn.stateMappings
            itemLimit     = 0
            isSplit       = $false
            description   = ''
        }

        # Declared value wins; otherwise keep what the Board already had; otherwise
        # a neutral default. Silently resetting itemLimit to 0 would wipe a
        # work-in-progress limit somebody set on purpose.
        if ($desiredColumn.PSObject.Properties.Name -contains 'itemLimit') { $column.itemLimit = [int]$desiredColumn.itemLimit }
        elseif ($match) { $column.itemLimit = [int](Get-PropertyValue -Object $match -Name 'itemLimit' -Default 0) }

        if ($desiredColumn.PSObject.Properties.Name -contains 'isSplit') { $column.isSplit = [bool]$desiredColumn.isSplit }
        elseif ($match) { $column.isSplit = [bool](Get-PropertyValue -Object $match -Name 'isSplit' -Default $false) }

        if ($desiredColumn.PSObject.Properties.Name -contains 'description') { $column.description = "$($desiredColumn.description)" }
        elseif ($match) { $column.description = "$(Get-PropertyValue -Object $match -Name 'description' -Default '')" }

        $matchId = Get-PropertyValue -Object $match -Name 'id' -Default ''
        if (-not [string]::IsNullOrWhiteSpace($matchId)) {
            $column.id = $matchId
            $claimedIds.Add("$matchId")
        }

        $payload.Add([pscustomobject]$column)
    }

    $preserved = New-Object System.Collections.Generic.List[object]
    foreach ($existingColumn in $existing) {
        $existingId = "$(Get-PropertyValue -Object $existingColumn -Name 'id' -Default '')"
        if ($claimedIds -contains $existingId) { continue }

        $columnType = "$($existingColumn.columnType)"
        if ($columnType -ne 'inProgress') {
            # Azure DevOps allows one incoming and one outgoing column, and the
            # outgoing one must be last. A preserved column of either type would
            # fail the whole PUT, so it is kept as inProgress: the column and its
            # Work Items survive instead of blocking the entire reconciliation.
            Write-Warning "Preserved column '$($existingColumn.name)': columnType '$columnType' was changed to 'inProgress' so the Board stays valid."
            $columnType = 'inProgress'
        }

        $preserved.Add([pscustomobject]([ordered]@{
            id            = $existingId
            name          = $existingColumn.name
            columnType    = $columnType
            stateMappings = $existingColumn.stateMappings
            itemLimit     = [int](Get-PropertyValue -Object $existingColumn -Name 'itemLimit' -Default 0)
            isSplit       = [bool](Get-PropertyValue -Object $existingColumn -Name 'isSplit' -Default $false)
            description   = "$(Get-PropertyValue -Object $existingColumn -Name 'description' -Default '')"
        }))
    }

    $declared = @($payload.ToArray())
    if ($preserved.Count -eq 0) { return @($declared) }

    $outgoingIndex = -1
    for ($index = 0; $index -lt $declared.Count; $index++) {
        if ($declared[$index].columnType -eq 'outgoing') { $outgoingIndex = $index; break }
    }
    if ($outgoingIndex -lt 0) {
        return @(@($declared) + @($preserved.ToArray()))
    }

    $merged = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $declared.Count; $index++) {
        if ($index -eq $outgoingIndex) {
            foreach ($preservedColumn in $preserved) { $merged.Add($preservedColumn) }
        }
        $merged.Add($declared[$index])
    }
    return @($merged.ToArray())
}

function Get-AdoBoardColumnStatus {
    <#
    .SYNOPSIS
        Classifies the Board column state as a single plan operation.

    .DESCRIPTION
        Read-only. Returns the action/status/reason triple the plan model uses, and
        never throws: an unreadable Board is a blocked operation, which the plan can
        show, rather than an exception that aborts the whole run and hides every
        other finding.

        Rename conflicts are checked before drift, because a conflict can coexist
        with a clean positional diff - and the "no drift" early return would hide it.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER BoardName
        Board name.

    .PARAMETER DesiredColumns
        Declared columns.

    .EXAMPLE
        Get-AdoBoardColumnStatus -Context $context -TeamName 'APP_ALPHA_Team' -BoardName 'Issues' -DesiredColumns $desired

    .OUTPUTS
        PSCustomObject with action, status and reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $BoardName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DesiredColumns
    )

    try {
        $board = Get-AdoBoard -Context $Context -TeamName $TeamName -Name $BoardName
        if ($null -eq $board) {
            return [pscustomobject]@{
                action = 'resolve'; status = 'blocked'
                reason = "Board '$BoardName' does not exist on Team '$TeamName'."
            }
        }

        $existing = @(Get-AdoBoardColumn -Context $Context -TeamName $TeamName -BoardId $board.id)

        $conflicts = @(Get-AdoBoardColumnRenameConflict -DesiredColumns $DesiredColumns -ExistingColumns $existing)
        if ($conflicts.Count -gt 0) {
            return [pscustomobject]@{ action = 'resolve'; status = 'blocked'; reason = ($conflicts -join '; ') }
        }

        $drift = Test-AdoBoardColumnDrift -DesiredColumns $DesiredColumns -ExistingColumns $existing
        if (-not $drift.hasDrift) {
            return [pscustomobject]@{
                action = 'exists'; status = 'ok'
                reason = 'Columns, order, limits and state mappings already match.'
            }
        }

        return [pscustomobject]@{ action = 'update'; status = 'pending'; reason = ($drift.reasons -join '; ') }
    }
    catch {
        return [pscustomobject]@{
            action = 'resolve'; status = 'blocked'
            reason = "Board columns could not be read: $($_.Exception.Message)"
        }
    }
}

function Sync-AdoBoardColumn {
    <#
    .SYNOPSIS
        Reconciles a Board's columns with the declared template.

    .DESCRIPTION
        Idempotent: with no drift it returns without issuing a write, which is what
        makes a second apply a no-op and makes idempotency usable as the acceptance
        criterion for a change.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamName
        Team name.

    .PARAMETER BoardName
        Board name.

    .PARAMETER DesiredColumns
        Declared columns.

    .EXAMPLE
        Sync-AdoBoardColumn -Context $context -TeamName 'APP_ALPHA_Team' -BoardName 'Issues' -DesiredColumns $desired

    .OUTPUTS
        PSCustomObject with boardId, changed and reasons.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamName,
        [Parameter(Mandatory)] [string] $BoardName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DesiredColumns
    )

    $board = Get-AdoBoard -Context $Context -TeamName $TeamName -Name $BoardName
    if ($null -eq $board) {
        throw "Board '$BoardName' does not exist on Team '$TeamName'."
    }

    $existing = @(Get-AdoBoardColumn -Context $Context -TeamName $TeamName -BoardId $board.id)
    $drift = Test-AdoBoardColumnDrift -DesiredColumns $DesiredColumns -ExistingColumns $existing
    if (-not $drift.hasDrift) {
        return [pscustomobject]@{ boardId = $board.id; changed = $false; reasons = @() }
    }

    $payload = New-AdoBoardColumnPayload -DesiredColumns $DesiredColumns -ExistingColumns $existing
    if (-not $PSCmdlet.ShouldProcess("$TeamName/$BoardName", 'Reconcile Board columns')) {
        return [pscustomobject]@{ boardId = $board.id; changed = $false; reasons = @($drift.reasons) }
    }

    Set-AdoBoardColumn -Context $Context -TeamName $TeamName -BoardId $board.id -Columns $payload | Out-Null
    Write-Verbose "Reconciled $(@($payload).Count) column(s) on Board '$BoardName' of Team '$TeamName'."

    return [pscustomobject]@{ boardId = $board.id; changed = $true; reasons = @($drift.reasons) }
}

#endregion

Export-ModuleMember -Function @(
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
