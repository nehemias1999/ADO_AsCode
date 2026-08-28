<#
.SYNOPSIS
    Provisions and reconciles the Azure DevOps Team, classification paths and Board
    of a declared application.

.DESCRIPTION
    One application per execution, by design. A run that touches every application
    at once produces a plan nobody reads and a failure nobody can attribute, and it
    removes the natural blast radius that makes a pilot meaningful.

    Command ladder. Only `apply`, `reconcile` and `rename` can write, and each needs
    an explicit confirmation switch:

      validate   Offline. Configuration against its schema, plus the invariants a
                 schema cannot express. No network, no Personal Access Token.
      inventory  Read-only snapshot of what exists in the organization today.
      plan       Diffs the declaration against live state and classifies every
                 operation. Writes nothing.
      smoke      Plan plus the manual verification checklist for after an apply.
      apply      Creates and reconciles. Requires -ConfirmApply.
      reconcile  Same as apply but refuses to create a Team, so it can only correct
                 an application that already exists.
      rename     Renames the Team and its Area Path. Requires -ConfirmRename.

    What this never does: delete a Team, a path, a member or a Board column; touch
    Service Connections, pipelines or project-level permissions; or commit a
    membership list. Membership is read at run time from the environment variable
    the configuration names.

.PARAMETER Command
    Operation to run. See the ladder above.

.PARAMETER ApplicationKey
    Key of the application to operate on, as declared in the configuration.
    Required by every command except validate and inventory.

.PARAMETER EnvFile
    Environment files to load, comma or list separated. The module's own members
    file is appended automatically when present.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ConfigurationPath
    Override for the applications configuration. Defaults to the active file named
    in the project context, falling back to the versioned template.

.PARAMETER BoardColumnsPath
    Override for the board column template.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/, which is not versioned.

.PARAMETER PreviousTeamName
    Current Team name, required by rename. Declared explicitly rather than derived:
    inferring a previous identity from a naming pattern produces confident, wrong
    diagnoses when the pattern changed.

.PARAMETER ConfirmApply
    Required by apply and reconcile. Without it both are pure simulations.

.PARAMETER ConfirmRename
    Required by rename, in addition to -ConfirmApply. Renaming an Area Path rewrites
    System.AreaPath on every Work Item below it and cannot be undone.

.EXAMPLE
    .\Invoke-TeamProvisioning.ps1 -Command validate

    Checks the configuration offline. Needs no credentials.

.EXAMPLE
    .\Invoke-TeamProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA

    Shows what would change. Review this with whoever owns the project.

.EXAMPLE
    .\Invoke-TeamProvisioning.ps1 -Command apply -ApplicationKey APP_ALPHA -ConfirmApply

    Applies the approved plan and writes a receipt as it goes.

.EXAMPLE
    .\Invoke-TeamProvisioning.ps1 -Command rename -ApplicationKey APP_ALPHA -PreviousTeamName APP_OLD_Team -ConfirmApply -ConfirmRename

    Renames the Team and its Area Path.

.OUTPUTS
    The plan object. The report is written to disk and its path is logged.
#>
[CmdletBinding()]
param(
    [ValidateSet('validate', 'inventory', 'plan', 'smoke', 'apply', 'reconcile', 'rename')]
    [string] $Command = 'plan',

    [string] $ApplicationKey,

    [string[]] $EnvFile = @('.env'),

    [string] $ProjectContextPath,
    [string] $ConfigurationPath,
    [string] $BoardColumnsPath,
    [string] $ReportPath,

    [string] $PreviousTeamName,

    [switch] $ConfirmApply,
    [switch] $ConfirmRename
)

Set-StrictMode -Version Latest

# Commands that operate on one declared application, so they require -ApplicationKey.
# validate and inventory are excluded: both survey everything on purpose.
# This is the set the previous check already enforced - it just enforced it late.
$script:ApplicationScopedCommands = @('plan', 'smoke', 'apply', 'reconcile', 'rename')
$ErrorActionPreference = 'Stop'

$moduleName = 'team-provisioning'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path

. (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

function Write-ModuleLog {
    <#
    .SYNOPSIS
        Writes a prefixed progress line to the information stream.

    .DESCRIPTION
        The information stream rather than the host, so a caller can capture or
        silence it. The prefix names the automation, which matters when a pipeline
        log interleaves several.

    .PARAMETER Message
        Text to write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)

    Write-Information "[$moduleName] $Message" -InformationAction Continue
}

function Get-DeclaredPath {
    <#
    .SYNOPSIS
        Normalizes a declared classification path.

    .DESCRIPTION
        Configuration uses '/' because a backslash has to be escaped in JSON and an
        escaped separator is a reliable source of typos. Azure DevOps uses '\', so
        the conversion happens once, here.

    .PARAMETER Path
        Declared path, relative to the project.

    .EXAMPLE
        Get-DeclaredPath -Path 'APP_ALPHA_Team/Sprint 01'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    return ($Path -replace '/', '\').Trim('\')
}

function Get-DeclaredPathSet {
    <#
    .SYNOPSIS
        Expands a path set into an ordered, de-duplicated list with the default first.

    .DESCRIPTION
        The default path must also be present in the full set: a Team whose default
        Area Path is not among its assigned values has a Board that shows nothing,
        and that is a confusing state to debug from the portal.

    .PARAMETER PathSet
        The areaPaths or iterationPaths object.

    .EXAMPLE
        Get-DeclaredPathSet -PathSet $application.areaPaths
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowNull()] [object] $PathSet)

    if ($null -eq $PathSet) { return @() }

    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add((Get-DeclaredPath -Path "$($PathSet.default)"))

    if ($PathSet.PSObject.Properties.Name -contains 'additional') {
        foreach ($path in @($PathSet.additional)) {
            $normalized = Get-DeclaredPath -Path "$path"
            if ($paths -notcontains $normalized) { $paths.Add($normalized) }
        }
    }

    return @($paths.ToArray())
}

