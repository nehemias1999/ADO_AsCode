<#
.SYNOPSIS
    Creates SSH/SFTP Service Connections from a declaration, without ever
    overwriting a credential that already exists.

.DESCRIPTION
    Service Connections are the sharpest edge in the Azure DevOps API, and this
    module is shaped almost entirely by one fact: a GET never returns the stored
    credential, and the only update route is a full-object PUT. Round-tripping a
    connection therefore sends a null credential over whatever the owner configured.

    Three consequences, all deliberate:

    * A connection that does not exist is created, with the configuration sentinel
      as its password when no credential is available locally. The owner completes it
      in the portal.
    * A connection that already exists is reported as `protected` and left alone.
      Overwriting it needs BOTH -ForceUpdate and -ForceCredentialOverwrite, so nobody
      arrives there by habit.
    * A rename is never automated. It is reported as manual work, because the API
      offers no partial update and the portal does. That is not a gap in this module;
      it is the correct answer, and the guide says so in the same words.

    Command ladder:

      validate   Offline. Declaration against its schema, plus the credential
                 variable names it derives.
      inventory  Read-only list of the declared connections and what exists.
      plan       Classifies each declared connection.
      smoke      Plan plus the manual verification checklist.
      apply      Creates the missing connections. Requires -ConfirmApply.

.PARAMETER Command
    Operation to run.

.PARAMETER ApplicationKey
    Restrict the run to one application.

.PARAMETER Environment
    Restrict the run to one environment.

.PARAMETER EnvFile
    Environment files to load, comma or list separated.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ConfigurationPath
    Override for the connections declaration.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/.

.PARAMETER ConfirmApply
    Required by apply. Without it, apply is a pure simulation.

.PARAMETER ForceUpdate
    Allow updating a connection that already exists. Must be combined with
    -ForceCredentialOverwrite.

.PARAMETER ForceCredentialOverwrite
    Acknowledges that a full PUT replaces the stored credential with whatever this
    run can supply, and that Azure DevOps will not give the old value back.

.EXAMPLE
    .\Invoke-ServiceConnectionProvisioning.ps1 -Command validate

    Checks the declaration offline, with no credentials.

.EXAMPLE
    .\Invoke-ServiceConnectionProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA

    Shows which connections are missing and which are protected.

.EXAMPLE
    .\Invoke-ServiceConnectionProvisioning.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply

    Creates the missing connection for one application in one environment.

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
    [string] $ConfigurationPath,
    [string] $ReportPath,

    [switch] $ConfirmApply,
    [switch] $ForceUpdate,
    [switch] $ForceCredentialOverwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleName = 'service-connection-provisioning'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path

