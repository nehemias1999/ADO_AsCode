<#
    Ado.Rest - transport layer for the Azure DevOps REST API.

    This module is the only place in the repository that knows how to build an
    Azure DevOps URL, authenticate a request, retry a transient failure and turn
    an HTTP error into a message a human can act on. Everything above it works
    with a context object and a resource path.

    Design rules for this module:

    * No domain knowledge. It knows nothing about Teams, Boards, Variable Groups
      or Service Connections. Adding an "if this is a board" branch here is a
      design error - that belongs in the domain module above.
    * No console output on the success path. Callers decide what to report.
    * Never surface a credential. Error text passes through Remove-SecretFromText
      before it leaves the module.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Default API version for the classic (dev.azure.com) surface. Individual calls
# override it where Microsoft only ships a preview route.
$script:DefaultApiVersion = '7.1'

# Transient HTTP status codes. 429 is throttling; the 5xx set is Azure DevOps
# shedding load. Anything else is a real answer and must not be retried, because
# retrying a 400 or a 409 only multiplies the damage.
$script:RetryableStatusCodes = @(408, 429, 500, 502, 503, 504)

# Methods that may be retried. A retry is only safe when repeating the request cannot
# create a second resource, and POST creates. A 502 or 504 from a gateway AFTER the
# server committed, followed by a retry, produces a duplicate Team, group, Variable
# Group or Service Connection - and a duplicate is precisely the condition this
# repository treats as blocking elsewhere (Ado.Identity, Ado.Library). So the retry that
# was meant to add resilience manufactured the one state the design refuses to guess
# about.
$script:IdempotentMethods = @('Get', 'Put', 'Delete')

# Upper bound on an honoured Retry-After. Without it, a server or an intercepting proxy
# answering 'Retry-After: 999999' parks the run in Start-Sleep for eleven days.
$script:MaximumRetryDelaySeconds = 120

# Upper bound on a single request. Azure DevOps answers well inside this; the point
# is that an unresponsive endpoint cannot park an apply forever.
$script:RequestTimeoutSeconds = 100

# Hosts the Personal Access Token may be sent to without an explicit opt-in. The
# PAT is attached to every request as a Basic authorization header, so this list is
# the answer to "who can receive it".
$script:DefaultAllowedHosts = @('dev.azure.com', 'vssps.dev.azure.com', 'vsaex.dev.azure.com')

# Azure DevOps Services also answers on the legacy per-organization domain. Matched as
# an anchored pattern rather than with EndsWith: a suffix test also accepted
# 'anything.delegated.contoso.visualstudio.com', so one delegated label under a legacy
# organization's zone named a host this repository would hand the token to. One label,
# optionally its vssps or vsaex twin, and nothing else.
$script:AllowedHostPatterns = @('(?i)^[a-z0-9][a-z0-9-]{0,61}\.(?:vssps\.|vsaex\.)?visualstudio\.com$')

# Organization hosts whose identity and Graph endpoints are served by a sibling host
# rather than by the organization host itself.
$script:IdentityHostBySourceHost = @{
    'dev.azure.com'       = 'vssps.dev.azure.com'
    'vsaex.dev.azure.com' = 'vssps.dev.azure.com'
    'vssps.dev.azure.com' = 'vssps.dev.azure.com'
}