function Get-TeamProvisioningApplication {
    <#
    .SYNOPSIS
        Returns the declaration of one application, or fails with a usable message.

    .PARAMETER Configuration
        Parsed applications configuration.

    .PARAMETER Key
        Application key.

    .EXAMPLE
        Get-TeamProvisioningApplication -Configuration $configuration -Key 'APP_ALPHA'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [string] $Key
    )

    $matched = @($Configuration.applications | Where-Object { "$($_.key)" -eq $Key })
    if ($matched.Count -eq 1) { return $matched[0] }

    $available = @($Configuration.applications | ForEach-Object { "$($_.key)" }) -join ', '
    if ($matched.Count -eq 0) {
        throw "Application '$Key' is not declared. Declared keys: $available."
    }
    throw "Application key '$Key' is declared $($matched.Count) times. Keys must be unique."
}

function Test-TeamProvisioningConfiguration {
    <#
    .SYNOPSIS
        Checks the invariants a JSON Schema cannot express.

    .DESCRIPTION
        Runs offline, as part of `validate`, and returns every problem rather than
        the first: a half-corrected configuration costs another round trip.

        Checked here because a schema cannot: keys and Team names must be unique
        across applications, a default path must not be repeated in `additional`,
        and the Board column template must satisfy the reconciler's rules.

    .PARAMETER Configuration
        Parsed applications configuration.

    .PARAMETER BoardColumns
        Parsed board column template.

    .EXAMPLE
        Test-TeamProvisioningConfiguration -Configuration $configuration -BoardColumns $boardColumns

    .OUTPUTS
        The problems found, as strings. Empty means the configuration is coherent.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [object] $BoardColumns
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $applications = @($Configuration.applications)

    foreach ($group in @($applications | Group-Object { "$($_.key)" } | Where-Object { $_.Count -gt 1 })) {
        $problems.Add("application key '$($group.Name)' is declared $($group.Count) times")
    }
    foreach ($group in @($applications | Group-Object { "$($_.team.name)" } | Where-Object { $_.Count -gt 1 })) {
        $problems.Add("Team name '$($group.Name)' is declared by $($group.Count) applications; two applications cannot share a Team")
    }

    foreach ($application in $applications) {
        foreach ($setName in @('areaPaths', 'iterationPaths')) {
            if ($application.PSObject.Properties.Name -notcontains $setName) { continue }
            $set = $application.$setName
            if ($null -eq $set) { continue }

            $default = Get-DeclaredPath -Path "$($set.default)"
            if ([string]::IsNullOrWhiteSpace($default)) {
                $problems.Add("$($application.key): $setName.default is empty")
                continue
            }
            if ($set.PSObject.Properties.Name -contains 'additional') {
                foreach ($path in @($set.additional)) {
                    if ((Get-DeclaredPath -Path "$path") -eq $default) {
                        $problems.Add("$($application.key): $setName.default '$default' is repeated in additional")
                    }
                }
            }
        }

        if ($application.board.name -ne $BoardColumns.name) {
            $problems.Add("$($application.key): board.name is '$($application.board.name)' but the column template targets '$($BoardColumns.name)'")
        }
    }

    try {
        Test-AdoBoardColumnTemplate -Template $BoardColumns | Out-Null
    }
    catch {
        $problems.Add("board columns: $($_.Exception.Message)")
    }

    return @($problems.ToArray())
}

function Get-TeamProvisioningInventory {
    <#
    .SYNOPSIS
        Reads the live state relevant to one application.

    .DESCRIPTION
        One read pass, reused by plan, smoke and apply, so a plan cannot disagree
        with the apply that follows it because they looked at different moments.

        A Team that does not exist yet is not an error: the returned object simply
        reports it as absent, along with the paths and Board that therefore cannot
        be inspected.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Application
        Application declaration.

    .EXAMPLE
        Get-TeamProvisioningInventory -Context $context -Project $project -Application $application

    .OUTPUTS
        PSCustomObject describing the Team, its members, its paths and its Board.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $Application
    )

    $teamName = "$($Application.team.name)"
    $team = Get-AdoTeam -Context $Context -Project $Project -Name $teamName

    $inventory = [ordered]@{
        teamName       = $teamName
        team           = $team
        members        = @()
        settings       = $null
        teamField      = $null
        board          = $null
        boardColumns   = @()
        areaNodes      = @{}
        iterationNodes = @{}
    }

    foreach ($path in (Get-DeclaredPathSet -PathSet $Application.areaPaths)) {
        $inventory.areaNodes[$path] = Get-AdoClassificationNode -Context $Context -StructureGroup Areas -RelativePath $path
    }
    if ($Application.PSObject.Properties.Name -contains 'iterationPaths') {
        foreach ($path in (Get-DeclaredPathSet -PathSet $Application.iterationPaths)) {
            $inventory.iterationNodes[$path] = Get-AdoClassificationNode -Context $Context -StructureGroup Iterations -RelativePath $path
        }
    }

    if ($null -eq $team) { return [pscustomobject]$inventory }

    $inventory.members = @(Get-AdoTeamMember -Context $Context -Project $Project -TeamId $team.id)

    # A brand new Team has no work settings yet, and asking for its Board returns an
    # error rather than an empty list. Treat that as "not configured" instead of
    # letting it abort the inventory of everything else.
    try {
        $inventory.settings = Get-AdoTeamSetting -Context $Context -TeamName $teamName
        $inventory.teamField = Get-AdoTeamFieldValue -Context $Context -TeamName $teamName
    }
    catch {
        Write-Verbose "Team '$teamName' has no usable work settings yet: $($_.Exception.Message)"
    }

    try {
        $board = Get-AdoBoard -Context $Context -TeamName $teamName -Name "$($Application.board.name)"
        $inventory.board = $board
        if ($null -ne $board) {
            $inventory.boardColumns = @(Get-AdoBoardColumn -Context $Context -TeamName $teamName -BoardId $board.id)
        }
    }
    catch {
        Write-Verbose "Board '$($Application.board.name)' is not available yet on '$teamName': $($_.Exception.Message)"
    }

    return [pscustomobject]$inventory
}

