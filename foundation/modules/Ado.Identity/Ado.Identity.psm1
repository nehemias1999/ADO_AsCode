<#
    Ado.Identity - the "who" of Azure DevOps: identities, Teams, memberships,
    administrators and plain security groups.

    A Team in Azure DevOps is not only a label. Creating one creates a security
    group, and it becomes usable for Boards only once the work-tracking settings
    are also in place. That second half lives in Ado.Work; this module stops at
    the identity boundary on purpose, so a caller that only needs to add a member
    does not drag board reconciliation into its call graph.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AdoIdentity {
    <#
    .SYNOPSIS
        Resolves a user reference - typically a sign-in address - to an identity.

    .DESCRIPTION
        Membership is supplied as text (a user principal name), so it has to be
        resolved to an identity id before it can be added to a group. The search
        endpoint is fuzzy, which makes ambiguity the real risk: adding the wrong
        person to a Team is worse than failing. The resolution rules are therefore
        strict.

        1. Prefer an exact match on uniqueName or on a display name.
        2. Accept a single fuzzy match.
        3. Fail on zero matches, and fail on several - never guess.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Identity
        Sign-in address or display name to resolve.

    .EXAMPLE
        Get-AdoIdentity -Context $context -Identity 'dana.reyes@contoso.com'

    .OUTPUTS
        The matched identity object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Identity
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/identities' -Service Identity -Query @{
        searchFilter    = 'General'
        filterValue     = $Identity
        queryMembership = 'None'
    }

    $response = Invoke-AdoRest -Context $Context -Method Get -Uri $uri
    $candidates = @($response.value | Where-Object {
        -not $_.isContainer -and -not [string]::IsNullOrWhiteSpace($_.id)
    })

    $exact = @($candidates | Where-Object {
        $_.uniqueName -eq $Identity -or
        $_.providerDisplayName -eq $Identity -or
        $_.customDisplayName -eq $Identity
    })
    if ($exact.Count -eq 1) { return $exact[0] }

    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -eq 0) {
        throw "Identity '$Identity' was not found in the organization. It must already have access before it can be added to a Team."
    }

    throw "Identity '$Identity' is ambiguous ($($candidates.Count) matches). Use the exact sign-in address."
}