function Assert-AdoOrganizationUrl {
    <#
    .SYNOPSIS
        Validates an organization URL before a credential is aimed at it, and
        returns it normalized.

    .DESCRIPTION
        The organization URL is lower-trust than the token: it arrives from a `.env`
        file or a pipeline parameter, while the token comes from a secret store. So
        the URL decides where the token goes, and it has to be checked.

        Two rules, both of which were missing:

        1. The scheme must be https. Over http the PAT crosses the network as
           base64 in a Basic header, which is not encryption.
        2. The host must be one this repository is willing to send a credential to.
           Without a host check, only the last path segment was inspected, so
           `https://attacker.example/dev.azure.com/contoso` was accepted and
           resolved to organization `contoso` - and every Core request went to
           `attacker.example` carrying the token, while the Identity requests went
           to the real service, so the run partly succeeded and looked legitimate.

        Azure DevOps Server (on-premises) does not use these host names, so
        -AllowedHost extends the list. It is a parameter rather than a config field
        because the decision to trust a host with a credential belongs at the call
        site, where it is visible in a diff.

    .PARAMETER OrganizationUrl
        The URL to validate.

    .PARAMETER AllowedHost
        Additional host names permitted to receive the credential, for Azure DevOps
        Server. Matched exactly, case-insensitively.

    .EXAMPLE
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://dev.azure.com/contoso'

    .EXAMPLE
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://tfs.onprem.example/tfs/DefaultCollection' -AllowedHost 'tfs.onprem.example'

    .OUTPUTS
        The URL with any trailing slash removed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $OrganizationUrl,
        [string[]] $AllowedHost
    )

    $normalizedUrl = $OrganizationUrl.TrimEnd('/')

    $uri = $null
    if (-not [Uri]::TryCreate($normalizedUrl, [UriKind]::Absolute, [ref] $uri)) {
        throw "The organization URL '$normalizedUrl' is not an absolute URL. Expected the form https://dev.azure.com/<organization>."
    }

    if ($uri.Scheme -ne 'https') {
        throw "The organization URL '$normalizedUrl' does not use https. The Personal Access Token is sent as a Basic authorization header, so an http URL puts it on the network in clear text."
    }

    $permitted = @($script:DefaultAllowedHosts)
    if ($AllowedHost) { $permitted += @($AllowedHost) }

    $isPermitted = $permitted -contains $uri.Host
    if (-not $isPermitted) {
        foreach ($pattern in $script:AllowedHostPatterns) {
            if ($uri.Host -match $pattern) {
                $isPermitted = $true
                break
            }
        }
    }

    if (-not $isPermitted) {
        throw ("The organization URL '$normalizedUrl' names host '$($uri.Host)', which is not a host this repository sends a credential to. " +
            "Permitted: $($permitted -join ', '), or <organization>.visualstudio.com. " +
            'For Azure DevOps Server, pass -AllowedHost explicitly.')
    }

    return $normalizedUrl
}


function Get-AdoIdentityUrl {
    <#
    .SYNOPSIS
        Derives the base URL serving the identity and Graph endpoints for an
        organization URL.

    .DESCRIPTION
        The identity host used to be a literal - 'https://vssps.dev.azure.com/<org>' -
        whatever the organization URL said. For Azure DevOps Services that literal is
        correct. For Azure DevOps Server it is not, and the failure mode is a credential
        disclosure rather than a failed run: the token of an on-premises collection was
        attached to a request aimed at Microsoft's cloud, and the run still partly
        succeeded because the Core calls went to the right place. That is the scenario
        Assert-AdoOrganizationUrl exists to prevent, reached from the other side.

        Three cases, in order:

        1. A known Services host maps to its vssps sibling, keeping the organization
           segment. This is the behaviour that was correct all along.
        2. The legacy per-organization domain answers on <org>.vssps.visualstudio.com.
           Identity and Graph are ACCOUNT scoped there, so the collection segment of the
           organization URL is not part of the route.
        3. Anything else - which, after Assert-AdoOrganizationUrl, means a host the
           caller named explicitly with -AllowedHost - is Azure DevOps Server, where
           there is no vssps host at all: '_apis/identities' and '_apis/graph' are served
           by the collection. The URL is returned unchanged. Never invent a host to send
           a credential to.

    .PARAMETER OrganizationUrl
        Organization URL, already validated by Assert-AdoOrganizationUrl.

    .EXAMPLE
        Get-AdoIdentityUrl -OrganizationUrl 'https://dev.azure.com/contoso'

        Returns 'https://vssps.dev.azure.com/contoso'.

    .EXAMPLE
        Get-AdoIdentityUrl -OrganizationUrl 'https://tfs.onprem.example/tfs/DefaultCollection'

        Returns the same URL: an on-premises collection serves its own identity routes.

    .OUTPUTS
        The identity base URL, with no trailing slash.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $OrganizationUrl
    )

    $normalizedUrl = $OrganizationUrl.TrimEnd('/')

    $uri = $null
    if (-not [Uri]::TryCreate($normalizedUrl, [UriKind]::Absolute, [ref] $uri)) {
        throw "Cannot derive an identity URL from '$normalizedUrl': it is not an absolute URL."
    }

    $sourceHost = $uri.Host.ToLowerInvariant()
    if ($script:IdentityHostBySourceHost.ContainsKey($sourceHost)) {
        return ('https://{0}{1}' -f $script:IdentityHostBySourceHost[$sourceHost], $uri.AbsolutePath.TrimEnd('/'))
    }

    if ($sourceHost -match '(?i)^([a-z0-9][a-z0-9-]{0,61})\.(?:vssps\.|vsaex\.)?visualstudio\.com$') {
        return "https://$($Matches[1]).vssps.visualstudio.com"
    }

    return $normalizedUrl
}