. (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

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

function Expand-NamePattern {
    <#
    .SYNOPSIS
        Substitutes {application} and {environment} in a pattern.

    .PARAMETER Pattern
        Pattern to expand.

    .PARAMETER Application
        Application key.

    .PARAMETER Environment
        Environment suffix.

    .EXAMPLE
        Expand-NamePattern -Pattern 'SFTP_{application}_{environment}' -Application 'APP_ALPHA' -Environment 'DEV'
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

function Get-DeclaredConnection {
    <#
    .SYNOPSIS
        Expands the declaration into one entry per application and environment.

    .DESCRIPTION
        Every name in the entry - the connection name and each credential variable
        name - is derived from the same two values, so a connection and the variable
        that fills it cannot drift apart. That matters because the failure mode of a
        mismatch is silent: the connection is created with the sentinel and the
        deployment fails at run time with an authentication error that points at the
        host, not at the naming.

        Pure function.

    .PARAMETER Configuration
        Parsed connections declaration.

    .EXAMPLE
        Get-DeclaredConnection -Configuration $configuration

    .OUTPUTS
        One object per declared connection.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object] $Configuration)

    $defaultPort = 22
    $descriptionPattern = 'Managed as code.'
    $grantAll = $false
    if ($Configuration.PSObject.Properties.Name -contains 'defaults') {
        if ($Configuration.defaults.PSObject.Properties.Name -contains 'port') { $defaultPort = [int]$Configuration.defaults.port }
        if ($Configuration.defaults.PSObject.Properties.Name -contains 'description') { $descriptionPattern = "$($Configuration.defaults.description)" }
        if ($Configuration.defaults.PSObject.Properties.Name -contains 'grantAccessToAllPipelines') { $grantAll = [bool]$Configuration.defaults.grantAccessToAllPipelines }
    }

    $variables = $Configuration.credentialVariables
    $declared = New-Object System.Collections.ArrayList

    foreach ($application in @($Configuration.applications)) {
        $key = "$($application.key)"
        $port = $defaultPort
        if ($application.PSObject.Properties.Name -contains 'port') { $port = [int]$application.port }

        foreach ($environment in @($application.environments)) {
            $entry = [ordered]@{
                application               = $key
                environment               = "$environment"
                name                      = Expand-NamePattern -Pattern "$($Configuration.namePattern)" -Application $key -Environment "$environment"
                port                      = $port
                grantAccessToAllPipelines = $grantAll
                description               = Expand-NamePattern -Pattern $descriptionPattern -Application $key -Environment "$environment"
                hostEnv                   = Expand-NamePattern -Pattern "$($variables.hostEnv)" -Application $key -Environment "$environment"
                usernameEnv               = Expand-NamePattern -Pattern "$($variables.usernameEnv)" -Application $key -Environment "$environment"
                passwordEnv               = $null
                privateKeyEnv             = $null
            }
            if ($variables.PSObject.Properties.Name -contains 'passwordEnv') {
                $entry.passwordEnv = Expand-NamePattern -Pattern "$($variables.passwordEnv)" -Application $key -Environment "$environment"
            }
            if ($variables.PSObject.Properties.Name -contains 'privateKeyEnv') {
                $entry.privateKeyEnv = Expand-NamePattern -Pattern "$($variables.privateKeyEnv)" -Application $key -Environment "$environment"
            }

            $declared.Add([pscustomobject]$entry) | Out-Null
        }
    }

    return @($declared.ToArray())
}

function Get-ConnectionCredential {
    <#
    .SYNOPSIS
        Resolves what this session actually knows about one connection's credential.

    .DESCRIPTION
        Reports which pieces are available without ever returning or logging the
        values themselves - the plan says "a password is available", never what it is.

    .PARAMETER Connection
        A declared connection entry.

    .EXAMPLE
        Get-ConnectionCredential -Connection $connection

    .OUTPUTS
        PSCustomObject with the resolved values and booleans describing what is known.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [object] $Connection)

    function Get-Value([string] $Name) {
        if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
        return [Environment]::GetEnvironmentVariable($Name, 'Process')
    }

    $serverHost = Get-Value $Connection.hostEnv
    $username = Get-Value $Connection.usernameEnv
    $password = Get-Value $Connection.passwordEnv
    $privateKey = Get-Value $Connection.privateKeyEnv

    return [pscustomobject]@{
        ServerHost    = $serverHost
        Username      = $username
        Password      = $password
        PrivateKey    = $privateKey
        HasHost       = -not [string]::IsNullOrWhiteSpace($serverHost)
        HasUsername   = -not [string]::IsNullOrWhiteSpace($username)
        HasPassword   = -not [string]::IsNullOrWhiteSpace($password)
        HasPrivateKey = -not [string]::IsNullOrWhiteSpace($privateKey)
    }
}