function Get-AdoGraphDescriptor {
    <#
    .SYNOPSIS
        Translates a storage key (a user, team or project id) into a Graph descriptor.

    .DESCRIPTION
        The Graph API addresses subjects by descriptor, not by id, so every
        membership call needs this translation first.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER StorageKey
        Identifier of the subject: a user id, a team id or a project id.

    .EXAMPLE
        Get-AdoGraphDescriptor -Context $context -StorageKey $project.id
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $StorageKey
    )

    $uri = New-AdoUri -Context $Context -Path "_apis/graph/descriptors/$([Uri]::EscapeDataString($StorageKey))" `
        -Service Identity -ApiVersion '7.1-preview.1'
    $response = Invoke-AdoRest -Context $Context -Method Get -Uri $uri
    return "$($response.value)"
}

function Get-AdoTeam {
    <#
    .SYNOPSIS
        Lists the Teams of the project, or returns one Team by name.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Name
        Exact Team name. When supplied, returns that Team or $null.

    .EXAMPLE
        Get-AdoTeam -Context $context -Project $project -Name 'APP_ALPHA_Team'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [string] $Name
    )

    $uri = New-AdoUri -Context $Context -Path "_apis/projects/$($Project.id)/teams" -Query @{ '$top' = 500 }
    $teams = @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)

    if (-not $PSBoundParameters.ContainsKey('Name')) { return $teams }

    $matched = @($teams | Where-Object { $_.name -eq $Name })
    if ($matched.Count -gt 1) {
        throw "Team name '$Name' matched $($matched.Count) Teams. Resolve the duplicate in the project before continuing."
    }
    if ($matched.Count -eq 0) { return $null }
    return $matched[0]
}

function New-AdoTeam {
    <#
    .SYNOPSIS
        Creates a Team.

    .DESCRIPTION
        Creating the Team is only the first of four steps needed before its Board
        works. See Initialize-AdoTeamWorkConfiguration in Ado.Work: without the
        backlog iteration and the team field value, opening the Board returns
        TF400509.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Name
        Team name.

    .PARAMETER Description
        Team description.

    .EXAMPLE
        New-AdoTeam -Context $context -Project $project -Name 'APP_ALPHA_Team' -Description 'Delivery team for APP_ALPHA'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Description = ''
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create Azure DevOps Team')) { return }

    $uri = New-AdoUri -Context $Context -Path "_apis/projects/$($Project.id)/teams"
    return Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{
        name        = $Name
        description = $Description
    }
}

function Rename-AdoTeam {
    <#
    .SYNOPSIS
        Renames a Team.

    .DESCRIPTION
        Renaming the Team is safe on its own: its id, its members and its Board
        survive. What is not safe is renaming the Area Path that carries the same
        name - that rewrites System.AreaPath on every existing Work Item. See
        Rename-AdoAreaPath in Ado.Work.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER TeamId
        Identifier of the Team to rename.

    .PARAMETER NewName
        New Team name.

    .PARAMETER Description
        Optional new description. Omitted leaves the current one.

    .EXAMPLE
        Rename-AdoTeam -Context $context -Project $project -TeamId $team.id -NewName 'APP_ALPHA_Team'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $TeamId,
        [Parameter(Mandatory)] [string] $NewName,
        [string] $Description
    )

    if (-not $PSCmdlet.ShouldProcess($TeamId, "Rename Azure DevOps Team to '$NewName'")) { return }

    $body = @{ name = $NewName }
    if ($PSBoundParameters.ContainsKey('Description')) { $body.description = $Description }

    $uri = New-AdoUri -Context $Context -Path "_apis/projects/$($Project.id)/teams/$([Uri]::EscapeDataString($TeamId))"
    return Invoke-AdoRest -Context $Context -Method Patch -Uri $uri -Body $body
}

function Get-AdoTeamMember {
    <#
    .SYNOPSIS
        Lists the members of a Team.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER TeamId
        Identifier of the Team.

    .EXAMPLE
        Get-AdoTeamMember -Context $context -Project $project -TeamId $team.id
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $TeamId
    )

    $uri = New-AdoUri -Context $Context -Path "_apis/projects/$($Project.id)/teams/$([Uri]::EscapeDataString($TeamId))/members" -Query @{ '$top' = 500 }
    return @((Invoke-AdoRest -Context $Context -Method Get -Uri $uri).value)
}

function Add-AdoTeamMember {
    <#
    .SYNOPSIS
        Adds a user to a Team.

    .DESCRIPTION
        Membership is a Graph relationship between two descriptors, so both the
        user id and the team id are translated first. The call is idempotent:
        adding an existing member succeeds without changing anything.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER TeamId
        Identifier of the Team.

    .PARAMETER UserId
        Identifier of the user, from Get-AdoIdentity.

    .EXAMPLE
        Add-AdoTeamMember -Context $context -TeamId $team.id -UserId $identity.id
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamId,
        [Parameter(Mandatory)] [string] $UserId
    )

    if (-not $PSCmdlet.ShouldProcess($UserId, "Add member to Team $TeamId")) { return }

    $teamDescriptor = Get-AdoGraphDescriptor -Context $Context -StorageKey $TeamId
    $userDescriptor = Get-AdoGraphDescriptor -Context $Context -StorageKey $UserId

    $uri = New-AdoUri -Context $Context `
        -Path "_apis/graph/memberships/$([Uri]::EscapeDataString($userDescriptor))/$([Uri]::EscapeDataString($teamDescriptor))" `
        -Service Identity -ApiVersion '7.1-preview.1'
    Invoke-AdoRest -Context $Context -Method Put -Uri $uri | Out-Null
}

function Set-AdoTeamAdministrator {
    <#
    .SYNOPSIS
        Promotes an existing Team member to Team administrator.

    .DESCRIPTION
        There is no public REST route for Team administrators. The portal uses the
        internal _api/_identity/AddTeamAdmins endpoint, which is what this function
        calls; it is pinned to the api-version that endpoint accepts. Being
        internal, it can change without notice - so it is isolated in one function
        with this note attached, rather than spread across call sites.

        The subject must already be a member of the Team; call Add-AdoTeamMember
        first. Creating a Team does not make the caller its administrator, which is
        why provisioning a Team normally ends with this call.

    .PARAMETER Context
        Connection context from Get-AdoContext. The project comes from the context,
        so this function takes no project parameter.

    .PARAMETER TeamId
        Identifier of the Team.

    .PARAMETER UserId
        Identifier of the user to promote.

    .EXAMPLE
        Set-AdoTeamAdministrator -Context $context -TeamId $team.id -UserId $user.id
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $TeamId,
        [Parameter(Mandatory)] [string] $UserId
    )

    if (-not $PSCmdlet.ShouldProcess($UserId, "Grant Team administrator on $TeamId")) { return }

    $uri = New-AdoUri -Context $Context -Path '_api/_identity/AddTeamAdmins' -IncludeProject -ApiVersion '5.1-preview.1'
    Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{
        teamId            = $TeamId
        newUsersJson      = '[]'
        existingUsersJson = (ConvertTo-Json -InputObject @($UserId) -Compress)
    } | Out-Null
}

function Get-AdoSecurityGroup {
    <#
    .SYNOPSIS
        Lists the project-scoped security groups.

    .DESCRIPTION
        A plain security group is not a Team: it has no Board, no Area Path and no
        work-tracking settings, so creating or renaming one has no side effects on
        Work Items. That makes groups the right vehicle for approval membership,
        where a Team would drag a Board along with it.

        The Graph groups collection pages with a continuation token, so the read
        goes through Invoke-AdoRestPaged.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .EXAMPLE
        Get-AdoSecurityGroup -Context $context -Project $project
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project
    )

    $projectDescriptor = Get-AdoGraphDescriptor -Context $Context -StorageKey $Project.id
    $uri = New-AdoUri -Context $Context -Path '_apis/graph/groups' -Service Identity `
        -ApiVersion '7.1-preview.1' -Query @{ scopeDescriptor = $projectDescriptor }

    $groups = Invoke-AdoRestPaged -Context $Context -Uri $uri
    return @($groups | Select-Object descriptor, displayName, description)
}