function Remove-SecretFromText {
    <#
    .SYNOPSIS
        Masks credential material in a string before it is logged or thrown.

    .DESCRIPTION
        Applied to every error message this module produces. An exception raised
        deep inside Invoke-RestMethod can echo request details, and a masked
        message is worth more than a rule that says "be careful what you log".

    .PARAMETER Text
        Text to sanitize. A null or empty value is returned unchanged.

    .EXAMPLE
        Remove-SecretFromText -Text 'Authorization: Basic Zm9vOmJhcg=='

        Returns 'Authorization: Basic ***'.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $sanitized = $Text
    $sanitized = [regex]::Replace($sanitized, '(?i)(Basic|Bearer)\s+[A-Za-z0-9+/=_\-\.]{8,}', '$1 ***')
    $sanitized = [regex]::Replace($sanitized, '(?i)(pat|token|password|secret)(["'']?\s*[:=]\s*["'']?)[^\s"'',;}]{6,}', '$1$2***')
    return $sanitized
}

function Get-AdoContext {
    <#
    .SYNOPSIS
        Builds the connection context every other call in the repository takes.

    .DESCRIPTION
        Resolves the organization URL, the project name and the Personal Access
        Token, and pre-computes the Basic authentication header. The context is a
        plain object with no methods so it can be constructed by hand in a test.

        The project context file declares the NAME of each environment variable
        rather than its value, so a configuration file never carries a secret and
        the same file works on a workstation and on a build agent.

    .PARAMETER ProjectContext
        Parsed project-context configuration. Its `organizationUrlEnv` and
        `projectEnv` properties name the environment variables to read.

    .PARAMETER OrganizationUrl
        Explicit organization URL, overriding the environment. Intended for tests
        and for one-off runs against a second organization.

    .PARAMETER Project
        Explicit project name, overriding the environment.

    .PARAMETER PersonalAccessToken
        Explicit token, overriding the ADO_PAT environment variable.

    .PARAMETER AllowedHost
        Additional host names the Personal Access Token may be sent to, for Azure
        DevOps Server. Azure DevOps Services hosts are permitted by default; see
        Assert-AdoOrganizationUrl.

    .EXAMPLE
        $context = Get-AdoContext -ProjectContext $projectContext

        Reads ADO_ORG_URL, ADO_PROJECT and ADO_PAT from the process environment.

    .OUTPUTS
        PSCustomObject with OrganizationUrl, OrganizationName, IdentityUrl,
        ProjectName, Headers and DefaultApiVersion.
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromEnvironment')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'FromEnvironment')]
        [object] $ProjectContext,

        [Parameter(ParameterSetName = 'Explicit', Mandatory)]
        [string] $OrganizationUrl,

        [Parameter(ParameterSetName = 'Explicit', Mandatory)]
        [string] $Project,

        [Parameter(ParameterSetName = 'Explicit', Mandatory)]
        [string] $PersonalAccessToken,

        [string[]] $AllowedHost
    )

    if ($PSCmdlet.ParameterSetName -eq 'FromEnvironment') {
        $organizationUrlVariable = 'ADO_ORG_URL'
        $projectVariable = 'ADO_PROJECT'
        if ($ProjectContext) {
            if ($ProjectContext.PSObject.Properties.Name -contains 'organizationUrlEnv') {
                $organizationUrlVariable = "$($ProjectContext.organizationUrlEnv)"
            }
            if ($ProjectContext.PSObject.Properties.Name -contains 'projectEnv') {
                $projectVariable = "$($ProjectContext.projectEnv)"
            }
        }

        $OrganizationUrl = Get-RequiredEnvironmentVariable -Name $organizationUrlVariable
        $Project = Get-RequiredEnvironmentVariable -Name $projectVariable
        $PersonalAccessToken = Get-RequiredEnvironmentVariable -Name 'ADO_PAT'
    }

    $normalizedUrl = Assert-AdoOrganizationUrl -OrganizationUrl $OrganizationUrl -AllowedHost $AllowedHost

    # The legacy domain names the organization in the subdomain; the path segment there
    # is the collection. Reading the last segment produced 'DefaultCollection' as an
    # organization name, which was then pasted into a hardcoded identity URL.
    if ($normalizedUrl -match '(?i)^https://([a-z0-9][a-z0-9-]{0,61})\.(?:vssps\.|vsaex\.)?visualstudio\.com(?:/|$)') {
        $organizationName = $Matches[1]
    }
    else {
        $organizationName = ([Uri]$normalizedUrl).Segments[-1].Trim('/')
    }
    if ([string]::IsNullOrWhiteSpace($organizationName)) {
        throw "The organization URL '$normalizedUrl' does not end in an organization name. Expected the form https://dev.azure.com/<organization>."
    }

    # A host allowlist cannot answer "which organization": every organization on
    # dev.azure.com shares one permitted host, so a mistyped or tampered ADO_ORG_URL
    # pointing at somebody else's organization passes every check above and receives
    # the token. Naming the expected organization is what closes that, and it is opt-in
    # by presence so no existing configuration changes behaviour. Per ADR 0003 the
    # configuration declares the NAME of the variable; the value stays out of Git,
    # because an organization name is itself on the deny list.
    if ($PSCmdlet.ParameterSetName -eq 'FromEnvironment' -and $ProjectContext -and
        $ProjectContext.PSObject.Properties.Name -contains 'expectedOrganizationEnv') {

        $expectedVariable = "$($ProjectContext.expectedOrganizationEnv)"
        $expected = [Environment]::GetEnvironmentVariable($expectedVariable, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($expected) -and $expected -ne $organizationName) {
            throw ("The organization URL '$normalizedUrl' resolves to organization '$organizationName', but $expectedVariable declares '$expected'. " +
                'Refusing to send the Personal Access Token to an organization the configuration does not expect.')
        }
    }

    # Azure DevOps accepts a PAT as the password of Basic authentication with an
    # empty user name.
    $encodedToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PersonalAccessToken"))

    [pscustomobject]@{
        OrganizationUrl   = $normalizedUrl
        OrganizationName  = $organizationName
        IdentityUrl       = (Get-AdoIdentityUrl -OrganizationUrl $normalizedUrl)
        ProjectName       = $Project
        DefaultApiVersion = $script:DefaultApiVersion
        Headers           = @{
            Authorization = "Basic $encodedToken"
            Accept        = 'application/json'
        }
    }
}