function New-TeamProvisioningPlan {
    <#
    .SYNOPSIS
        Builds the plan for one application.

    .DESCRIPTION
        Every operation the automation could perform appears in the plan, including
        the ones already satisfied, so a reviewer sees the full intended shape of the
        application rather than only the delta. Counts of `ok` operations are what
        make a re-run recognisable as idempotent.

        `reconcile` differs from `apply` in exactly one way, expressed here: a
        missing Team becomes a blocked operation instead of a create, so a command
        meant to correct an existing application can never quietly stand one up.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Application
        Application declaration.

    .PARAMETER BoardColumns
        Board column template.

    .PARAMETER Inventory
        Live state from Get-TeamProvisioningInventory.

    .PARAMETER ProjectContext
        Shared project context.

    .PARAMETER CommandName
        Command being planned: plan, smoke, apply or reconcile.

    .EXAMPLE
        New-TeamProvisioningPlan -Context $context -Project $project -Application $application `
            -BoardColumns $boardColumns -Inventory $inventory -ProjectContext $projectContext -CommandName plan

    .OUTPUTS
        A plan object from New-Plan.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $Application,
        [Parameter(Mandatory)] [object] $BoardColumns,
        [Parameter(Mandatory)] [object] $Inventory,
        [Parameter(Mandatory)] [object] $ProjectContext,
        [Parameter(Mandatory)] [string] $CommandName
    )

    $plan = New-Plan -Command $CommandName -Target "$($Application.key)"
    $teamName = $Inventory.teamName
    $isReconcile = $CommandName -eq 'reconcile'

    # --- Team -------------------------------------------------------------
    if ($null -eq $Inventory.team) {
        if ($isReconcile) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $teamName `
                -Action 'resolve' -Status 'blocked' `
                -Reason 'reconcile only corrects an application that already exists. Use apply for the initial creation.')
        }
        else {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $teamName `
                -Action 'create' -Status 'pending' -Reason 'The Team does not exist.')
        }
    }
    else {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $teamName `
            -Action 'exists' -Status 'ok' -Reason 'The Team exists and is adopted as is.')
    }

    # --- Team administrator -----------------------------------------------
    if ("$($ProjectContext.defaults.teamAdministratorMode)" -eq 'authenticatedUser') {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team administrator' -Name $teamName `
            -Action 'authorize' -Status 'pending' `
            -Reason 'The identity behind the Personal Access Token is added as a member and promoted to Team administrator. Creating a Team through the API does not do this.')
    }

    # --- Classification paths ---------------------------------------------
    foreach ($pathSetName in @('areaPaths', 'iterationPaths')) {
        if ($Application.PSObject.Properties.Name -notcontains $pathSetName) { continue }

        $structureGroup = if ($pathSetName -eq 'areaPaths') { 'Areas' } else { 'Iterations' }
        $resourceLabel = if ($pathSetName -eq 'areaPaths') { 'Area Path' } else { 'Iteration Path' }
        $nodes = if ($pathSetName -eq 'areaPaths') { $Inventory.areaNodes } else { $Inventory.iterationNodes }

        foreach ($path in (Get-DeclaredPathSet -PathSet $Application.$pathSetName)) {
            $exists = $nodes.ContainsKey($path) -and $null -ne $nodes[$path]
            if ($exists) {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource $resourceLabel -Name $path `
                    -Action 'exists' -Status 'ok' -Reason "The $structureGroup node exists.")
            }
            else {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource $resourceLabel -Name $path `
                    -Action 'create' -Status 'pending' -Reason "The $structureGroup node is missing and will be created. Existing nodes are never removed.")
            }
        }
    }

    # --- Team work configuration ------------------------------------------
    $defaultAreaPath = "$($Project.name)\$(Get-DeclaredPath -Path "$($Application.areaPaths.default)")"
    $backlogIterationSet = $false
    $teamFieldSet = $false
    if ($null -ne $Inventory.settings) {
        $backlogIterationId = "$($Inventory.settings.backlogIteration.id)"
        $backlogIterationSet = -not [string]::IsNullOrWhiteSpace($backlogIterationId) -and
                               $backlogIterationId -ne '00000000-0000-0000-0000-000000000000'
    }
    if ($null -ne $Inventory.teamField) {
        $teamFieldSet = "$($Inventory.teamField.defaultValue)" -eq $defaultAreaPath
    }

    if ($backlogIterationSet -and $teamFieldSet) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team work configuration' -Name $teamName `
            -Action 'exists' -Status 'ok' -Reason "Backlog iteration is set and the default Area Path is '$defaultAreaPath'.")
    }
    else {
        $missing = New-Object System.Collections.Generic.List[string]
        if (-not $backlogIterationSet) { $missing.Add("backlog iteration (copied from '$($ProjectContext.defaults.boardTemplateTeam)')") }
        if (-not $teamFieldSet) { $missing.Add("default Area Path '$defaultAreaPath'") }

        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team work configuration' -Name $teamName `
            -Action 'set' -Status 'pending' `
            -Reason "Missing: $($missing -join '; '). Without these the Board fails to open with TF400509.")
    }

    # --- Members ----------------------------------------------------------
    if ($Application.PSObject.Properties.Name -contains 'membersEnv') {
        $membersVariable = "$($Application.membersEnv)"
        $declaredMembers = @(Get-AdoAsCodeMemberList -VariableName $membersVariable -AllowEmpty)

        if ($declaredMembers.Count -eq 0) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team membership' -Name $membersVariable `
                -Action 'skip' -Status 'warning' `
                -Reason "Environment variable '$membersVariable' is empty, so no membership is applied. Existing members are left untouched.")
        }
        else {
            $currentMembers = @($Inventory.members | ForEach-Object { "$($_.identity.uniqueName)" })
            foreach ($member in $declaredMembers) {
                if ($currentMembers -contains $member) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team member' -Name $member `
                        -Action 'exists' -Status 'ok' -Reason 'Already a member.')
                }
                else {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team member' -Name $member `
                        -Action 'add' -Status 'pending' -Reason 'Declared but not a member yet. Members are only added, never removed.')
                }
            }
        }
    }

    # --- Work Item types --------------------------------------------------
    if ($Application.board.PSObject.Properties.Name -contains 'workItemTypes') {
        foreach ($workItemType in @($Application.board.workItemTypes)) {
            try {
                $states = @(Get-AdoWorkItemTypeState -Context $Context -WorkItemType $workItemType)
                $declaredStates = @(
                    $BoardColumns.columns |
                        ForEach-Object { $_.stateMappings.PSObject.Properties } |
                        Where-Object { $_.Name -eq $workItemType } |
                        ForEach-Object { "$($_.Value)" } |
                        Select-Object -Unique
                )
                $missingStates = @($declaredStates | Where-Object { @($states | ForEach-Object { "$($_.name)" }) -notcontains $_ })

                if ($missingStates.Count -gt 0) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Work Item type' -Name $workItemType `
                        -Action 'resolve' -Status 'blocked' `
                        -Reason "State(s) '$($missingStates -join ', ')' are mapped by the column template but do not exist in the project process. Writing the columns would fail with an error that does not name the state.")
                }
                else {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Work Item type' -Name $workItemType `
                        -Action 'validate' -Status 'ok' -Reason "Exists, and every mapped state is valid ($($states.Count) state(s)).")
                }
            }
            catch {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Work Item type' -Name $workItemType `
                    -Action 'resolve' -Status 'blocked' `
                    -Reason "Not found in the project process: $($_.Exception.Message)")
            }
        }
    }

    # --- Board columns ----------------------------------------------------
    if ($null -eq $Inventory.team) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Board column' -Name "$($Application.board.name)" `
            -Action 'reconcile' -Status 'pending' `
            -Reason 'The Board does not exist yet because the Team does not. Columns are reconciled once the Team is created.')
    }
    elseif ($null -eq $Inventory.board) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Board column' -Name "$($Application.board.name)" `
            -Action 'resolve' -Status 'blocked' `
            -Reason "Board '$($Application.board.name)' was not found on Team '$teamName'. Check the Board name against the project process.")
    }
    else {
        $conflicts = @(Get-AdoBoardColumnRenameConflict -DesiredColumns $BoardColumns.columns -ExistingColumns $Inventory.boardColumns)
        if ($conflicts.Count -gt 0) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Board column' -Name "$($Application.board.name)" `
                -Action 'resolve' -Status 'blocked' -Reason ($conflicts -join '; '))
        }
        else {
            $drift = Test-AdoBoardColumnDrift -DesiredColumns $BoardColumns.columns -ExistingColumns $Inventory.boardColumns
            if ($drift.hasDrift) {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Board column' -Name "$($Application.board.name)" `
                    -Action 'reconcile' -Status 'pending' -Reason ($drift.reasons -join '; '))
            }
            else {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Board column' -Name "$($Application.board.name)" `
                    -Action 'exists' -Status 'ok' -Reason 'Columns, order, limits and state mappings already match.')
            }
        }
    }

    return $plan
}

