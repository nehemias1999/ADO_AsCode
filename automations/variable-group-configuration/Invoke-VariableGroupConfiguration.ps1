<#
.SYNOPSIS
    Creates and fills Azure DevOps Variable Groups from a declared scope and a CSV
    of values, without ever destroying a secret.

.DESCRIPTION
    Configuration as data. The scope file says which groups exist and which keys they
    may contain; a CSV says what the non-secret values are. Neither file carries a
    secret: a key declared as secret is created at the configuration sentinel and
    completed by whoever holds the credential.

    Three rules do most of the work here, and each one exists because the API makes
    the naive version destructive.

    1. The only value this automation overwrites is the sentinel. A key already
       holding something else carries somebody's decision.
    2. A write to a group that contains secrets re-posts every secret in the same
       request, because a Variable Group PUT treats an omitted value as an empty
       string. If a secret cannot be resolved, the whole write is blocked rather
       than attempted.
    3. A key listed as forbidden for an environment is refused. A pipeline agent
       exposes every variable of every linked group as a process environment
       variable, so a stray key can switch on behaviour that no YAML mentions.

    Command ladder:

      validate   Offline. Scope against its schema, CSV against the scope.
      inventory  Read-only snapshot of the groups in scope.
      plan       Classifies every key of every group in scope.
      smoke      Plan plus the manual verification checklist.
      apply      Creates groups and writes values. Requires -ConfirmApply.

.PARAMETER Command
    Operation to run.

.PARAMETER ApplicationKey
    Restrict the run to one application. Omit to cover the whole scope.

.PARAMETER Environment
    Restrict the run to one environment.

.PARAMETER EnvFile
    Environment files to load, comma or list separated.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ScopePath
    Override for the scope configuration.

.PARAMETER CsvPath
    Override for the values CSV.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/.

.PARAMETER ConfirmApply
    Required by apply. Without it, apply is a pure simulation.

.PARAMETER AllowUnqualifiedSecretName
    Accepts the bare <NAME> as the source of a secret, instead of requiring
    <NAME>_<ENVIRONMENT>.

    A Variable Group PUT sends the whole object, so a secret the automation cannot
    resolve would be stored as an empty string - which is why an unresolved secret
    blocks the write instead. The environment qualifier exists because the group name
    carries the environment and the secret's own name does not, and a live secret
    value cannot be read back to compare against: with a bare name, the DEV value of
    APP_SERVER_PASSWORD is written over the PROD credential, the API reports success,
    and nothing afterwards can detect it.

    So this is opt-in, and it is only correct when one credential is genuinely shared
    across every environment. Leaving a qualified variable empty and seeing the group
    reported blocked is the safe outcome, not a problem to switch off.

.EXAMPLE
    .\Invoke-VariableGroupConfiguration.ps1 -Command validate

    Checks the scope and the CSV offline, with no credentials.

.EXAMPLE
    .\Invoke-VariableGroupConfiguration.ps1 -Command plan -ApplicationKey APP_ALPHA -Environment DEV

    Shows what would change for one group.

.EXAMPLE
    .\Invoke-VariableGroupConfiguration.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply

    Applies the approved plan for one group.

.OUTPUTS
    The plan object.
#>
[CmdletBinding()]
param(
    [ValidateSet('validate', 'inventory', 'plan', 'smoke', 'apply')]
    [string] $Command = 'plan',

    [string] $ApplicationKey,
    [string] $Environment,

    [string[]] $EnvFile = @('.env'),

    [string] $ProjectContextPath,
    [string] $ScopePath,
    [string] $CsvPath,
    [string] $ReportPath,

    [switch] $ConfirmApply,

    # A secret is resolved from <NAME>_<ENVIRONMENT>. This also accepts the bare
    # <NAME>, for a credential deliberately shared across environments. Opt-in,
    # because the bare name is what allowed a DEV value to be written over PROD.
    [switch] $AllowUnqualifiedSecretName
)

Set-StrictMode -Version Latest

# Commands that write. Naming them once keeps the -ApplicationKey requirement and the
# confirmation gate from drifting apart as verbs are added.
$script:WritingCommands = @('apply')
$ErrorActionPreference = 'Stop'

$moduleName = 'variable-group-configuration'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path

. (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

$requiredCsvColumn = @('application', 'environment', 'variable', 'value')

function Write-ModuleLog {
    <#
    .SYNOPSIS
        Writes a prefixed progress line to the information stream.

    .PARAMETER Message
        Text to write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)

    Write-Information "[$moduleName] $Message" -InformationAction Continue
}