function Get-RequiredEnvironmentVariable {
    <#
    .SYNOPSIS
        Reads a process environment variable and fails with a usable message when
        it is missing.

    .PARAMETER Name
        Variable name.

    .EXAMPLE
        Get-RequiredEnvironmentVariable -Name 'ADO_PAT'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable '$Name' is not set. Add it to your .env file (see .env.example) or to the pipeline secret variables."
    }
    return $value
}

function New-AdoUri {
    <#
    .SYNOPSIS
        Builds a fully qualified Azure DevOps URL with the api-version applied.

    .DESCRIPTION
        Centralising URL construction keeps percent-encoding correct - project and
        team names contain spaces - and keeps the api-version out of the call
        sites, where a stale literal is easy to miss.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Path
        Resource path with no leading slash, for example '_apis/projects'.

    .PARAMETER Service
        'Core' targets the organization URL; 'Identity' targets the context's
        IdentityUrl, which serves the Graph and identity endpoints. Both are derived
        from the same validated organization URL, so there is no second host the token
        can reach. For Azure DevOps Services the identity host is vssps.dev.azure.com;
        on-premises it is the collection itself.

    .PARAMETER IncludeProject
        Inserts the encoded project name between the organization and the path.

    .PARAMETER TeamName
        Inserts an encoded team name after the project. Team-scoped work endpoints
        require it in the route rather than in the query string.

    .PARAMETER ApiVersion
        Overrides the context default. Preview routes need their exact version.

    .PARAMETER Query
        Extra query string values, added before api-version.

    .EXAMPLE
        New-AdoUri -Context $context -Path '_apis/work/boards' -IncludeProject -TeamName 'APP_ALPHA_Team'
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Core', 'Identity')] [string] $Service = 'Core',
        [switch] $IncludeProject,
        [string] $TeamName,
        [string] $ApiVersion,
        [hashtable] $Query
    )

    if (-not $ApiVersion) { $ApiVersion = $Context.DefaultApiVersion }

    if ($Service -eq 'Identity') {
        # Read from the context, never derived here. A context built by hand that
        # reaches this line is a caller who bypassed Get-AdoContext, and the old
        # behaviour for that caller was to aim the Basic header at
        # vssps.dev.azure.com regardless of where the organization actually was -
        # which for an on-premises token is a disclosure, not a failed request.
        # Refusing is the only safe default.
        if ($Context.PSObject.Properties.Name -notcontains 'IdentityUrl' -or
            [string]::IsNullOrWhiteSpace($Context.IdentityUrl)) {
            throw 'The connection context carries no IdentityUrl. Build it with Get-AdoContext, which derives the identity host from the organization URL.'
        }
        $baseUri = $Context.IdentityUrl
    }
    else {
        $baseUri = $Context.OrganizationUrl
    }

    if ($IncludeProject) {
        $baseUri += '/' + [Uri]::EscapeDataString($Context.ProjectName)
    }
    if ($TeamName) {
        $baseUri += '/' + [Uri]::EscapeDataString($TeamName)
    }

    $uri = "$baseUri/$($Path.TrimStart('/'))"

    $queryParts = New-Object System.Collections.Generic.List[string]
    if ($Query) {
        foreach ($key in $Query.Keys) {
            if ($null -eq $Query[$key]) { continue }
            $queryParts.Add(('{0}={1}' -f [Uri]::EscapeDataString("$key"), [Uri]::EscapeDataString("$($Query[$key])")))
        }
    }
    $queryParts.Add("api-version=$ApiVersion")

    return "$uri`?$($queryParts -join '&')"
}