function Invoke-TeamProvisioningApply {
    <#
    .SYNOPSIS
        Executes an approved plan, writing a receipt after every completed step.

    .DESCRIPTION
        The receipt is updated as work completes rather than at the end. An apply
        that dies partway - a token expiring, an agent being recycled - then still
        leaves a record of exactly which operations finished, which is what makes
        the next run a resume rather than a guess.

        Order matters: the Team must exist before its paths can be assigned, its
        work configuration must be set before its Board is usable, and the Board
        must exist before its columns can be reconciled.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Application
        Application declaration.

    .PARAMETER BoardColumns
        Board column template.

    .PARAMETER ProjectContext
        Shared project context.

    .PARAMETER ReceiptPath
        Where to write the incremental receipt.

    .PARAMETER AllowCreate
        Allow creating the Team. False for reconcile.

    .EXAMPLE
        Invoke-TeamProvisioningApply -Context $context -Project $project -Application $application `
            -BoardColumns $boardColumns -ProjectContext $projectContext -ReceiptPath $receiptPath

    .OUTPUTS
        The completed operations.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $Application,
        [Parameter(Mandatory)] [object] $BoardColumns,
        [Parameter(Mandatory)] [object] $ProjectContext,
        [Parameter(Mandatory)] [string] $ReceiptPath,
        [bool] $AllowCreate = $true
    )

    $teamName = "$($Application.team.name)"
    $completed = New-Object System.Collections.ArrayList

    function Complete-Step {
        param([string] $Resource, [string] $Name, [string] $Action, [string] $Detail)

        $completed.Add([pscustomobject]@{
            resource = $Resource
            name     = $Name
            action   = $Action
            detail   = $Detail
        }) | Out-Null

        Save-AdoAsCodeReceipt -Path $ReceiptPath -Target "$($Application.key)" -Status 'in_progress' `
            -CompletedOperations @($completed.ToArray())
        Write-ModuleLog "$Action $Resource '$Name': $Detail"
    }

    try {
        # --- Team ---------------------------------------------------------
        $team = Get-AdoTeam -Context $Context -Project $Project -Name $teamName
        if ($null -eq $team) {
            if (-not $AllowCreate) {
                throw "Team '$teamName' does not exist and reconcile is not allowed to create it."
            }
            $description = ''
            if ($Application.team.PSObject.Properties.Name -contains 'description') { $description = "$($Application.team.description)" }
            $team = New-AdoTeam -Context $Context -Project $Project -Name $teamName -Description $description
            Complete-Step -Resource 'Team' -Name $teamName -Action 'create' -Detail 'Created.'
        }

        # --- Classification paths -----------------------------------------
        foreach ($path in (Get-DeclaredPathSet -PathSet $Application.areaPaths)) {
            if (Get-AdoClassificationNode -Context $Context -StructureGroup Areas -RelativePath $path) { continue }
            Initialize-AdoClassificationPath -Context $Context -StructureGroup Areas -RelativePath $path | Out-Null
            Complete-Step -Resource 'Area Path' -Name $path -Action 'create' -Detail 'Created.'
        }

        if ($Application.PSObject.Properties.Name -contains 'iterationPaths') {
            foreach ($path in (Get-DeclaredPathSet -PathSet $Application.iterationPaths)) {
                $node = Get-AdoClassificationNode -Context $Context -StructureGroup Iterations -RelativePath $path
                if ($null -eq $node) {
                    $node = Initialize-AdoClassificationPath -Context $Context -StructureGroup Iterations -RelativePath $path
                    Complete-Step -Resource 'Iteration Path' -Name $path -Action 'create' -Detail 'Created.'
                }

                # Creating the node and subscribing the Team to it are separate
                # operations. A node that exists but is not subscribed does not
                # appear in the Team's sprint list, which reads as "nothing happened".
                $subscribed = @(Get-AdoTeamIteration -Context $Context -TeamName $teamName |
                    Where-Object { "$($_.path)" -eq "$($Project.name)\$path" -or "$($_.name)" -eq (Split-Path -Leaf $path) })
                if ($subscribed.Count -eq 0 -and $node -and $node.PSObject.Properties.Name -contains 'identifier') {
                    Add-AdoTeamIteration -Context $Context -TeamName $teamName -IterationId "$($node.identifier)" | Out-Null
                    Complete-Step -Resource 'Team iteration' -Name $path -Action 'add' -Detail 'Subscribed the Team to the iteration.'
                }
            }
        }

        # --- Team work configuration --------------------------------------
        $defaultAreaPath = "$($Project.name)\$(Get-DeclaredPath -Path "$($Application.areaPaths.default)")"
        $workingDays = @('monday', 'tuesday', 'wednesday', 'thursday', 'friday')
        if ($ProjectContext.defaults.PSObject.Properties.Name -contains 'workingDays') {
            $workingDays = @($ProjectContext.defaults.workingDays)
        }

        # A Team created moments ago is not immediately queryable for work settings.
        # Two short attempts beat either failing the run or sleeping unconditionally.
        $configuration = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $configuration = Initialize-AdoTeamWorkConfiguration -Context $Context -TeamName $teamName `
                    -AreaPath $defaultAreaPath `
                    -TemplateTeamName "$($ProjectContext.defaults.boardTemplateTeam)" `
                    -WorkingDays $workingDays `
                    -DefaultIterationMacro "$($ProjectContext.defaults.defaultIterationMacro)"
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Write-Verbose "Team work configuration not ready yet (attempt $attempt): $($_.Exception.Message)"
                Start-Sleep -Seconds 3
            }
        }

        if ($configuration.AreaPathCreated) { Complete-Step -Resource 'Area Path' -Name $defaultAreaPath -Action 'create' -Detail 'Created for the team field.' }
        if ($configuration.BacklogIterationSet) { Complete-Step -Resource 'Team work configuration' -Name $teamName -Action 'set' -Detail 'Backlog iteration copied from the template Team.' }
        if ($configuration.TeamFieldSet) { Complete-Step -Resource 'Team work configuration' -Name $teamName -Action 'set' -Detail "Default Area Path set to '$defaultAreaPath'." }

        # --- Team administrator -------------------------------------------
        if ("$($ProjectContext.defaults.teamAdministratorMode)" -eq 'authenticatedUser') {
            $authenticated = (Get-AdoAuthenticatedUser -Context $Context).authenticatedUser
            Add-AdoTeamMember -Context $Context -TeamId "$($team.id)" -UserId "$($authenticated.id)"
            Set-AdoTeamAdministrator -Context $Context -TeamId "$($team.id)" -UserId "$($authenticated.id)"
            Complete-Step -Resource 'Team administrator' -Name $teamName -Action 'authorize' -Detail 'The identity behind the Personal Access Token is now a Team administrator.'
        }

        # --- Members -------------------------------------------------------
        if ($Application.PSObject.Properties.Name -contains 'membersEnv') {
            foreach ($member in @(Get-AdoAsCodeMemberList -VariableName "$($Application.membersEnv)" -AllowEmpty)) {
                $identity = Get-AdoIdentity -Context $Context -Identity $member
                Add-AdoTeamMember -Context $Context -TeamId "$($team.id)" -UserId "$($identity.id)"
                Complete-Step -Resource 'Team member' -Name $member -Action 'add' -Detail 'Added to the Team.'
            }
        }

        # --- Board columns -------------------------------------------------
        $reconciled = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $reconciled = Sync-AdoBoardColumn -Context $Context -TeamName $teamName `
                    -BoardName "$($Application.board.name)" -DesiredColumns $BoardColumns.columns
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Write-Verbose "Board not ready yet (attempt $attempt): $($_.Exception.Message)"
                Start-Sleep -Seconds 3
            }
        }

        if ($reconciled.changed) {
            Complete-Step -Resource 'Board column' -Name "$($Application.board.name)" -Action 'reconcile' `
                -Detail "Reconciled. Changes: $($reconciled.reasons -join '; ')"
        }

        Save-AdoAsCodeReceipt -Path $ReceiptPath -Target "$($Application.key)" -Status 'completed' `
            -CompletedOperations @($completed.ToArray()) `
            -Message "Applied $($completed.Count) operation(s)."
    }
    catch {
        Save-AdoAsCodeReceipt -Path $ReceiptPath -Target "$($Application.key)" -Status 'failed' `
            -CompletedOperations @($completed.ToArray()) `
            -Message "$($_.Exception.Message)"
        throw
    }

    return @($completed.ToArray())
}