function Get-GroupName {
    <#
    .SYNOPSIS
        Derives a Variable Group name from the scope pattern.

    .DESCRIPTION
        One derivation, no per-environment overrides. An override is how a
        pipeline's reference and a group's actual name stop matching, and that
        failure surfaces as a variable that is silently empty at run time.

    .PARAMETER Pattern
        Name pattern containing {application} and {environment}.

    .PARAMETER Application
        Application key.

    .PARAMETER Environment
        Environment suffix.

    .EXAMPLE
        Get-GroupName -Pattern 'Credentials_{application}_{environment}' -Application 'APP_ALPHA' -Environment 'DEV'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Application,
        [Parameter(Mandatory)] [string] $Environment
    )

    return $Pattern.Replace('{application}', $Application).Replace('{environment}', $Environment)
}

function Get-DeclaredKey {
    <#
    .SYNOPSIS
        Returns the declaration of one key, or $null when it is not declared.

    .PARAMETER Scope
        Parsed scope configuration.

    .PARAMETER Name
        Variable name.

    .EXAMPLE
        Get-DeclaredKey -Scope $scope -Name 'DEPLOY_PATH'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Scope,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Scope.declaredKeys | Where-Object { "$($_.name)" -ceq $Name }) | Select-Object -First 1
}

function Get-ForbiddenKey {
    <#
    .SYNOPSIS
        Returns the keys forbidden in an environment.

    .PARAMETER Scope
        Parsed scope configuration.

    .PARAMETER Environment
        Environment suffix.

    .EXAMPLE
        Get-ForbiddenKey -Scope $scope -Environment 'DEV'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [object] $Scope,
        [Parameter(Mandatory)] [string] $Environment
    )

    if ($Scope.PSObject.Properties.Name -notcontains 'forbiddenKeysByEnvironment') { return @() }
    $map = $Scope.forbiddenKeysByEnvironment
    if ($null -eq $map -or $map.PSObject.Properties.Name -notcontains $Environment) { return @() }
    return @($map.$Environment)
}

function Get-CsvValueRow {
    <#
    .SYNOPSIS
        Reads and validates the values CSV against the scope.

    .DESCRIPTION
        Strict on purpose. The CSV is the one place a human types free text into
        this automation, so every plausible mistake is caught here rather than
        becoming a wrong value in production:

        * a missing or misspelled column,
        * an application or environment outside the declared scope,
        * a variable that is not a declared key,
        * a variable declared as secret - a secret value must never travel through
          a CSV, and rejecting the row is the only way to keep that true,
        * a key forbidden in that environment,
        * the same application/environment/variable declared twice with different
          values, which is a merge accident and has no correct resolution.

        Pure function over text, so `validate` runs it with no network access.

    .PARAMETER Path
        CSV path.

    .PARAMETER Scope
        Parsed scope configuration.

    .EXAMPLE
        Get-CsvValueRow -Path $csvPath -Scope $scope

    .OUTPUTS
        PSCustomObject with rows and errors.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Scope
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $Path)) {
        $errors.Add("Values file not found: $Path. Rename the .example.csv template to create it.")
        return [pscustomobject]@{ rows = @(); errors = @($errors.ToArray()) }
    }

    $csv = @(Import-Csv -LiteralPath $Path)
    if ($csv.Count -eq 0) {
        return [pscustomobject]@{ rows = @(); errors = @() }
    }

    $columns = @($csv[0].PSObject.Properties.Name)
    $missingColumns = @($requiredCsvColumn | Where-Object { $columns -notcontains $_ })
    if ($missingColumns.Count -gt 0) {
        $errors.Add("The values file is missing column(s): $($missingColumns -join ', '). Expected header: $($requiredCsvColumn -join ',').")
        return [pscustomobject]@{ rows = @(); errors = @($errors.ToArray()) }
    }

    $applications = @($Scope.applications)
    $environments = @($Scope.environments)
    $seen = @{}
    $lineNumber = 1   # the header

    foreach ($record in $csv) {
        $lineNumber++
        $application = "$($record.application)".Trim()
        $environment = "$($record.environment)".Trim()
        $variable = "$($record.variable)".Trim()
        $value = "$($record.value)"

        if ($applications -notcontains $application) {
            $errors.Add("line ${lineNumber}: application '$application' is not in scope")
            continue
        }
        if ($environments -notcontains $environment) {
            $errors.Add("line ${lineNumber}: environment '$environment' is not in scope")
            continue
        }

        $declared = Get-DeclaredKey -Scope $Scope -Name $variable
        if ($null -eq $declared) {
            $errors.Add("line ${lineNumber}: '$variable' is not a declared key")
            continue
        }
        if ([bool]$declared.isSecret) {
            $errors.Add("line ${lineNumber}: '$variable' is declared secret, so its value must not appear in a values file. Remove the row; the key is created at the sentinel and completed by whoever holds the credential.")
            continue
        }
        if ((Get-ForbiddenKey -Scope $Scope -Environment $environment) -contains $variable) {
            $errors.Add("line ${lineNumber}: '$variable' is forbidden in $environment. Writing it would switch on behaviour that no pipeline definition mentions.")
            continue
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            $errors.Add("line ${lineNumber}: '$variable' has no value. An empty value is not the same as 'leave it alone' - remove the row instead.")
            continue
        }

        $identity = "$application|$environment|$variable"
        if ($seen.ContainsKey($identity)) {
            if ($seen[$identity] -cne $value) {
                $errors.Add("line ${lineNumber}: '$variable' for $application/$environment is declared twice with different values ('$($seen[$identity])' and '$value')")
            }
            else {
                $errors.Add("line ${lineNumber}: '$variable' for $application/$environment is declared twice")
            }
            continue
        }
        $seen[$identity] = $value

        $rows.Add([pscustomobject]@{
            application = $application
            environment = $environment
            variable    = $variable
            value       = $value
            line        = $lineNumber
        }) | Out-Null
    }

    return [pscustomobject]@{
        rows   = @($rows.ToArray())
        errors = @($errors.ToArray())
    }
}

