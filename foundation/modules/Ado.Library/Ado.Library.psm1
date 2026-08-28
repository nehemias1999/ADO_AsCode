<#
    Ado.Library - the Pipelines library surface: Variable Groups and Service
    Connections.

    Both resources share one hazard that shapes every function here: Azure DevOps
    never returns a stored secret on a GET, and it only accepts a full-object PUT.
    Round-tripping a resource therefore destroys its credentials unless the writer
    does something deliberate about it.

    Two measured facts drive the design:

    * On a Variable Group PUT, a variable whose `value` property is omitted is
      treated as an empty string. It is not "left as it was". A PUT that omits the
      value of a secret variable blanks that secret.
    * On a Service Connection PUT, the authorization parameters must be resent in
      full. Since GET never returns them, a round-trip sends null and erases the
      credential. The portal performs a partial update and does not.

    Consequences, encoded below:

    * The only value an automation will overwrite is the configuration sentinel.
      Anything else already carries a decision somebody made.
    * A Variable Group containing secrets can only be written through
      Set-AdoVariableGroupValue, which resends every secret with a value resolved
      from the local environment and blocks when it cannot resolve one.
    * A Service Connection rename is not implemented. It is reported as manual
      work, on purpose - see the module guide.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Placeholder written when a value is not known to the automation. It is the only
# value a later run is allowed to replace, which is what lets the platform owner
# fill in a real credential in the portal without the next apply undoing it.
$script:DefaultSentinel = 'PENDING_OWNER_CONFIGURATION'

# The variablegroups collection GET is preview-only; the item PUT is not.
$script:VariableGroupListApiVersion = '7.1-preview.2'

function Get-AdoConfigurationSentinel {
    <#
    .SYNOPSIS
        Returns the placeholder value that marks a setting as not yet configured.

    .DESCRIPTION
        Exposed as a function so tests and callers agree on one literal instead of
        repeating the string, which is how a typo turns into an overwritten
        credential.

    .EXAMPLE
        Get-AdoConfigurationSentinel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:DefaultSentinel
}

#region Variable Groups