function New-ServiceConnectionPlan {
    <#
    .SYNOPSIS
        Builds the plan for the declared connections.

    .DESCRIPTION
        The interesting classification is not "missing or present" but what happens to
        an existing one. Present means `protected`: not updated, because a full PUT
        would replace a credential this automation cannot read. Only the two force
        switches together turn that into a pending update, and the reason text spells
        out what will be sent.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Declared
        Declared connections from Get-DeclaredConnection.

    .PARAMETER Sentinel
        The configuration sentinel.

    .PARAMETER Force
        Both force switches were supplied.

    .PARAMETER CommandName
        Command being planned.

    .EXAMPLE
        New-ServiceConnectionPlan -Context $context -Declared $declared -Sentinel $sentinel -CommandName plan

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
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Declared,
        [Parameter(Mandatory)] [string] $Sentinel,
        [switch] $Force,
        [Parameter(Mandatory)] [string] $CommandName
    )

    $plan = New-Plan -Command $CommandName -Target (@($Declared | ForEach-Object { $_.name }) -join ',')
    $existing = @(Get-AdoServiceEndpoint -Context $Context)

    foreach ($connection in $Declared) {
        $status = Get-AdoServiceEndpointStatus -Name $connection.name -ExistingEndpoint $existing -Force:$Force
        Add-PlanOperation -Plan $plan -Resource 'Service Connection' -Name $connection.name -Status $status

        if ($status.action -ne 'create' -and -not $Force) { continue }

        # What the credential will actually be, stated before anything is written.
        $credential = Get-ConnectionCredential -Connection $connection

        if (-not $credential.HasHost) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection host' -Name $connection.name `
                -Action 'resolve' -Status 'blocked' `
                -Reason "No value for '$($connection.hostEnv)'. A connection needs a real host; there is no sensible placeholder for one.")
        }
        else {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection host' -Name $connection.name `
                -Action 'validate' -Status 'ok' -Reason "Host and port $($connection.port) resolved from '$($connection.hostEnv)'.")
        }

        if (-not $credential.HasUsername) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection user' -Name $connection.name `
                -Action 'resolve' -Status 'blocked' `
                -Reason "No value for '$($connection.usernameEnv)'. The user name is not secret and has to be declared.")
        }
        else {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection user' -Name $connection.name `
                -Action 'validate' -Status 'ok' -Reason "User name resolved from '$($connection.usernameEnv)'.")
        }

        if ($credential.HasPrivateKey) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection credential' -Name $connection.name `
                -Action 'set' -Status 'pending' -Reason "A private key is available in '$($connection.privateKeyEnv)' and will be used instead of a password.")
        }
        elseif ($credential.HasPassword) {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection credential' -Name $connection.name `
                -Action 'set' -Status 'pending' -Reason "A password is available in '$($connection.passwordEnv)' and will be used.")
        }
        else {
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Connection credential' -Name $connection.name `
                -Action 'manual' -Status 'warning' `
                -Reason "No credential is available in this session, so the connection is created with '$Sentinel' as its password. Whoever holds the credential completes it in the portal, and no later run will overwrite it.")
        }
    }

    return $plan
}

function Invoke-ServiceConnectionApply {
    <#
    .SYNOPSIS
        Creates the connections the plan marked as pending.

    .DESCRIPTION
        Only creation. Updating an existing connection is refused unless both force
        switches were supplied, and even then it is a delete-and-recreate in the
        portal's terms - which is why the guide recommends doing it there.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Project
        Project object from Get-AdoProject.

    .PARAMETER Declared
        Declared connections.

    .PARAMETER Sentinel
        The configuration sentinel.

    .PARAMETER ReceiptPath
        Where to write the incremental receipt.

    .EXAMPLE
        Invoke-ServiceConnectionApply -Context $context -Project $project -Declared $declared -Sentinel $sentinel -ReceiptPath $receiptPath

    .OUTPUTS
        The completed operations.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Project,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Declared,
        [Parameter(Mandatory)] [string] $Sentinel,
        [Parameter(Mandatory)] [string] $ReceiptPath
    )

    $completed = New-Object System.Collections.ArrayList
    $targetLabel = (@($Declared | ForEach-Object { $_.name }) -join ',')

    try {
        $existing = @(Get-AdoServiceEndpoint -Context $Context)

        foreach ($connection in $Declared) {
            if (@($existing | Where-Object { "$($_.name)" -eq $connection.name }).Count -gt 0) {
                Write-ModuleLog "'$($connection.name)' already exists and is not modified."
                continue
            }

            $credential = Get-ConnectionCredential -Connection $connection
            $arguments = @{
                Context     = $Context
                Project     = $Project
                Name        = $connection.name
                ServerHost  = $credential.ServerHost
                Port        = [int]$connection.port
                Username    = $credential.Username
                Description = $connection.description
                Sentinel    = $Sentinel
            }
            if ($credential.HasPrivateKey) { $arguments.PrivateKey = $credential.PrivateKey }
            elseif ($credential.HasPassword) { $arguments.Password = $credential.Password }

            New-AdoSshServiceEndpoint @arguments | Out-Null

            $credentialKind = if ($credential.HasPrivateKey) { 'private key' } elseif ($credential.HasPassword) { 'password' } else { "the '$Sentinel' placeholder" }
            $completed.Add([pscustomobject]@{
                resource = 'Service Connection'
                name     = $connection.name
                action   = 'create'
                detail   = "Created on port $($connection.port) using $credentialKind."
            }) | Out-Null

            Save-AdoAsCodeReceipt -Path $ReceiptPath -Target $targetLabel -Status 'in_progress' -CompletedOperations @($completed.ToArray())
            Write-ModuleLog "created '$($connection.name)' using $credentialKind"
        }

        Save-AdoAsCodeReceipt -Path $ReceiptPath -Target $targetLabel -Status 'completed' `
            -CompletedOperations @($completed.ToArray()) -Message "Created $($completed.Count) connection(s)."
    }
    catch {
        Save-AdoAsCodeReceipt -Path $ReceiptPath -Target $targetLabel -Status 'failed' `
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

if (-not $ConfigurationPath) {
    $activePath = Resolve-AdoAsCodePath -Path "$($automationPaths.configuration)" -RootPath $repoRoot
    $templatePath = Resolve-AdoAsCodePath -Path "$($automationPaths.template)" -RootPath $repoRoot
    $ConfigurationPath = if (Test-Path -LiteralPath $activePath) { $activePath } else { $templatePath }
}

$configuration = Get-AdoAsCodeConfiguration -Path $ConfigurationPath
$declared = @(Get-DeclaredConnection -Configuration $configuration)

if ($ApplicationKey) {
    $declared = @($declared | Where-Object { $_.application -eq $ApplicationKey })
    if ($declared.Count -eq 0) { throw "Application '$ApplicationKey' declares no connection." }
}
if ($Environment) {
    $declared = @($declared | Where-Object { $_.environment -eq $Environment })
    if ($declared.Count -eq 0) { throw "No connection is declared for environment '$Environment'." }
}

if ($Command -eq 'validate') {
    Write-ModuleLog "Configuration: $ConfigurationPath"

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($declared | Group-Object name | Where-Object { $_.Count -gt 1 })) {
        $problems.Add("connection name '$($group.Name)' is derived $($group.Count) times; two applications would collide")
    }
    foreach ($connection in $declared) {
        foreach ($variableProperty in @('hostEnv', 'usernameEnv')) {
            if ([string]::IsNullOrWhiteSpace("$($connection.$variableProperty)")) {
                $problems.Add("$($connection.name): $variableProperty resolved to an empty variable name")
            }
        }
    }

    if ($problems.Count -gt 0) {
        $detail = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "The declaration is not coherent:$([Environment]::NewLine)$detail"
    }

    Write-ModuleLog "Valid. $($declared.Count) connection(s) declared across $(@($configuration.applications).Count) application(s)."
    Write-ModuleLog 'Credential variables expected in the environment:'
    foreach ($connection in $declared) {
        $names = @($connection.hostEnv, $connection.usernameEnv, $connection.passwordEnv, $connection.privateKeyEnv) | Where-Object { $_ }
        Write-ModuleLog "  $($connection.name): $($names -join ', ')"
    }
    Write-ModuleLog 'No network call was made and no credential was read.'
    return
}

Import-AdoAsCodeEnvironment -Path $EnvFile | Out-Null
$context = Get-AdoContext -ProjectContext $projectContext
$project = Get-AdoProject -Context $context
Write-ModuleLog "Connected to '$($context.OrganizationUrl)' project '$($project.name)'."

if ($ForceUpdate -and -not $ForceCredentialOverwrite) {
    throw '-ForceUpdate requires -ForceCredentialOverwrite. Updating an existing connection sends the whole object, so the stored credential is replaced by whatever this run can supply - and Azure DevOps will not give the old value back. Acknowledge that explicitly, or make the change in the portal.'
}
$force = $ForceUpdate.IsPresent -and $ForceCredentialOverwrite.IsPresent

if (-not $ReportPath) {
    $suffix = if ($ApplicationKey -and $Environment) { "-$ApplicationKey-$Environment" } elseif ($ApplicationKey) { "-$ApplicationKey" } else { '' }
    $ReportPath = Join-Path $repoRoot "artifacts/reports/$moduleName-$Command$suffix.json"
}

if ($Command -eq 'inventory') {
    $existing = @(Get-AdoServiceEndpoint -Context $context)
    $plan = New-Plan -Command 'inventory' -Target (@($declared | ForEach-Object { $_.name }) -join ',')

    foreach ($connection in $declared) {
        $match = @($existing | Where-Object { "$($_.name)" -eq $connection.name })
        $reason = if ($match.Count -eq 0) { 'Absent.' } else { "Present; type '$($match[0].type)', ready=$($match[0].isReady). The stored credential is never returned by the API, so its validity cannot be checked from here." }
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Service Connection' -Name $connection.name `
            -Action 'validate' -Status 'ok' -Reason $reason)
    }

    Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
    Write-PlanSummary -Plan $plan
    Write-ModuleLog "Report: $ReportPath"
    return $plan
}