function Get-VariableGroupWriteBlock {
    <#
    .SYNOPSIS
        Returns the reason a group cannot be written, or $null when it can.

    .DESCRIPTION
        The most useful thing this automation reports, and the least obvious.

        A Variable Group PUT sends the whole object, and Azure DevOps never returns
        a stored secret on a GET. To change one non-secret key in a group that also
        holds a secret, the writer has to re-post that secret with a value it knows -
        so the group becomes unwritable by automation the moment somebody completes
        a secret in the portal and no matching environment variable exists locally.

        That is a real constraint, not a bug to work around, and the honest response
        is to say so in the plan instead of attempting a write that would blank a
        credential.

        Pure function.

    .PARAMETER Group
        Live group object from Get-AdoVariableGroup -Id.

    .PARAMETER SecretSource
        Resolved secret values, from Get-AdoVariableGroupSecretSource.

    .EXAMPLE
        Get-VariableGroupWriteBlock -Group $group -SecretSource $sources
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Group,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $SecretSource
    )

    $unresolved = New-Object System.Collections.Generic.List[string]
    foreach ($property in @($Group.variables.PSObject.Properties)) {
        if (-not [bool]$property.Value.isSecret) { continue }
        if (-not $SecretSource.Contains("$($property.Name)")) { $unresolved.Add("$($property.Name)") }
    }

    if ($unresolved.Count -eq 0) { return $null }

    return "The group holds secret(s) with no known value in this session: $($unresolved -join ', '). Any write sends the complete object, and an omitted secret is stored as an empty string, so writing would blank them. Supply the value in your environment file under the same name, or make the change in the portal."
}