function Get-AdoVariableGroup {
    <#
    .SYNOPSIS
        Lists Variable Groups, or returns one by name or id.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Name
        Exact group name. Returns the group or $null.

    .PARAMETER Id
        Group identifier. Returns the full group, including its project references.

    .EXAMPLE
        Get-AdoVariableGroup -Context $context -Name 'Credentials_APP_ALPHA_DEV'
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(ParameterSetName = 'ByName', Mandatory)] [string] $Name,
        [Parameter(ParameterSetName = 'ById', Mandatory)] [int] $Id
    )

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $uri = New-AdoUri -Context $Context -Path "_apis/distributedtask/variablegroups/$Id" -IncludeProject
        return Invoke-AdoRest -Context $Context -Method Get -Uri $uri
    }

    $uri = New-AdoUri -Context $Context -Path '_apis/distributedtask/variablegroups' -IncludeProject `
        -ApiVersion $script:VariableGroupListApiVersion
    $groups = @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)

    if ($PSCmdlet.ParameterSetName -eq 'All') { return $groups }
    return @($groups | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function New-AdoVariableGroup {
    <#
    .SYNOPSIS
        Creates a Variable Group whose declared keys start at the sentinel.

    .DESCRIPTION
        Creation writes structure, not values. Every declared key is created with
        the sentinel unless the caller supplies a known value, so the group is
        immediately usable as a contract - a pipeline can reference it and fail
        loudly on a missing value - while the real credentials are filled in later
        by whoever holds them.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Name
        Group name.

    .PARAMETER Description
        Group description.

    .PARAMETER Variable
        Ordered dictionary or hashtable of key to definition. A definition may be a
        plain value, or a hashtable with `value` and `isSecret`.

    .PARAMETER Sentinel
        Placeholder for keys with no supplied value.

    .EXAMPLE
        New-AdoVariableGroup -Context $context -Project $project -Name 'Credentials_APP_ALPHA_DEV' `
            -Variable @{ APP_SERVER_HOST = @{ isSecret = $false }; APP_SERVER_PASSWORD = @{ isSecret = $true } }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Description = '',
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Variable,
        [string] $Sentinel = $script:DefaultSentinel
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create Variable Group')) { return }

    $variables = @{}
    foreach ($key in $Variable.Keys) {
        $definition = $Variable[$key]
        $isSecret = $false
        $value = $Sentinel

        if ($definition -is [System.Collections.IDictionary]) {
            if ($definition.Contains('isSecret')) { $isSecret = [bool]$definition['isSecret'] }
            if ($definition.Contains('value') -and -not [string]::IsNullOrWhiteSpace("$($definition['value'])")) {
                $value = "$($definition['value'])"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace("$definition")) {
            $value = "$definition"
        }

        $variables["$key"] = @{ value = $value; isSecret = $isSecret }
    }

    $uri = New-AdoUri -Context $Context -Path '_apis/distributedtask/variablegroups' -IncludeProject `
        -ApiVersion $script:VariableGroupListApiVersion
    return Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{
        name                          = $Name
        description                   = $Description
        type                          = 'Vsts'
        variables                     = $variables
        variableGroupProjectReferences = @(
            @{
                projectReference = @{ id = $Project.id; name = $Project.name }
                name             = $Name
                description      = $Description
            }
        )
    }
}

function Get-AdoVariableGroupSecretSource {
    <#
    .SYNOPSIS
        Resolves a known value for each secret variable of a group from the process
        environment.

    .DESCRIPTION
        Resolution is ENVIRONMENT QUALIFIED. A secret variable named
        APP_SERVER_PASSWORD in the DEV group is resolved from APP_SERVER_PASSWORD_DEV,
        not from APP_SERVER_PASSWORD.

        That qualification is the whole point of this function's signature. The group
        name carries the environment (groupNamePattern) but the secret's own name does
        not, and the live value cannot be read back to compare against - Azure DevOps
        never returns a stored secret. So with an unqualified lookup, a stale or
        DEV-valued APP_SERVER_PASSWORD sitting in .env was written over the PROD
        secret by any apply that touched a non-secret key in that group, and the API
        reported success. Nothing anywhere could detect it afterwards.

        The unqualified name is accepted only under -AllowUnqualifiedName, for the
        case where one credential genuinely is shared across environments. It has to
        be asked for, because the failure mode of guessing wrong is silent and
        unrecoverable.

        A secret with no resolvable value is deliberately left ABSENT from the
        returned map, so New-AdoVariableGroupPayload reports it as a block rather
        than resending an empty string - which would blank the credential.

        A secret with no value in the environment is deliberately left ABSENT from
        the returned map, so the writer reports it as a block rather than resending
        an empty string - which would blank the credential.

    .PARAMETER VariableGroup
        Group object from Get-AdoVariableGroup -Id.

    .PARAMETER Environment
        Environment this group belongs to, for example DEV or PROD. When supplied, each
        secret is resolved from <NAME>_<ENVIRONMENT>.

    .PARAMETER AllowUnqualifiedName
        Also accept the bare <NAME>, for a credential deliberately shared across
        environments. Without it, a secret with no environment-qualified variable is
        left unresolved and the write is blocked.

    .EXAMPLE
        $sources = Get-AdoVariableGroupSecretSource -VariableGroup $group -Environment 'PROD'

        Resolves APP_SERVER_PASSWORD from APP_SERVER_PASSWORD_PROD.

    .OUTPUTS
        Hashtable of variable name to value. A secret that could not be resolved is
        absent, which is what makes the writer block instead of blanking it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $VariableGroup,
        [string] $Environment,
        [switch] $AllowUnqualifiedName
    )

    $sources = @{}
    foreach ($property in @($VariableGroup.variables.PSObject.Properties)) {
        if ($property.Value.isSecret -ne $true) { continue }

        $secretName = "$($property.Name)"

        # Qualified first, always. The bare name is a fallback that has to be asked
        # for, because it is the one that can carry a DEV value into PROD.
        $candidates = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($Environment)) {
            $candidates.Add("${secretName}_$Environment")
        }
        if ($AllowUnqualifiedName -or [string]::IsNullOrWhiteSpace($Environment)) {
            $candidates.Add($secretName)
        }

        foreach ($candidate in $candidates) {
            $value = [Environment]::GetEnvironmentVariable($candidate, 'Process')
            if (-not [string]::IsNullOrEmpty($value)) {
                $sources[$secretName] = $value
                break
            }
        }
    }
    return $sources
}

function Get-AdoVariableGroupUpdate {
    <#
    .SYNOPSIS
        Decides which non-secret variables may be written, and which must not.

    .DESCRIPTION
        Pure function, and the single place the overwrite policy lives:

        * A declared key that does not exist is added.
        * A key whose live value is exactly the sentinel is filled in.
        * A key holding any other value is left alone. Somebody decided that value.
        * A secret key is refused: its live value cannot be read, so there is no way
          to tell a sentinel from a real credential.

        `Force` narrows rather than widens the policy: it allows correcting a value
        only when the live value matches the expected previous value exactly, which
        is what makes it safe to re-propagate a renamed resource without relaxing
        the general rule. Comparisons are case sensitive on purpose - a nearly equal
        value must reach a human, not be overwritten.

    .PARAMETER VariableGroup
        Group object from Get-AdoVariableGroup -Id.

    .PARAMETER DesiredValue
        Hashtable of key to desired value.

    .PARAMETER Force
        Hashtable of key to @{ from = '...'; to = '...' } for a verified correction.

    .PARAMETER OnlyMissing
        Only add absent keys; do not fill sentinels.

    .PARAMETER Sentinel
        Placeholder value that may be replaced.

    .EXAMPLE
        Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ APP_SERVER_HOST = 'app-dev-01.contoso.local' }

    .OUTPUTS
        PSCustomObject with `updates` (name, value, isNew, forcedFrom) and `blocked`.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $VariableGroup,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $DesiredValue,
        [System.Collections.IDictionary] $Force,
        [switch] $OnlyMissing,
        [string] $Sentinel = $script:DefaultSentinel
    )

    $updates = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[string]
    $forced = if ($Force) { $Force } else { @{} }

    foreach ($key in $DesiredValue.Keys) {
        $variable = $null
        if ($VariableGroup.variables.PSObject.Properties.Name -contains "$key") {
            $variable = $VariableGroup.variables."$key"
        }

        if ($null -eq $variable) {
            $updates.Add([pscustomobject]@{ name = "$key"; value = "$($DesiredValue[$key])"; isNew = $true; forcedFrom = $null })
            continue
        }
        if ([bool]$variable.isSecret) {
            $blocked.Add("$key is secret and cannot be updated automatically; its live value cannot be read to verify what would be replaced.")
            continue
        }
        if ($OnlyMissing) { continue }
        if ("$($variable.value)" -ceq $Sentinel) {
            $updates.Add([pscustomobject]@{ name = "$key"; value = "$($DesiredValue[$key])"; isNew = $false; forcedFrom = $Sentinel })
        }
    }

    foreach ($key in @($forced.Keys)) {
        if (@($updates | Where-Object { $_.name -eq "$key" }).Count -gt 0) { continue }

        $variable = $null
        if ($VariableGroup.variables.PSObject.Properties.Name -contains "$key") {
            $variable = $VariableGroup.variables."$key"
        }
        if ($null -eq $variable) { continue }
        if ([bool]$variable.isSecret) {
            $blocked.Add("$key is secret and cannot be corrected by declared value.")
            continue
        }

        $from = "$($forced[$key].from)"
        $to = "$($forced[$key].to)"
        if ("$($variable.value)" -cne $from) { continue }
        if ($from -ceq $to) { continue }

        $updates.Add([pscustomobject]@{ name = "$key"; value = $to; isNew = $false; forcedFrom = $from })
    }

    return [pscustomobject]@{
        updates = @($updates.ToArray())
        blocked = @($blocked.ToArray())
    }
}

function New-AdoVariableGroupPayload {
    <#
    .SYNOPSIS
        Builds the complete variables payload for a Variable Group PUT, re-posting
        every secret with a known value.

    .DESCRIPTION
        Pure function, so every rule is verifiable offline. This is the mitigation
        for the measured behaviour stated at the top of the module: on a PUT, an
        omitted `value` is an empty string, so "leave the secret alone by not
        sending it" silently deletes the secret.

        The contract implemented instead is: re-post each secret with a value the
        caller can prove it knows, and refuse to write at all when it cannot.
        Blocking conditions:

        * A secret in the group has no entry in SecretSource.
        * A resolved secret value is empty.
        * The number of secrets in the payload would differ from the number in the
          group - which would mean a secret is about to be dropped or invented.

        Non-secret changes come from two independent inputs:

        * RenameUpdate re-propagates a declared value only when the live value
          matches `from` exactly.
        * SetValue writes a key unconditionally. That is what allows completing an
          absent key in a group that holds secrets, which the value-policy writer
          refuses to touch as a whole.

    .PARAMETER VariableGroup
        Group object from Get-AdoVariableGroup -Id.

    .PARAMETER RenameUpdate
        Hashtable of key to @{ from = '...'; to = '...' }.

    .PARAMETER SetValue
        Hashtable of key to value.

    .PARAMETER SecretSource
        Hashtable of secret key to resolved value, from Get-AdoVariableGroupSecretSource.

    .EXAMPLE
        New-AdoVariableGroupPayload -VariableGroup $group -SetValue @{ DEPLOY_PATH = '/srv/app' } -SecretSource $sources

    .OUTPUTS
        PSCustomObject with variables, applied, blocked, restoredSecrets and secretCount.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $VariableGroup,
        [System.Collections.IDictionary] $RenameUpdate,
        [System.Collections.IDictionary] $SetValue,
        [System.Collections.IDictionary] $SecretSource
    )

    $renameMap = if ($RenameUpdate) { $RenameUpdate } else { @{} }
    $setMap = if ($SetValue) { $SetValue } else { @{} }
    $secretMap = if ($SecretSource) { $SecretSource } else { @{} }

    $variables = @{}
    $applied = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[string]
    $restoredSecrets = New-Object System.Collections.Generic.List[string]
    $secretCount = 0

    foreach ($property in @($VariableGroup.variables.PSObject.Properties)) {
        $variableName = "$($property.Name)"

        if (-not [bool]$property.Value.isSecret) {
            $variables[$variableName] = @{ value = "$($property.Value.value)"; isSecret = $false }
            continue
        }

        $secretCount++
        $source = $null
        if ($secretMap.Contains($variableName)) { $source = "$($secretMap[$variableName])" }

        if ([string]::IsNullOrEmpty($source)) {
            $blocked.Add("$variableName is secret and has no known source to re-post it. Abort before writing: the PUT would blank it.")
            continue
        }

        $variables[$variableName] = @{ value = $source; isSecret = $true }
        $restoredSecrets.Add($variableName)
    }

    foreach ($key in @($renameMap.Keys)) {
        $variable = $null
        if ($VariableGroup.variables.PSObject.Properties.Name -contains "$key") {
            $variable = $VariableGroup.variables."$key"
        }
        if ($null -eq $variable) { continue }
        if ([bool]$variable.isSecret) {
            # There is no way to read a secret's live value, so "only overwrite when
            # it equals `from`" cannot be verified. Refuse rather than guess.
            $blocked.Add("$key is secret and cannot be re-propagated by declared value.")
            continue
        }

        $from = "$($renameMap[$key].from)"
        $to = "$($renameMap[$key].to)"
        if ("$($variable.value)" -cne $from) { continue }
        if ($from -ceq $to) { continue }

        $variables["$key"] = @{ value = $to; isSecret = $false }
        $applied.Add([pscustomobject]@{ name = "$key"; value = $to; forcedFrom = $from })
    }

    foreach ($key in @($setMap.Keys)) {
        $variable = $null
        if ($VariableGroup.variables.PSObject.Properties.Name -contains "$key") {
            $variable = $VariableGroup.variables."$key"
        }
        if ($null -ne $variable -and [bool]$variable.isSecret) {
            $blocked.Add("$key is secret and cannot be set by explicit value.")
            continue
        }

        $previous = if ($null -eq $variable) { $null } else { "$($variable.value)" }
        if ($null -ne $variable -and "$previous" -ceq "$($setMap[$key])") { continue }

        $variables["$key"] = @{ value = "$($setMap[$key])"; isSecret = $false }
        $applied.Add([pscustomobject]@{ name = "$key"; value = "$($setMap[$key])"; forcedFrom = $previous })
    }

    # Last invariant: the payload must carry exactly as many secrets as the group
    # holds. A mismatch means one is about to be dropped or invented, and neither
    # is recoverable once the PUT lands.
    if ($blocked.Count -eq 0 -and $restoredSecrets.Count -ne $secretCount) {
        $blocked.Add("The payload would carry $($restoredSecrets.Count) secret(s) but the group holds $secretCount. Refusing to write.")
    }

    return [pscustomobject]@{
        variables       = $variables
        applied         = @($applied.ToArray())
        blocked         = @($blocked.ToArray())
        restoredSecrets = @($restoredSecrets.ToArray())
        secretCount     = $secretCount
    }
}

function Set-AdoVariableGroupValue {
    <#
    .SYNOPSIS
        Writes declared values to a Variable Group while preserving its secrets.

    .DESCRIPTION
        The only supported way to modify a Variable Group that contains secrets.
        It reads the group, resolves each secret from the environment, builds the
        payload, refuses to continue if the payload reports any block, and only then
        issues the PUT.

        The description Azure DevOps displays is the one on the project reference,
        not the top-level one: sending only the top-level description is silently
        lost. Other projects' references are preserved untouched.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER GroupId
        Variable Group identifier.

    .PARAMETER RenameUpdate
        Hashtable of key to @{ from = '...'; to = '...' }.

    .PARAMETER SetValue
        Hashtable of key to value.

    .PARAMETER Description
        Optional new description.

    .PARAMETER Environment
        Environment this group belongs to. Passed through to
        Get-AdoVariableGroupSecretSource, which resolves each secret from
        <NAME>_<ENVIRONMENT>.

    .PARAMETER AllowUnqualifiedSecretName
        Allow a secret to be resolved from its bare name as well as the
        environment-qualified one. See Get-AdoVariableGroupSecretSource.

    .EXAMPLE
        Set-AdoVariableGroupValue -Context $context -Project $project -GroupId 42 -SetValue @{ DEPLOY_PATH = '/srv/app' }

    .OUTPUTS
        The payload object, so the caller can record what was applied.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [int] $GroupId,
        [System.Collections.IDictionary] $RenameUpdate,
        [System.Collections.IDictionary] $SetValue,
        [string] $Description,
        [string] $Environment,
        [switch] $AllowUnqualifiedSecretName
    )

    $group = Get-AdoVariableGroup -Context $Context -Id $GroupId
    $resolvedSecrets = Get-AdoVariableGroupSecretSource -VariableGroup $group `
        -Environment $Environment -AllowUnqualifiedName:$AllowUnqualifiedSecretName
    $payload = New-AdoVariableGroupPayload -VariableGroup $group -RenameUpdate $RenameUpdate `
        -SetValue $SetValue -SecretSource $resolvedSecrets

    if ($payload.blocked.Count -gt 0) {
        throw ($payload.blocked -join ' ')
    }
    if ($payload.applied.Count -eq 0 -and -not $PSBoundParameters.ContainsKey('Description')) {
        return $payload
    }

    $targetDescription = "$($group.description)"
    if ($PSBoundParameters.ContainsKey('Description')) { $targetDescription = $Description }

    if (-not $PSCmdlet.ShouldProcess($group.name, "Write $($payload.applied.Count) variable(s), re-posting $($payload.secretCount) secret(s)")) {
        return $payload
    }

    $references = @($group.variableGroupProjectReferences | ForEach-Object {
        $referenceDescription = $_.description
        if ("$($_.projectReference.id)" -eq "$($Project.id)") { $referenceDescription = $targetDescription }
        @{
            projectReference = @{ id = $_.projectReference.id; name = $_.projectReference.name }
            name             = $_.name
            description      = $referenceDescription
        }
    })

    $uri = New-AdoUri -Context $Context -Path "_apis/distributedtask/variablegroups/$GroupId" -IncludeProject
    Invoke-AdoRest -Context $Context -Method Put -Uri $uri -Body @{
        name                           = $group.name
        description                    = $targetDescription
        type                           = $group.type
        variables                      = $payload.variables
        variableGroupProjectReferences = $references
    } | Out-Null

    return $payload
}

function Rename-AdoVariableGroup {
    <#
    .SYNOPSIS
        Renames a Variable Group, preserving its variables and its secrets.

    .DESCRIPTION
        A rename is still a full PUT, so it carries the same secret hazard as any
        other write and goes through the same payload builder.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER GroupId
        Variable Group identifier.

    .PARAMETER NewName
        New group name.

    .PARAMETER Environment
        Environment this group belongs to. Passed through to
        Get-AdoVariableGroupSecretSource. A rename re-posts every secret, so the same
        qualification applies.

    .PARAMETER AllowUnqualifiedSecretName
        Allow a secret to be resolved from its bare name as well as the
        environment-qualified one.

    .EXAMPLE
        Rename-AdoVariableGroup -Context $context -Project $project -GroupId 42 -NewName 'Credentials_APP_ALPHA_QA'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [int] $GroupId,
        [Parameter(Mandatory)] [string] $NewName,
        [string] $Environment,
        [switch] $AllowUnqualifiedSecretName
    )

    $group = Get-AdoVariableGroup -Context $Context -Id $GroupId
    if ("$($group.name)" -ceq $NewName) { return $group }

    $resolvedSecrets = Get-AdoVariableGroupSecretSource -VariableGroup $group `
        -Environment $Environment -AllowUnqualifiedName:$AllowUnqualifiedSecretName
    $payload = New-AdoVariableGroupPayload -VariableGroup $group -SecretSource $resolvedSecrets
    if ($payload.blocked.Count -gt 0) {
        throw ($payload.blocked -join ' ')
    }

    if (-not $PSCmdlet.ShouldProcess($group.name, "Rename Variable Group to '$NewName'")) { return $group }

    $references = @($group.variableGroupProjectReferences | ForEach-Object {
        $referenceName = $_.name
        if ("$($_.projectReference.id)" -eq "$($Project.id)") { $referenceName = $NewName }
        @{
            projectReference = @{ id = $_.projectReference.id; name = $_.projectReference.name }
            name             = $referenceName
            description      = $_.description
        }
    })

    $uri = New-AdoUri -Context $Context -Path "_apis/distributedtask/variablegroups/$GroupId" -IncludeProject
    return Invoke-AdoRest -Context $Context -Method Put -Uri $uri -Body @{
        name                           = $NewName
        description                    = $group.description
        type                           = $group.type
        variables                      = $payload.variables
        variableGroupProjectReferences = $references
    }
}