function New-AdoRequestParameter {
    <#
    .SYNOPSIS
        Builds the splat passed to Invoke-RestMethod for one Azure DevOps request.

    .DESCRIPTION
        A pure function, so the two protections that are easy to omit and invisible
        when missing can be asserted by a test rather than trusted.

        MaximumRedirection is 0. Windows PowerShell 5.1 - the support floor declared
        in this module's manifest - forwards caller-supplied headers verbatim across
        a redirect, including a cross-origin one, and offers no
        -PreserveAuthorizationOnRedirect to turn that off. So any 3xx, from a captive
        portal or a misconfigured gateway, would receive the Basic header carrying the
        PAT. A redirect is not an expected answer from this API, so refusing to follow
        one costs nothing and closes the replay.

        TimeoutSec is bounded. Without it a single request has no upper bound, and an
        unresponsive endpoint parks an apply with no way to observe why.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Method
        HTTP method.

    .PARAMETER Uri
        Fully qualified request URI.

    .PARAMETER Body
        Object to serialize as the request body. Omit for a request without one.

    .PARAMETER ContentType
        Content type for the body.

    .EXAMPLE
        New-AdoRequestParameter -Context $context -Method Get -Uri $uri

    .OUTPUTS
        Hashtable, ready to splat onto Invoke-RestMethod.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body,
        [string] $ContentType = 'application/json'
    )

    $parameters = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $Context.Headers
        MaximumRedirection = 0
        TimeoutSec         = $script:RequestTimeoutSeconds
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 20
        $parameters.ContentType = $ContentType
        # Encoding the body explicitly avoids the mojibake that appears when a
        # non-ASCII name is sent with the default encoding of Invoke-RestMethod.
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }

    return $parameters
}