function New-VariableGroupPlan {
    <#
    .SYNOPSIS
        Builds the plan for every group in scope.

    .DESCRIPTION
        One operation per group plus one per key, so the plan reads as the intended
        shape of the configuration rather than only its delta. A key already holding
        a value that differs from the CSV is reported as `protected`, not as an
        update: this automation fills blanks, it does not overrule decisions.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Scope
        Parsed scope configuration.

    .PARAMETER Row
        Validated CSV rows.

    .PARAMETER Target
        The application/environment pairs to plan.

    .PARAMETER Sentinel
        The configuration sentinel.

    .PARAMETER AllowUnqualifiedSecretName
        Resolve a secret from its bare name as well as <NAME>_<ENVIRONMENT>. Needed only
        when one credential is genuinely shared across environments, and opt-in because
        the failure mode of the bare name is silent: a DEV value written over PROD.

    .PARAMETER CommandName
        Command being planned.

    .EXAMPLE
        New-VariableGroupPlan -Context $context -Scope $scope -Row $rows -Target $targets -Sentinel $sentinel -CommandName plan

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
        [Parameter(Mandatory)] [object] $Scope,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Row,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Target,
        [Parameter(Mandatory)] [string] $Sentinel,
        [Parameter(Mandatory)] [string] $CommandName,
        [switch] $AllowUnqualifiedSecretName
    )

    $plan = New-Plan -Command $CommandName -Target (@($Target | ForEach-Object { "$($_.application)/$($_.environment)" }) -join ',')
    $liveGroups = @(Get-AdoVariableGroup -Context $Context)

    foreach ($target in $Target) {
        $groupName = Get-GroupName -Pattern "$($Scope.groupNamePattern)" -Application $target.application -Environment $target.environment
        $forbidden = @(Get-ForbiddenKey -Scope $Scope -Environment $target.environment)
        $declaredValues = @{}
        foreach ($row in @($Row | Where-Object { $_.application -eq $target.application -and $_.environment -eq $target.environment })) {
            $declaredValues[$row.variable] = $row.value
        }

        $summary = @($liveGroups | Where-Object { "$($_.name)" -eq $groupName })

        if ($summary.Count -eq 0) {
            $secretKeys = @($Scope.declaredKeys | Where-Object { [bool]$_.isSecret } | ForEach-Object { "$($_.name)" })
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable Group' -Name $groupName `
                -Action 'create' -Status 'pending' `
                -Reason "Does not exist. It will be created with every declared key; secret key(s) $(if ($secretKeys.Count -gt 0) { $secretKeys -join ', ' } else { 'none' }) start at '$Sentinel' for the owner to complete.")

            foreach ($declared in @($Scope.declaredKeys)) {
                $keyName = "$($declared.name)"
                if ($forbidden -contains $keyName) { continue }

                if ([bool]$declared.isSecret) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'manual' -Status 'warning' `
                        -Reason "Secret. Created at '$Sentinel'; the value has to be completed in the portal by whoever holds it.")
                }
                elseif ($declaredValues.ContainsKey($keyName)) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'set' -Status 'pending' -Reason "Created with the value from the values file.")
                }
                else {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'create' -Status 'pending' -Reason "Declared but with no value in the values file. Created at '$Sentinel'.")
                }
            }
            continue
        }

        if ($summary.Count -gt 1) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable Group' -Name $groupName `
                -Action 'resolve' -Status 'blocked' -Reason "$($summary.Count) groups share this name. Resolve the duplicate before continuing.")
            continue
        }

        $group = Get-AdoVariableGroup -Context $Context -Id ([int]$summary[0].id)
        $secretSource = Get-AdoVariableGroupSecretSource -VariableGroup $group `
            -Environment $target.environment -AllowUnqualifiedName:$AllowUnqualifiedSecretName
        $writeBlock = Get-VariableGroupWriteBlock -Group $group -SecretSource $secretSource
        $liveNames = @($group.variables.PSObject.Properties.Name)

        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable Group' -Name $groupName `
            -Action 'exists' -Status 'ok' -Reason "Exists with $($liveNames.Count) variable(s), $(@($group.variables.PSObject.Properties | Where-Object { [bool]$_.Value.isSecret }).Count) of them secret.")

        # A key that must not exist in this environment. Reported before anything
        # else, because its presence changes what the pipeline does at run time.
        foreach ($forbiddenKey in $forbidden) {
            if ($liveNames -notcontains $forbiddenKey) {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Forbidden variable' -Name "$groupName/$forbiddenKey" `
                    -Action 'validate' -Status 'ok' -Reason "Correctly absent in $($target.environment).")
                continue
            }
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Forbidden variable' -Name "$groupName/$forbiddenKey" `
                -Action 'resolve' -Status 'blocked' `
                -Reason "Present in $($target.environment) but declared forbidden there. The agent exposes it as a process environment variable, so it can switch on behaviour that no pipeline definition mentions. Remove it in the portal; this automation does not delete.")
        }

        foreach ($declared in @($Scope.declaredKeys)) {
            $keyName = "$($declared.name)"
            if ($forbidden -contains $keyName) { continue }

            $exists = $liveNames -contains $keyName
            $liveValue = if ($exists) { "$($group.variables.$keyName.value)" } else { $null }

            if ([bool]$declared.isSecret) {
                if (-not $exists) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'manual' -Status 'warning' -Reason "Secret and absent. It will be added at '$Sentinel' for the owner to complete.")
                }
                elseif ($secretSource.Contains($keyName)) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'exists' -Status 'protected' -Reason 'Secret, and a value with the same name is available locally, so a write to this group can re-post it. The stored value is never read or replaced.')
                }
                else {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'exists' -Status 'protected' -Reason 'Secret, with no local value. Its stored value cannot be read, so it is left exactly as it is.')
                }
                continue
            }

            if (-not $declaredValues.ContainsKey($keyName)) {
                if ($exists) {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'exists' -Status 'ok' -Reason 'Present, and the values file says nothing about it.')
                }
                else {
                    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                        -Action 'create' -Status 'pending' -Reason "Declared but absent, and the values file gives no value. It will be added at '$Sentinel'.")
                }
                continue
            }

            $desired = "$($declaredValues[$keyName])"

            if (-not $exists) {
                $status = if ($writeBlock) { 'blocked' } else { 'pending' }
                $reason = if ($writeBlock) { $writeBlock } else { "Absent. It will be created with '$desired'." }
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                    -Action 'set' -Status $status -Reason $reason)
            }
            elseif ($liveValue -ceq $desired) {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                    -Action 'exists' -Status 'ok' -Reason 'Already holds the declared value.')
            }
            elseif ($liveValue -ceq $Sentinel) {
                $status = if ($writeBlock) { 'blocked' } else { 'pending' }
                $reason = if ($writeBlock) { $writeBlock } else { "Holds '$Sentinel', so it is filled in with '$desired'." }
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                    -Action 'set' -Status $status -Reason $reason)
            }
            else {
                Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name "$groupName/$keyName" `
                    -Action 'exists' -Status 'protected' `
                    -Reason "Holds '$liveValue' while the values file declares '$desired'. It is not overwritten: a value that is neither absent nor the sentinel was set by somebody on purpose. Reconcile the values file, or clear the variable to the sentinel to let the automation fill it.")
            }
        }

        # Keys nobody declared. Preserved - this automation never deletes - but
        # reported, because an undeclared variable in a group is configuration that
        # no review ever saw.
        foreach ($liveName in $liveNames) {
            if (@($Scope.declaredKeys | ForEach-Object { "$($_.name)" }) -contains $liveName) { continue }
            if ($forbidden -contains $liveName) { continue }
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Undeclared variable' -Name "$groupName/$liveName" `
                -Action 'skip' -Status 'warning' `
                -Reason 'Present but not declared in the scope. It is preserved, not removed. Either declare it or remove it in the portal, so the scope stays an accurate description of the group.')
        }
    }

    return $plan
}

function Invoke-VariableGroupApply {
    <#
    .SYNOPSIS
        Executes an approved plan against the groups in scope.

    .DESCRIPTION
        Creation and value writing go through different paths for a reason. Creating
        a group is a POST with the full declared key set at the sentinel: nothing can
        be destroyed because nothing exists. Writing values into an existing group is
        a PUT of the whole object, which is why it goes through the secret-preserving
        writer and why that writer refuses rather than guesses.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Scope
        Parsed scope configuration.

    .PARAMETER Row
        Validated CSV rows.

    .PARAMETER Target
        Application/environment pairs to apply.

    .PARAMETER Sentinel
        The configuration sentinel.

    .PARAMETER Provenance
        Provenance block, written into every receipt this function saves so an
        interrupted run still records who was running it and from which commit.

    .PARAMETER ReceiptPath
        Where to write the incremental receipt.

    .PARAMETER AllowUnqualifiedSecretName
        Resolve a secret from its bare name as well as <NAME>_<ENVIRONMENT>. Needed only
        when one credential is genuinely shared across environments, and opt-in because
        the failure mode of the bare name is silent: a DEV value written over PROD.

    .EXAMPLE
        Invoke-VariableGroupApply -Context $context -Project $project -Scope $scope -Row $rows -Target $targets -Sentinel $sentinel -ReceiptPath $receiptPath -Provenance $script:provenance

    .OUTPUTS
        The completed operations.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [object] $Scope,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Row,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Target,
        [Parameter(Mandatory)] [string] $Sentinel,
        [Parameter(Mandatory)] [string] $ReceiptPath,
        [object] $Provenance,
        [switch] $AllowUnqualifiedSecretName
    )

    $completed = New-Object System.Collections.ArrayList
    $targetLabel = (@($Target | ForEach-Object { "$($_.application)/$($_.environment)" }) -join ',')

    try {
        foreach ($target in $Target) {
            $groupName = Get-GroupName -Pattern "$($Scope.groupNamePattern)" -Application $target.application -Environment $target.environment
            $forbidden = @(Get-ForbiddenKey -Scope $Scope -Environment $target.environment)

            $declaredValues = @{}
            foreach ($row in @($Row | Where-Object { $_.application -eq $target.application -and $_.environment -eq $target.environment })) {
                $declaredValues[$row.variable] = $row.value
            }

            $summary = @(Get-AdoVariableGroup -Context $Context | Where-Object { "$($_.name)" -eq $groupName })

            if ($summary.Count -eq 0) {
                $definition = [ordered]@{}
                foreach ($declared in @($Scope.declaredKeys)) {
                    $keyName = "$($declared.name)"
                    if ($forbidden -contains $keyName) { continue }

                    $value = $Sentinel
                    if (-not [bool]$declared.isSecret -and $declaredValues.ContainsKey($keyName)) {
                        $value = "$($declaredValues[$keyName])"
                    }
                    $definition[$keyName] = @{ value = $value; isSecret = [bool]$declared.isSecret }
                }

                $description = "Managed by $moduleName for $($target.application) in $($target.environment)."
                New-AdoVariableGroup -Context $Context -Project $Project -Name $groupName `
                    -Description $description -Variable $definition -Sentinel $Sentinel | Out-Null

                $completed.Add([pscustomobject]@{
                    resource = 'Variable Group'
                    name     = $groupName
                    action   = 'create'
                    detail   = "Created with $($definition.Count) declared key(s)."
                }) | Out-Null
                Save-AdoAsCodeReceipt -Provenance $Provenance -Path $ReceiptPath -Target $targetLabel -Status 'in_progress' -CompletedOperations @($completed.ToArray())
                Write-ModuleLog "created Variable Group '$groupName' with $($definition.Count) key(s)"
                continue
            }

            $group = Get-AdoVariableGroup -Context $Context -Id ([int]$summary[0].id)
            $liveNames = @($group.variables.PSObject.Properties.Name)

            # Only keys that are absent or hold the sentinel. Anything else was set
            # deliberately and is not this automation's to change.
            $writes = @{}
            foreach ($keyName in @($declaredValues.Keys)) {
                if ($forbidden -contains $keyName) { continue }
                $declared = Get-DeclaredKey -Scope $Scope -Name $keyName
                if ($null -eq $declared -or [bool]$declared.isSecret) { continue }

                if ($liveNames -notcontains $keyName) { $writes[$keyName] = "$($declaredValues[$keyName])"; continue }
                if ("$($group.variables.$keyName.value)" -ceq $Sentinel) { $writes[$keyName] = "$($declaredValues[$keyName])" }
            }

            # Declared keys that are missing entirely still have to appear, at the
            # sentinel, so the group is a complete contract a pipeline can rely on.
            foreach ($declared in @($Scope.declaredKeys)) {
                $keyName = "$($declared.name)"
                if ($forbidden -contains $keyName) { continue }
                if ($liveNames -contains $keyName) { continue }
                if ($writes.ContainsKey($keyName)) { continue }
                if ([bool]$declared.isSecret) { continue }   # a secret is never created by a value write
                $writes[$keyName] = $Sentinel
            }

            if ($writes.Count -eq 0) {
                Write-ModuleLog "Variable Group '$groupName': nothing to write."
                continue
            }

            $payload = Set-AdoVariableGroupValue -Context $Context -Project $Project -GroupId ([int]$group.id) `
                -SetValue $writes -Environment $target.environment `
                -AllowUnqualifiedSecretName:$AllowUnqualifiedSecretName
            $completed.Add([pscustomobject]@{
                resource = 'Variable Group'
                name     = $groupName
                action   = 'set'
                detail   = "Wrote $(@($payload.applied).Count) key(s); re-posted $($payload.secretCount) secret(s) in the same request."
            }) | Out-Null
            Save-AdoAsCodeReceipt -Provenance $Provenance -Path $ReceiptPath -Target $targetLabel -Status 'in_progress' -CompletedOperations @($completed.ToArray())
            Write-ModuleLog "Variable Group '$groupName': wrote $(@($payload.applied).Count) key(s)"
        }

        Save-AdoAsCodeReceipt -Provenance $Provenance -Path $ReceiptPath -Target $targetLabel -Status 'completed' `
            -CompletedOperations @($completed.ToArray()) -Message "Applied $($completed.Count) operation(s)."
    }
    catch {
        Save-AdoAsCodeReceipt -Provenance $Provenance -Path $ReceiptPath -Target $targetLabel -Status 'failed' `
            -CompletedOperations @($completed.ToArray()) -Message "$($_.Exception.Message)"
        throw
    }

    return @($completed.ToArray())
}