#endregion

#region Service Connections

function Get-AdoServiceEndpoint {
    <#
    .SYNOPSIS
        Lists Service Connections, or returns one by name.

    .DESCRIPTION
        The response never contains authorization parameters. Treat a Service
        Connection read as metadata only: it can tell you the endpoint exists, not
        whether its credential is valid.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Name
        Exact connection name. Returns the connection or $null.

    .EXAMPLE
        Get-AdoServiceEndpoint -Context $context -Name 'SFTP_APP_ALPHA_DEV'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [string] $Name
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/serviceendpoint/endpoints' -IncludeProject
    $endpoints = @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)

    if (-not $PSBoundParameters.ContainsKey('Name')) { return $endpoints }
    return @($endpoints | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function New-AdoSshServiceEndpoint {
    <#
    .SYNOPSIS
        Creates an SSH/SFTP Service Connection.

    .DESCRIPTION
        Authentication is chosen from what the caller can actually supply, in this
        order: private key, then password, then the sentinel.

        The private key field is omitted entirely when there is no key, rather than
        sent empty. An empty PrivateKey declares a certificate slot that Azure
        DevOps keeps, and that slot then has to be filled before the connection
        works - a confusing failure for whoever completes the credential later.

        `grantAccessToAllPipelines` is false by default. A connection that any
        pipeline may use is a lateral movement path, and the pipelines that need it
        are known at provisioning time.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Name
        Connection name.

    .PARAMETER ServerHost
        Target host name.

    .PARAMETER Port
        Target port.

    .PARAMETER Username
        Login user name.

    .PARAMETER Password
        Login password. Ignored when PrivateKey is supplied.

    .PARAMETER PrivateKey
        Private key material.

    .PARAMETER Description
        Connection description.

    .PARAMETER Sentinel
        Placeholder used when neither a password nor a key is available.

    .EXAMPLE
        New-AdoSshServiceEndpoint -Context $context -Project $project -Name 'SFTP_APP_ALPHA_DEV' `
            -ServerHost 'sftp-dev-01.contoso.local' -Username 'svc_deploy'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ServerHost,
        [int] $Port = 22,
        [Parameter(Mandatory)] [string] $Username,
        [string] $Password,
        [string] $PrivateKey,
        [string] $Description = '',
        [string] $Sentinel = $script:DefaultSentinel
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create SSH Service Connection')) { return }

    $body = New-AdoSshServiceEndpointPayload -Project $Project -Name $Name -ServerHost $ServerHost `
        -Port $Port -Username $Username -Password $Password -PrivateKey $PrivateKey `
        -Description $Description -Sentinel $Sentinel

    $uri = New-AdoUri -Context $Context -Path '_apis/serviceendpoint/endpoints' -IncludeProject
    return Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body $body
}

function New-AdoSshServiceEndpointPayload {
    <#
    .SYNOPSIS
        Builds the request body for an SSH/SFTP Service Connection.

    .DESCRIPTION
        Split out from New-AdoSshServiceEndpoint so the credential placement is a
        pure function over its inputs, and can therefore be asserted without a round
        trip. What goes where is the whole safety question here, and it was wrong
        before this function existed.

        Azure DevOps treats the two bags in this payload differently:

        - `authorization.parameters` is write-only. GET never returns it.
        - `data` is metadata and comes straight back on
          `GET _apis/serviceendpoint/endpoints`, in clear text, to every identity
          with read access to the project.

        So credential material belongs in `authorization.parameters` and nowhere
        else. A private key written into `data` stops being a secret the moment it
        is written, and lands in any inventory built from an endpoint read.

        Authentication is chosen from what the caller can actually supply, in this
        order: private key, then password, then the sentinel. The private key field
        is omitted entirely when there is no key, rather than sent empty - an empty
        PrivateKey declares a certificate slot Azure DevOps keeps, and that slot then
        has to be filled before the connection works.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Name
        Connection name.

    .PARAMETER ServerHost
        Target host name.

    .PARAMETER Port
        Target port.

    .PARAMETER Username
        Login user name.

    .PARAMETER Password
        Login password. Ignored when PrivateKey is supplied.

    .PARAMETER PrivateKey
        Private key material.

    .PARAMETER Description
        Connection description.

    .PARAMETER Sentinel
        Placeholder used when neither a password nor a key is available.

    .EXAMPLE
        New-AdoSshServiceEndpointPayload -Project $project -Name 'SFTP_APP_ALPHA_DEV' `
            -ServerHost 'sftp-dev-01.example.invalid' -Username 'svc_deploy'

    .OUTPUTS
        Hashtable, ready to POST.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ServerHost,
        [int] $Port = 22,
        [Parameter(Mandatory)] [string] $Username,
        [string] $Password,
        [string] $PrivateKey,
        [string] $Description = '',
        [string] $Sentinel = $script:DefaultSentinel
    )

    $authorizationParameters = @{ username = $Username }

    # Host and Port only. Nothing added here may be a credential: this bag is
    # readable by anyone who can read the endpoint.
    $data = @{ Host = $ServerHost; Port = "$Port" }

    if (-not [string]::IsNullOrWhiteSpace($PrivateKey)) {
        $authorizationParameters.privateKey = $PrivateKey
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Password)) {
        $authorizationParameters.password = $Password
    }
    else {
        $authorizationParameters.password = $Sentinel
    }

    return @{
        name                             = $Name
        type                             = 'ssh'
        url                              = "ssh://${ServerHost}:$Port"
        description                      = $Description
        isShared                         = $false
        isReady                          = $true
        owner                            = 'library'
        authorization                    = @{
            scheme     = 'UsernamePassword'
            parameters = $authorizationParameters
        }
        data                             = $data
        serviceEndpointProjectReferences = @(
            @{
                projectReference = @{ id = $Project.id; name = $Project.name }
                name             = $Name
                description      = $Description
            }
        )
    }
}