function Get-AdoRetryDecision {
    <#
    .SYNOPSIS
        Decides whether a failed request may be retried, and after how long.

    .DESCRIPTION
        A pure function over (method, status, Retry-After, attempt), so the policy can
        be asserted rather than inferred from reading the loop. Three rules, each of
        which was wrong before this function existed:

        1. Only GET, PUT and DELETE are retried. POST creates, so a 502 arriving after
           the server committed, followed by a retry, produces a duplicate - the exact
           condition the rest of the codebase treats as blocking.
        2. A failure with NO status is retried. DNS failures, TLS resets and timeouts
           carry no HTTP status and are the most transient failures there are; they
           were the ones excluded, while 500 was retried.
        3. An honoured Retry-After is capped. 'Retry-After: 999999' otherwise parks the
           run for eleven days.

    .PARAMETER Method
        HTTP method of the failed request.

    .PARAMETER StatusCode
        HTTP status, or $null for a transport-level failure.

    .PARAMETER RetryAfterSeconds
        Seconds requested by the service, or 0 when it did not ask.

    .PARAMETER Attempt
        1-based attempt number that just failed.

    .PARAMETER MaximumAttempts
        Total attempts allowed.

    .EXAMPLE
        Get-AdoRetryDecision -Method Get -StatusCode 429 -RetryAfterSeconds 5 -Attempt 1 -MaximumAttempts 4

    .OUTPUTS
        PSCustomObject with ShouldRetry, DelaySeconds and Reason.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')] [string] $Method,
        [AllowNull()] [System.Nullable[int]] $StatusCode,
        [int] $RetryAfterSeconds = 0,
        [Parameter(Mandatory)] [int] $Attempt,
        [Parameter(Mandatory)] [int] $MaximumAttempts
    )

    $isIdempotent = $script:IdempotentMethods -contains $Method
    $isTransport = $null -eq $StatusCode
    $isRetryableStatus = $isTransport -or ($script:RetryableStatusCodes -contains $StatusCode)
    $isLastAttempt = $Attempt -ge $MaximumAttempts

    $delaySeconds = [int][Math]::Pow(2, $Attempt - 1)
    if ($RetryAfterSeconds -gt 0) { $delaySeconds = $RetryAfterSeconds }
    $delaySeconds = [int][Math]::Min($delaySeconds, $script:MaximumRetryDelaySeconds)

    $reason = ''
    if (-not $isRetryableStatus) { $reason = "HTTP $StatusCode is a real answer, not a transient failure." }
    elseif (-not $isIdempotent) { $reason = "$Method is not retried: repeating it could create a duplicate." }
    elseif ($isLastAttempt) { $reason = "Attempt $Attempt of $MaximumAttempts was the last." }

    return [pscustomobject]@{
        ShouldRetry  = ($isRetryableStatus -and $isIdempotent -and -not $isLastAttempt)
        DelaySeconds = $delaySeconds
        Reason       = $reason
    }
}