$plan = New-ServiceConnectionPlan -Context $context -Declared $declared -Sentinel $sentinel -Force:$force -CommandName $Command
Write-PlanSummary -Plan $plan

switch ($Command) {
    'plan' {
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
        Write-ModuleLog "Report: $ReportPath"
    }

    'smoke' {
        $checklist = @(
            [pscustomobject]@{ step = 1; check = 'Project settings > Service connections lists every declared connection.' }
            [pscustomobject]@{ step = 2; check = "Each connection whose credential shows '$sentinel' has been handed to its owner to complete." }
            [pscustomobject]@{ step = 3; check = 'Use "Verify" in the portal on one connection per environment. This automation cannot verify a credential it is not allowed to read.' }
            [pscustomobject]@{ step = 4; check = 'Each connection grants access only to the pipelines that need it. None should be open to all pipelines.' }
            [pscustomobject]@{ step = 5; check = 'Re-run plan. Existing connections should read as protected, and nothing as pending.' }
        )
        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName `
            -Detail ([pscustomobject]@{ manualVerification = $checklist }) | Out-Null

        Write-ModuleLog 'Manual verification checklist:'
        foreach ($item in $checklist) { Write-ModuleLog "  $($item.step). $($item.check)" }
        Write-ModuleLog "Report: $ReportPath"
    }

    default {
        if (-not $ConfirmApply) {
            Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName | Out-Null
            Write-ModuleLog 'Simulation only: apply requires -ConfirmApply. Nothing was modified.'
            Write-ModuleLog "Report: $ReportPath"
            return $plan
        }

        Assert-PlanApplicable -Plan $plan

        $receiptPath = Get-AdoAsCodeReceiptPath -ReportPath $ReportPath
        $completed = @(Invoke-ServiceConnectionApply -Context $context -Project $project -Declared $declared `
            -Sentinel $sentinel -ReceiptPath $receiptPath)

        Write-AdoAsCodeReport -Plan $plan -Path $ReportPath -Module $moduleName `
            -Detail ([pscustomobject]@{ appliedOperations = $completed }) | Out-Null

        Write-ModuleLog "apply complete: $($completed.Count) connection(s) created."
        Write-ModuleLog "Report: $ReportPath"
        Write-ModuleLog "Receipt: $receiptPath"
        Write-ModuleLog "Hand any connection still showing '$sentinel' to whoever holds the credential. No later run will overwrite what they set."
    }
}

return $plan