# =====================================================================
# Entry point
# =====================================================================

$projectContextPath = if ($ProjectContextPath) { $ProjectContextPath } else { Join-Path $repoRoot 'foundation/config/project-context.json' }
$projectContext = Get-AdoAsCodeConfiguration -Path $projectContextPath
$automationPaths = $projectContext.automations.$moduleName
$sentinel = "$($projectContext.defaults.configurationSentinel)"

if (-not $ScopePath) {
    $activeScope = Resolve-AdoAsCodePath -Path "$($automationPaths.configuration)" -RootPath $repoRoot
    $templateScope = Resolve-AdoAsCodePath -Path "$($automationPaths.template)" -RootPath $repoRoot
    $ScopePath = if (Test-Path -LiteralPath $activeScope) { $activeScope } else { $templateScope }
}
if (-not $CsvPath) {
    $activeCsv = Resolve-AdoAsCodePath -Path "$($automationPaths.values)" -RootPath $repoRoot
    $templateCsv = Resolve-AdoAsCodePath -Path "$($automationPaths.valuesTemplate)" -RootPath $repoRoot
    $CsvPath = if (Test-Path -LiteralPath $activeCsv) { $activeCsv } else { $templateCsv }
}

$scope = Get-AdoAsCodeConfiguration -Path $ScopePath
$csv = Get-CsvValueRow -Path $CsvPath -Scope $scope