function New-TeamProvisioningRenamePlan {
    <#
    .SYNOPSIS
        Builds the plan for renaming a Team and its Area Path.

    .DESCRIPTION
        Renaming the Team is cheap and reversible. Renaming the Area Path is not:
        Azure DevOps rewrites System.AreaPath on every Work Item below the node, and
        renaming back does not undo the revision history. The plan therefore marks
        the Area Path rename as a warning even when it will succeed, so the reviewer
        reads that sentence before approving.

        The nodes are compared by id, not by name, because Azure DevOps resolves an
        Area Path case insensitively: a lookup for the new name succeeds against the
        old node when the only difference is capitalisation, and the rename would be
        skipped as "already done".

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Application
        Application declaration carrying the target names.

    .PARAMETER PreviousTeamName
        Current Team name.

    .EXAMPLE
        New-TeamProvisioningRenamePlan -Context $context -Project $project -Application $application -PreviousTeamName 'APP_OLD_Team'

    .OUTPUTS
        A plan object from New-Plan.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $Application,
        [Parameter(Mandatory)] [string] $PreviousTeamName
    )

    $plan = New-Plan -Command 'rename' -Target "$($Application.key)"
    $targetTeamName = "$($Application.team.name)"

    if ($PreviousTeamName -ceq $targetTeamName) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $targetTeamName `
            -Action 'skip' -Status 'ok' -Reason 'The previous and target names are identical.')
        return $plan
    }

    $previousTeam = Get-AdoTeam -Context $Context -Project $Project -Name $PreviousTeamName
    $targetTeam = Get-AdoTeam -Context $Context -Project $Project -Name $targetTeamName

    if ($null -eq $previousTeam -and $null -ne $targetTeam) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $targetTeamName `
            -Action 'exists' -Status 'ok' -Reason 'The rename has already been applied.')
    }
    elseif ($null -eq $previousTeam) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $PreviousTeamName `
            -Action 'resolve' -Status 'blocked' -Reason 'Neither the previous nor the target Team exists. Check -PreviousTeamName.')
    }
    elseif ($null -ne $targetTeam) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $targetTeamName `
            -Action 'resolve' -Status 'blocked' `
            -Reason "Both '$PreviousTeamName' and '$targetTeamName' exist. Merging two Teams is not something an automation should decide.")
    }
    else {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $targetTeamName `
            -Action 'rename' -Status 'pending' -Reason "Renamed from '$PreviousTeamName'. The Team keeps its id, members and Board.")
    }

    $previousAreaPath = Get-DeclaredPath -Path $PreviousTeamName
    $targetAreaPath = Get-DeclaredPath -Path "$($Application.areaPaths.default)"
    $previousNode = Get-AdoClassificationNode -Context $Context -StructureGroup Areas -RelativePath $previousAreaPath
    $targetNode = Get-AdoClassificationNode -Context $Context -StructureGroup Areas -RelativePath $targetAreaPath

    if ($null -eq $previousNode) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Area Path' -Name $targetAreaPath `
            -Action 'skip' -Status 'ok' -Reason "No Area Path named '$previousAreaPath' exists, so there is nothing to rename.")
    }
    elseif ($null -ne $targetNode -and "$($targetNode.id)" -ne "$($previousNode.id)") {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Area Path' -Name $targetAreaPath `
            -Action 'resolve' -Status 'blocked' `
            -Reason "Both '$previousAreaPath' and '$targetAreaPath' exist as separate nodes. Move or merge the Work Items by hand first.")
    }
    elseif ($null -ne $targetNode -and "$($targetNode.id)" -eq "$($previousNode.id)") {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Area Path' -Name $targetAreaPath `
            -Action 'rename' -Status 'warning' `
            -Reason "The node already resolves under both names because Azure DevOps matches an Area Path case insensitively. The rename will normalise the capitalisation and will rewrite System.AreaPath on every Work Item below it.")
    }
    else {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Area Path' -Name $targetAreaPath `
            -Action 'rename' -Status 'warning' `
            -Reason "Renamed from '$previousAreaPath'. This rewrites System.AreaPath on every Work Item below the node and cannot be undone; queries and dashboards filtering on the old path stop matching.")
    }

    return $plan
}

function New-TeamProvisioningSmokeChecklist {
    <#
    .SYNOPSIS
        Produces the manual verification checklist for after an apply.

    .DESCRIPTION
        Deliberately manual. An automated check that creates a throwaway Work Item
        proves the API works, which was never in doubt; what needs proving is that a
        real member of the Team can see the Board, move a card and attach a file with
        their own permissions. So the automation writes the checklist and a person
        runs it.

    .PARAMETER Application
        Application declaration.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER BoardColumns
        Board column template.

    .EXAMPLE
        New-TeamProvisioningSmokeChecklist -Application $application -Project $project -BoardColumns $boardColumns

    .OUTPUTS
        The checklist items.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Application,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $BoardColumns
    )

    $teamName = "$($Application.team.name)"
    $columnNames = @($BoardColumns.columns | ForEach-Object { "$($_.name)" })

    return @(
        [pscustomobject]@{ step = 1; check = "Project settings > Teams lists '$teamName' with the expected members." }
        [pscustomobject]@{ step = 2; check = "Board '$($Application.board.name)' shows these columns in order: $($columnNames -join ' | '). Columns the automation did not declare are still there." }
        [pscustomobject]@{ step = 3; check = "Create a Work Item of type '$(@($Application.board.workItemTypes)[0])' as a Team member, not as the automation identity." }
        [pscustomobject]@{ step = 4; check = 'Assign it to a Team member and move it across every column.' }
        [pscustomobject]@{ step = 5; check = 'Add a comment and an attachment, to prove the permissions are real and not only visible.' }
        [pscustomobject]@{ step = 6; check = "New Work Items carry Area Path '$($Project.name)\$(Get-DeclaredPath -Path "$($Application.areaPaths.default)")' by default." }
        [pscustomobject]@{ step = 7; check = 'Re-run plan. Every operation should be ok. A pending operation means the apply did not finish, and re-running apply blindly is not the answer - read the plan first.' }
    )
}

# =====================================================================
# Entry point
# =====================================================================

$projectContextPath = if ($ProjectContextPath) { $ProjectContextPath } else { Join-Path $repoRoot 'foundation/config/project-context.json' }
$projectContext = Get-AdoAsCodeConfiguration -Path $projectContextPath

$automationPaths = $projectContext.automations.$moduleName

if (-not $ConfigurationPath) {
    $activePath = Resolve-AdoAsCodePath -Path "$($automationPaths.configuration)" -RootPath $repoRoot
    $templatePath = Resolve-AdoAsCodePath -Path "$($automationPaths.template)" -RootPath $repoRoot
    # The active file is created by renaming the template, and is excluded from
    # version control because it names people. Falling back to the template keeps
    # `validate` useful on a fresh clone.
    $ConfigurationPath = if (Test-Path -LiteralPath $activePath) { $activePath } else { $templatePath }
}
if (-not $BoardColumnsPath) {
    $BoardColumnsPath = Resolve-AdoAsCodePath -Path "$($automationPaths.boardColumns)" -RootPath $repoRoot
}

$configuration = Get-AdoAsCodeConfiguration -Path $ConfigurationPath
$boardColumns = Get-AdoAsCodeConfiguration -Path $BoardColumnsPath

if ($Command -eq 'validate') {
    Write-ModuleLog "Configuration: $ConfigurationPath"
    Write-ModuleLog "Board columns : $BoardColumnsPath"

    $problems = @(Test-TeamProvisioningConfiguration -Configuration $configuration -BoardColumns $boardColumns)
    if ($problems.Count -gt 0) {
        $detail = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "The configuration is not coherent:$([Environment]::NewLine)$detail"
    }

    Write-ModuleLog "Valid. $(@($configuration.applications).Count) application(s) declared, $(@($boardColumns.columns).Count) Board column(s)."
    Write-ModuleLog 'No network call was made and no credential was read.'
    return
}

# Every remaining command talks to Azure DevOps.
$environmentFiles = @($EnvFile)
$membersFile = Join-Path $PSScriptRoot 'config/members.env'
if (Test-Path -LiteralPath $membersFile) { $environmentFiles += $membersFile }
# One application per run, checked before the environment file is read and before any
# network call. The check existed and covered the same commands, but ran after the
# connection was established - so a run with no key reported a missing .env rather than
# the missing argument, and had already read the token by the time it complained.
if ($Command -in $script:ApplicationScopedCommands -and -not $ApplicationKey) {
    throw "-ApplicationKey is required by '$Command'. It is what keeps one run to one application. Declared keys: $(@($configuration.applications | ForEach-Object { "$($_.key)" }) -join ', ')."
}

Import-AdoAsCodeEnvironment -Path $environmentFiles | Out-Null

$context = Get-AdoContext -ProjectContext $projectContext
$project = Get-AdoProject -Context $context
Write-ModuleLog "Connected to '$($context.OrganizationUrl)' project '$($project.name)'."

if ($Command -eq 'inventory') {
    $inventory = New-Object System.Collections.ArrayList
    $keys = if ($ApplicationKey) { @($ApplicationKey) } else { @($configuration.applications | ForEach-Object { "$($_.key)" }) }

    foreach ($key in $keys) {
        $application = Get-TeamProvisioningApplication -Configuration $configuration -Key $key
        $live = Get-TeamProvisioningInventory -Context $context -Project $project -Application $application
        $inventory.Add([pscustomobject]@{
            application    = $key
            teamName       = $live.teamName
            teamExists     = $null -ne $live.team
            memberCount    = @($live.members).Count
            boardExists    = $null -ne $live.board
            boardColumns   = @($live.boardColumns | ForEach-Object { "$($_.name)" })
            areaPaths      = @($live.areaNodes.Keys | Where-Object { $null -ne $live.areaNodes[$_] })
            iterationPaths = @($live.iterationNodes.Keys | Where-Object { $null -ne $live.iterationNodes[$_] })
        }) | Out-Null
    }

    $plan = New-Plan -Command 'inventory' -Target ($keys -join ',')
    foreach ($item in $inventory) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name $item.teamName `
            -Action 'validate' -Status 'ok' `
            -Reason "exists=$($item.teamExists); members=$($item.memberCount); board=$($item.boardExists); columns=$(@($item.boardColumns).Count); areaPaths=$(@($item.areaPaths).Count); iterationPaths=$(@($item.iterationPaths).Count)")
    }

    if (-not $ReportPath) { $ReportPath = Join-Path $repoRoot "artifacts/reports/$moduleName-inventory.json" }
    Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Detail ([pscustomobject]@{ applications = @($inventory.ToArray()) }) | Out-Null
    Write-PlanSummary -Plan $plan
    Write-ModuleLog "Report: $ReportPath"
    return $plan
}

$application = Get-TeamProvisioningApplication -Configuration $configuration -Key $ApplicationKey

if (-not $ReportPath) {
    $ReportPath = Join-Path $repoRoot "artifacts/reports/$moduleName-$Command-$ApplicationKey.json"
}

if ($Command -eq 'rename') {
    $plan = New-TeamProvisioningRenamePlan -Context $context -Project $project -Application $application -PreviousTeamName $PreviousTeamName
    Write-PlanSummary -Plan $plan

    if (-not ($ConfirmApply -and $ConfirmRename)) {
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
        Write-ModuleLog 'Simulation only: rename requires both -ConfirmApply and -ConfirmRename. Nothing was modified.'
        Write-ModuleLog "Report: $ReportPath"
        return $plan
    }

    Assert-PlanApplicable -Plan $plan

    $receiptPath = Get-AdoAsCodeReceiptPath -ReportPath $ReportPath
    $completed = New-Object System.Collections.ArrayList

    foreach ($operation in @($plan.operations | Where-Object { $_.action -eq 'rename' })) {
        if ($operation.resource -eq 'Team') {
            $previousTeam = Get-AdoTeam -Context $context -Project $project -Name $PreviousTeamName
            Rename-AdoTeam -Context $context -Project $project -TeamId "$($previousTeam.id)" -NewName "$($application.team.name)" | Out-Null
            $completed.Add([pscustomobject]@{ resource = 'Team'; name = "$($application.team.name)"; action = 'rename'; detail = "Renamed from '$PreviousTeamName'." }) | Out-Null
        }
        else {
            Rename-AdoAreaPath -Context $context -RelativePath (Get-DeclaredPath -Path $PreviousTeamName) `
                -NewName (Split-Path -Leaf (Get-DeclaredPath -Path "$($application.areaPaths.default)")) -Confirm:$false | Out-Null
            $completed.Add([pscustomobject]@{ resource = 'Area Path'; name = $operation.name; action = 'rename'; detail = 'Renamed. System.AreaPath was rewritten on every Work Item below the node.' }) | Out-Null
        }

        Save-AdoAsCodeReceipt -Path $receiptPath -Target $ApplicationKey -Status 'in_progress' -CompletedOperations @($completed.ToArray())
    }

    Save-AdoAsCodeReceipt -Path $receiptPath -Target $ApplicationKey -Status 'completed' `
        -CompletedOperations @($completed.ToArray()) -Message "Renamed $($completed.Count) resource(s)."
    Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
    Write-ModuleLog "Rename complete. Report: $ReportPath"
    return $plan
}

$inventory = Get-TeamProvisioningInventory -Context $context -Project $project -Application $application
$plan = New-TeamProvisioningPlan -Context $context -Project $project -Application $application `
    -BoardColumns $boardColumns -Inventory $inventory -ProjectContext $projectContext -CommandName $Command