function Invoke-AdoRest {
    <#
    .SYNOPSIS
        Sends one request to the Azure DevOps REST API.

    .DESCRIPTION
        Serializes the body as UTF-8 JSON, retries transient failures with
        exponential backoff, and converts an HTTP error into an exception whose
        message names the method, the status code and the service response.

        Depth 20 on the JSON conversion is deliberate: board column payloads and
        variable group project references nest deeply enough that the default
        depth of 2 silently truncates them into the string "System.Object[]".

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Method
        HTTP method.

    .PARAMETER Uri
        Absolute request URI, normally built with New-AdoUri.

    .PARAMETER Body
        Object to serialize as the request body. Omit for GET and DELETE.

    .PARAMETER ContentType
        Request content type. The Graph group endpoints require
        'application/json-patch+json' for a PATCH; everything else uses JSON.

    .PARAMETER MaximumAttempts
        Total attempts, including the first. 1 disables retrying.

    .PARAMETER AllowNotFound
        Returns $null on HTTP 404 instead of throwing. Absence is a normal answer
        when a plan is discovering what does not exist yet, and callers should not
        have to inspect exception text to tell "missing" from "broken".

    .EXAMPLE
        Invoke-AdoRest -Context $context -Method Get -Uri $uri

    .EXAMPLE
        $node = Invoke-AdoRest -Context $context -Method Get -Uri $uri -AllowNotFound

        Returns $null when the classification node has not been created yet.

    .OUTPUTS
        The deserialized response body, or $null when -AllowNotFound absorbed a 404.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body,
        [string] $ContentType = 'application/json',
        [ValidateRange(1, 10)] [int] $MaximumAttempts = 4,
        [switch] $AllowNotFound
    )

    $requestArguments = @{ Context = $Context; Method = $Method; Uri = $Uri; ContentType = $ContentType }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) { $requestArguments.Body = $Body }
    $parameters = New-AdoRequestParameter @requestArguments

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            $statusCode = Get-AdoErrorStatusCode -ErrorRecord $_
            if ($AllowNotFound -and $statusCode -eq 404) { return $null }

            $decision = Get-AdoRetryDecision -Method $Method -StatusCode $statusCode `
                -RetryAfterSeconds (Get-AdoRetryAfterSeconds -ErrorRecord $_) `
                -Attempt $attempt -MaximumAttempts $MaximumAttempts

            if ($decision.ShouldRetry) {
                Write-Verbose "Azure DevOps returned $statusCode for $Method $Uri. Retrying in $($decision.DelaySeconds) second(s) (attempt $attempt of $MaximumAttempts)."
                Start-Sleep -Seconds $decision.DelaySeconds
                continue
            }

            $detail = Get-AdoErrorDetail -ErrorRecord $_
            $statusText = if ($null -eq $statusCode) { 'no status' } else { "HTTP $statusCode" }

            # Say so explicitly. Otherwise a transient failure on a POST looks like a
            # hard failure, and the operator has no way to know a retry was declined
            # deliberately rather than not attempted.
            $note = ''
            if ($decision.Reason -like '*could create a duplicate*') {
                $note = " $($decision.Reason) Re-run the command - the plan is computed from live state, so an operation that already succeeded will show as ok."
            }
            throw (Remove-SecretFromText -Text "Azure DevOps request failed: $Method $Uri returned $statusText. $detail$note")
        }
    }
}