function New-AdoSecurityGroup {
    <#
    .SYNOPSIS
        Creates a project-scoped security group.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER DisplayName
        Group name.

    .PARAMETER Description
        Group description.

    .EXAMPLE
        New-AdoSecurityGroup -Context $context -Project $project -DisplayName 'APP_ALPHA_PROD_Approvers' -Description 'Production approvers for APP_ALPHA'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [string] $DisplayName,
        [string] $Description = ''
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create security group')) { return }

    $projectDescriptor = Get-AdoGraphDescriptor -Context $Context -StorageKey $Project.id
    $uri = New-AdoUri -Context $Context -Path '_apis/graph/groups' -Service Identity `
        -ApiVersion '7.1-preview.1' -Query @{ scopeDescriptor = $projectDescriptor }

    return Invoke-AdoRest -Context $Context -Method Post -Uri $uri -Body @{
        displayName = $DisplayName
        description = $Description
    }
}

function Rename-AdoSecurityGroup {
    <#
    .SYNOPSIS
        Renames a security group, preserving its descriptor and membership.

    .DESCRIPTION
        The Graph group endpoint is the one PATCH in this repository that requires
        JSON Patch (RFC 6902) rather than a plain JSON document. Sending an object
        body returns a 400 whose message does not mention the content type, which
        is why the requirement is stated here.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER GroupDescriptor
        Descriptor of the group to rename.

    .PARAMETER NewDisplayName
        New group name.

    .EXAMPLE
        Rename-AdoSecurityGroup -Context $context -GroupDescriptor $group.descriptor -NewDisplayName 'APP_ALPHA_PROD_Approvers'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $GroupDescriptor,
        [Parameter(Mandatory)] [string] $NewDisplayName
    )

    if (-not $PSCmdlet.ShouldProcess($GroupDescriptor, "Rename security group to '$NewDisplayName'")) { return }

    $uri = New-AdoUri -Context $Context -Path "_apis/graph/groups/$([Uri]::EscapeDataString($GroupDescriptor))" `
        -Service Identity -ApiVersion '7.1-preview.1'
    $patch = @(
        @{ op = 'replace'; path = '/displayName'; value = $NewDisplayName }
    )

    return Invoke-AdoRest -Context $Context -Method Patch -Uri $uri -Body $patch -ContentType 'application/json-patch+json'
}

Export-ModuleMember -Function @(
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