if ($Command -eq 'validate') {
    Write-ModuleLog "Scope : $ScopePath"
    Write-ModuleLog "Values: $CsvPath"

    if ($csv.errors.Count -gt 0) {
        $detail = ($csv.errors | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "The values file does not satisfy the scope:$([Environment]::NewLine)$detail"
    }

    Write-ModuleLog "Valid. $(@($scope.applications).Count) application(s) x $(@($scope.environments).Count) environment(s), $(@($scope.declaredKeys).Count) declared key(s), $(@($csv.rows).Count) value row(s)."
    foreach ($environment in @($scope.environments)) {
        $forbidden = @(Get-ForbiddenKey -Scope $scope -Environment $environment)
        if ($forbidden.Count -gt 0) {
            Write-ModuleLog "  $environment forbids: $($forbidden -join ', ')"
        }
    }
    Write-ModuleLog 'No network call was made and no credential was read.'
    return
}

if ($csv.errors.Count -gt 0) {
    $detail = ($csv.errors | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "The values file does not satisfy the scope. Run 'validate' to fix it before touching Azure DevOps:$([Environment]::NewLine)$detail"
}

# A writing verb is narrowed to one application. Without this, 'apply -ConfirmApply'
# with no key applied to every application in scope multiplied by every environment -
# six Variable Groups in the shipped example, PROD included, behind a single
# confirmation. docs/reference/command-model.md already promised the opposite, and
# the blast-radius argument in docs/overview/scope-and-limits.md depends on it.
#
# Checked before the environment file is read and before any network call, so the
# refusal costs nothing and needs no credentials - which is also what lets a test
# cover it offline.
if ($Command -in $script:WritingCommands -and -not $ApplicationKey) {
    throw "-ApplicationKey is required by '$Command'. It is what keeps one run to one application. In scope: $(@($scope.applications) -join ', ')."
}

Import-AdoAsCodeEnvironment -Path $EnvFile | Out-Null
$context = Get-AdoContext -ProjectContext $projectContext

# Built once per run, not inside the writers: the receipt is rewritten after every
# completed operation, so building it there would shell out to git dozens of times in
# one apply. The identity lookup is best effort - a run must not fail because it could
# not find out who was running it, since the report is the thing that would be lost.
# It lives here rather than in AdoAsCode.Report because that module knows nothing about
# Azure DevOps (ADR 0004).
$adoActor = $null
try {
    $adoActor = "$((Get-AdoAuthenticatedUser -Context $context).authenticatedUser.providerDisplayName)"
}
catch {
    Write-Verbose "Could not resolve the authenticated identity: $($_.Exception.Message)"
}
$script:provenance = New-AdoAsCodeProvenance -Module $moduleName -Command $Command -ActorDisplayName $adoActor
$script:runId = $script:provenance.runId
Write-ModuleLog "run $($script:runId)"
$project = Get-AdoProject -Context $context
Write-ModuleLog "Connected to '$($context.OrganizationUrl)' project '$($project.name)'."

$applications = @($scope.applications)
if ($ApplicationKey) {
    if ($applications -notcontains $ApplicationKey) {
        throw "Application '$ApplicationKey' is not in scope. In scope: $($applications -join ', ')."
    }
    $applications = @($ApplicationKey)
}

$environments = @($scope.environments)
if ($Environment) {
    if ($environments -notcontains $Environment) {
        throw "Environment '$Environment' is not in scope. In scope: $($environments -join ', ')."
    }
    $environments = @($Environment)
}

$excluded = @{}
if ($scope.PSObject.Properties.Name -contains 'manualExclusions') {
    foreach ($exclusion in @($scope.manualExclusions)) { $excluded["$($exclusion.group)"] = "$($exclusion.reason)" }
}

$targets = New-Object System.Collections.ArrayList
foreach ($application in $applications) {
    foreach ($environment in $environments) {
        $groupName = Get-GroupName -Pattern "$($scope.groupNamePattern)" -Application $application -Environment $environment
        if ($excluded.ContainsKey($groupName)) {
            Write-ModuleLog "skipping '$groupName': $($excluded[$groupName])"
            continue
        }
        $targets.Add([pscustomobject]@{ application = $application; environment = $environment }) | Out-Null
    }
}

if ($targets.Count -eq 0) {
    throw 'Nothing in scope after filters and exclusions.'
}

if (-not $ReportPath) {
    $suffix = if ($ApplicationKey -and $Environment) { "-$ApplicationKey-$Environment" } elseif ($ApplicationKey) { "-$ApplicationKey" } else { '' }
    $ReportPath = Join-Path $repoRoot "artifacts/reports/$moduleName-$Command$suffix.json"
}

if ($Command -eq 'inventory') {
    $groups = @(Get-AdoVariableGroup -Context $context)
    $plan = New-Plan -Command 'inventory' -Target (@($targets | ForEach-Object { "$($_.application)/$($_.environment)" }) -join ',')

    foreach ($target in $targets) {
        $groupName = Get-GroupName -Pattern "$($scope.groupNamePattern)" -Application $target.application -Environment $target.environment
        $match = @($groups | Where-Object { "$($_.name)" -eq $groupName })
        if ($match.Count -eq 0) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable Group' -Name $groupName `
                -Action 'validate' -Status 'ok' -Reason 'Absent.')
            continue
        }
        $group = Get-AdoVariableGroup -Context $context -Id ([int]$match[0].id)
        $secrets = @($group.variables.PSObject.Properties | Where-Object { [bool]$_.Value.isSecret }).Count
        $pending = @($group.variables.PSObject.Properties | Where-Object { "$($_.Value.value)" -ceq $sentinel }).Count
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable Group' -Name $groupName `
            -Action 'validate' -Status 'ok' `
            -Reason "variables=$(@($group.variables.PSObject.Properties).Count); secret=$secrets; awaiting configuration=$pending")
    }

    Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Provenance $script:provenance | Out-Null
    Write-PlanSummary -Plan $plan
    Write-ModuleLog "Report: $ReportPath"
    return $plan
}

$plan = New-VariableGroupPlan -Context $context -Scope $scope -Row $csv.rows -Target @($targets.ToArray()) `
    -Sentinel $sentinel -CommandName $Command -AllowUnqualifiedSecretName:$AllowUnqualifiedSecretName
Write-PlanSummary -Plan $plan

switch ($Command) {
    'plan' {
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Provenance $script:provenance | Out-Null
        Write-ModuleLog "Report: $ReportPath"
    }

    'smoke' {
        $checklist = @(
            [pscustomobject]@{ step = 1; check = 'Pipelines > Library lists every group in scope, each with the declared keys.' }
            [pscustomobject]@{ step = 2; check = "No variable still reads '$sentinel' unless it is a secret waiting for its owner." }
            [pscustomobject]@{ step = 3; check = 'Every secret variable still shows as secret, and the pipeline that consumes it succeeds. A blanked secret is only visible at run time.' }
            [pscustomobject]@{ step = 4; check = 'No group in a lower environment contains a key forbidden there.' }
            [pscustomobject]@{ step = 5; check = 'Re-run plan. Every operation should be ok or protected, and none pending.' }
        )
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Provenance $script:provenance `
            -Detail ([pscustomobject]@{ manualVerification = $checklist }) | Out-Null

        Write-ModuleLog 'Manual verification checklist:'
        foreach ($item in $checklist) { Write-ModuleLog "  $($item.step). $($item.check)" }
        Write-ModuleLog "Report: $ReportPath"
    }

    default {
        if (-not $ConfirmApply) {
            Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Provenance $script:provenance | Out-Null
            Write-ModuleLog 'Simulation only: apply requires -ConfirmApply. Nothing was modified.'
            Write-ModuleLog "Report: $ReportPath"
            return $plan
        }

        Assert-PlanApplicable -Plan $plan

        $receiptPath = Get-AdoAsCodeReceiptPath -ReportPath $ReportPath
        $completed = @(Invoke-VariableGroupApply -Context $context -Project $project -Scope $scope `
            -Row $csv.rows -Target @($targets.ToArray()) -Sentinel $sentinel -ReceiptPath $receiptPath -Provenance $script:provenance `
            -AllowUnqualifiedSecretName:$AllowUnqualifiedSecretName)

        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName -Provenance $script:provenance `
            -Detail ([pscustomobject]@{ appliedOperations = $completed }) | Out-Null

        Write-ModuleLog "apply complete: $($completed.Count) operation(s) written."
        Write-ModuleLog "Report: $ReportPath"
        Write-ModuleLog "Receipt: $receiptPath"
        Write-ModuleLog 'Next: run plan again. Nothing should be pending.'
    }
}

return $plan