Write-PlanSummary -Plan $plan

switch ($Command) {
    'plan' {
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
        Write-ModuleLog "Report: $ReportPath"
    }

    'smoke' {
        $checklist = New-TeamProvisioningSmokeChecklist -Application $application -Project $project -BoardColumns $boardColumns
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName `
            -Detail ([pscustomobject]@{ manualVerification = @($checklist) }) | Out-Null

        Write-ModuleLog 'Manual verification checklist:'
        foreach ($item in $checklist) { Write-ModuleLog "  $($item.step). $($item.check)" }
        Write-ModuleLog "Report: $ReportPath"
    }

    default {
        # apply and reconcile
        if (-not $ConfirmApply) {
            Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
            Write-ModuleLog "Simulation only: '$Command' requires -ConfirmApply. Nothing was modified."
            Write-ModuleLog "Report: $ReportPath"
            return $plan
        }

        Assert-PlanApplicable -Plan $plan

        $receiptPath = Get-AdoAsCodeReceiptPath -ReportPath $ReportPath
        $completed = @(Invoke-TeamProvisioningApply -Context $context -Project $project -Application $application `
            -BoardColumns $boardColumns -ProjectContext $projectContext -ReceiptPath $receiptPath `
            -AllowCreate ($Command -eq 'apply'))

        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName `
            -Detail ([pscustomobject]@{ appliedOperations = $completed }) | Out-Null

        Write-ModuleLog "$Command complete: $($completed.Count) operation(s) written."
        Write-ModuleLog "Report: $ReportPath"
        Write-ModuleLog "Receipt: $receiptPath"
        Write-ModuleLog "Next: run 'plan' again. Every operation should be ok, which is how this repository defines a finished change."
    }
}

return $plan