function Invoke-AdoRestPaged {
    <#
    .SYNOPSIS
        Retrieves every page of a continuation-token paged collection.

    .DESCRIPTION
        Several Azure DevOps collections - Graph groups in particular - page with
        an X-MS-ContinuationToken response header rather than a skip/top pair.
        Invoke-RestMethod discards response headers, so this function uses
        Invoke-WebRequest and deserializes the body itself.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .PARAMETER Uri
        First page URI. The continuation token is appended to it.

    .EXAMPLE
        Invoke-AdoRestPaged -Context $context -Uri $groupsUri

    .OUTPUTS
        The concatenated `value` arrays of every page.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Uri
    )

    $items = New-Object System.Collections.Generic.List[object]
    $continuationToken = $null

    do {
        $pageUri = $Uri
        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $separator = if ($pageUri.Contains('?')) { '&' } else { '?' }
            $pageUri = "$pageUri$separator" + 'continuationToken=' + [Uri]::EscapeDataString($continuationToken)
        }

        try {
            # -MaximumRedirection 0 and -TimeoutSec for the same reasons as in
            # Invoke-AdoRest: this call carries the same Basic header.
            $response = Invoke-WebRequest -Method Get -Uri $pageUri -Headers $Context.Headers -UseBasicParsing `
                -MaximumRedirection 0 -TimeoutSec $script:RequestTimeoutSeconds
        }
        catch {
            $detail = Get-AdoErrorDetail -ErrorRecord $_
            throw (Remove-SecretFromText -Text "Azure DevOps paged request failed: GET $pageUri. $detail")
        }

        $page = $response.Content | ConvertFrom-Json
        if ($page.PSObject.Properties.Name -contains 'value') {
            $items.AddRange(@($page.value))
        }

        $continuationToken = $null
        if ($response.Headers -and $response.Headers['X-MS-ContinuationToken']) {
            $continuationToken = @($response.Headers['X-MS-ContinuationToken'])[0]
        }
    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    return @($items.ToArray())
}

function Get-AdoErrorStatusCode {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from a failed web request, or $null.

    .PARAMETER ErrorRecord
        Error record caught around Invoke-RestMethod or Invoke-WebRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $response = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response') {
        $response = $ErrorRecord.Exception.Response
    }
    if (-not $response) { return $null }
    if (-not ($response.PSObject.Properties.Name -contains 'StatusCode')) { return $null }
    if ($null -eq $response.StatusCode) { return $null }

    try { return [int] $response.StatusCode } catch { return $null }
}

function Get-AdoRetryAfterSeconds {
    <#
    .SYNOPSIS
        Reads the Retry-After hint from a throttled response, or 0 when absent.

    .PARAMETER ErrorRecord
        Error record caught around a failed request.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    try {
        $response = $ErrorRecord.Exception.Response
        if (-not $response) { return 0 }
        $headers = $response.Headers
        if (-not $headers) { return 0 }
        $value = $null
        if ($headers -is [System.Net.WebHeaderCollection]) {
            $value = $headers['Retry-After']
        }
        elseif ($headers.PSObject.Properties.Name -contains 'RetryAfter') {
            $value = "$($headers.RetryAfter)"
        }
        if ([string]::IsNullOrWhiteSpace("$value")) { return 0 }
        return [int] "$value"
    }
    catch {
        return 0
    }
}

function Get-AdoErrorDetail {
    <#
    .SYNOPSIS
        Returns the service-supplied error message, falling back to the exception.

    .DESCRIPTION
        Azure DevOps puts the useful part of a failure in the response body, in a
        `message` property. Without reading it the caller only sees "The remote
        server returned an error: (400) Bad Request", which never explains what
        was wrong with the payload.

    .PARAMETER ErrorRecord
        Error record caught around a failed request.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    # PowerShell 7 exposes the already-read body; 5.1 requires draining the stream.
    if ($ErrorRecord.PSObject.Properties.Name -contains 'ErrorDetails' -and $ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $raw = $ErrorRecord.ErrorDetails.Message
    }
    else {
        $raw = $null
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $raw = $reader.ReadToEnd()
                $reader.Dispose()
            }
        }
        catch {
            $raw = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "$($ErrorRecord.Exception.Message)"
    }

    try {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains 'message' -and $parsed.message) {
            return "$($parsed.message)"
        }
    }
    catch {
        # Not JSON. That is normal for a gateway error or an HTML sign-in page, so
        # fall through and return the raw text rather than losing it.
        Write-Verbose "Error body was not JSON: $($_.Exception.Message)"
    }

    if ($raw.Length -gt 600) { return $raw.Substring(0, 600) + '...' }
    return $raw
}

function Get-AdoProject {
    <#
    .SYNOPSIS
        Retrieves the team project named by the context.

    .DESCRIPTION
        Every automation calls this first: it proves the organization URL, the
        project name and the token all work together before any plan is computed,
        and it returns the project id that the rest of the endpoints need.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .EXAMPLE
        $project = Get-AdoProject -Context $context
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context
    )

    $uri = New-AdoUri -Context $Context -Path "_apis/projects/$([Uri]::EscapeDataString($Context.ProjectName))"
    return Invoke-AdoRest -Context $Context -Method Get -Uri $uri
}

function Get-AdoAuthenticatedUser {
    <#
    .SYNOPSIS
        Returns the identity behind the Personal Access Token.

    .DESCRIPTION
        Used to record who applied a change and to promote that identity to team
        administrator. The connection data endpoint is preview-only, which is why
        the api-version is pinned here rather than inherited.

    .PARAMETER Context
        Connection context from Get-AdoContext.

    .EXAMPLE
        (Get-AdoAuthenticatedUser -Context $context).authenticatedUser.providerDisplayName
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context
    )

    $uri = New-AdoUri -Context $Context -Path '_apis/connectionData' -ApiVersion '7.1-preview.1'
    return Invoke-AdoRest -Context $Context -Method Get -Uri $uri
}

Export-ModuleMember -Function @(
    'Assert-AdoOrganizationUrl',
    'Get-AdoIdentityUrl',
    'Get-AdoContext',
    'Get-RequiredEnvironmentVariable',
    'New-AdoUri',
    'Get-AdoRetryDecision',
    'New-AdoRequestParameter',
    'Invoke-AdoRest',
    'Invoke-AdoRestPaged',
    'Get-AdoProject',
    'Get-AdoAuthenticatedUser',
    'Remove-SecretFromText'
)