function Get-AdoServiceEndpointStatus {
    <#
    .SYNOPSIS
        Classifies a declared Service Connection against what exists, as a plan
        operation.

    .DESCRIPTION
        Pure function over an inventory, so it runs without a second round trip per
        connection. The classification encodes the module's central safety rule:

        * Absent          -> create / pending.
        * Present         -> protected. Not updated, because a full PUT would send a
                             null credential over whatever the owner configured, and
                             GET cannot tell us what is there.
        * Present, forced -> update / pending, only with both force switches, which
                             the caller must have obtained explicitly.

    .PARAMETER Name
        Declared connection name.

    .PARAMETER ExistingEndpoint
        Inventory of existing connections.

    .PARAMETER Force
        The caller supplied both force switches.

    .EXAMPLE
        Get-AdoServiceEndpointStatus -Name 'SFTP_APP_ALPHA_DEV' -ExistingEndpoint $inventory

    .OUTPUTS
        PSCustomObject with action, status and reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingEndpoint,
        [switch] $Force
    )

    $existing = @($ExistingEndpoint | Where-Object { $_.name -eq $Name })

    if ($existing.Count -eq 0) {
        return [pscustomobject]@{
            action = 'create'; status = 'pending'
            reason = "Connection '$Name' does not exist. It will be created with the configuration sentinel so the owner can complete the credential in the portal."
        }
    }
    if ($existing.Count -gt 1) {
        return [pscustomobject]@{
            action = 'resolve'; status = 'blocked'
            reason = "Connection name '$Name' matches $($existing.Count) endpoints. Resolve the duplicate before continuing."
        }
    }
    if ($Force) {
        return [pscustomobject]@{
            action = 'update'; status = 'pending'
            reason = "Connection '$Name' exists and will be overwritten because both force switches were supplied. Every authorization parameter must be resent or it will be erased."
        }
    }

    return [pscustomobject]@{
        action = 'exists'; status = 'protected'
        reason = "Connection '$Name' exists and is not modified. A full PUT would replace its credential with null, and GET does not return the stored value."
    }
}

#endregion

Export-ModuleMember -Function @(
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
    'New-AdoSshServiceEndpointPayload',
    'Get-AdoServiceEndpointStatus'
)
