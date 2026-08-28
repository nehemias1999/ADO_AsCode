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
$script:RetryableStatusCodes = @(429, 500, 502, 503, 504)

# Upper bound on a single request. Azure DevOps answers well inside this; the point
# is that an unresponsive endpoint cannot park an apply forever.
$script:RequestTimeoutSeconds = 100

# Hosts the Personal Access Token may be sent to without an explicit opt-in. The
# PAT is attached to every request as a Basic authorization header, so this list is
# the answer to "who can receive it".
$script:DefaultAllowedHosts = @('dev.azure.com', 'vssps.dev.azure.com', 'vsaex.dev.azure.com')

# Azure DevOps Services also answers on the legacy per-organization domain.
$script:AllowedHostSuffixes = @('.visualstudio.com')

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
        foreach ($suffix in $script:AllowedHostSuffixes) {
            if ($uri.Host.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $isPermitted = $true
                break
            }
        }
    }

    if (-not $isPermitted) {
        throw ("The organization URL '$normalizedUrl' names host '$($uri.Host)', which is not a host this repository sends a credential to. " +
            "Permitted: $($permitted -join ', '), or any *$($script:AllowedHostSuffixes -join ', *'). " +
            'For Azure DevOps Server, pass -AllowedHost explicitly.')
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
        PSCustomObject with OrganizationUrl, OrganizationName, ProjectName,
        Headers and DefaultApiVersion.
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
    $organizationName = ([Uri]$normalizedUrl).Segments[-1].Trim('/')
    if ([string]::IsNullOrWhiteSpace($organizationName)) {
        throw "The organization URL '$normalizedUrl' does not end in an organization name. Expected the form https://dev.azure.com/<organization>."
    }

    # Azure DevOps accepts a PAT as the password of Basic authentication with an
    # empty user name.
    $encodedToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PersonalAccessToken"))

    [pscustomobject]@{
        OrganizationUrl   = $normalizedUrl
        OrganizationName  = $organizationName
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
        'Core' targets dev.azure.com; 'Identity' targets vssps.dev.azure.com,
        which serves the Graph and identity endpoints.

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
        $baseUri = "https://vssps.dev.azure.com/$($Context.OrganizationName)"
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

            $isLastAttempt = $attempt -ge $MaximumAttempts
            $isRetryable = $null -ne $statusCode -and ($script:RetryableStatusCodes -contains $statusCode)

            if ($isRetryable -and -not $isLastAttempt) {
                $delaySeconds = [Math]::Pow(2, $attempt - 1)
                $retryAfter = Get-AdoRetryAfterSeconds -ErrorRecord $_
                if ($retryAfter -gt 0) { $delaySeconds = $retryAfter }
                Write-Verbose "Azure DevOps returned $statusCode for $Method $Uri. Retrying in $delaySeconds second(s) (attempt $attempt of $MaximumAttempts)."
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            $detail = Get-AdoErrorDetail -ErrorRecord $_
            $statusText = if ($null -eq $statusCode) { 'no status' } else { "HTTP $statusCode" }
            throw (Remove-SecretFromText -Text "Azure DevOps request failed: $Method $Uri returned $statusText. $detail")
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
    'Get-AdoContext',
    'Get-RequiredEnvironmentVariable',
    'New-AdoUri',
    'New-AdoRequestParameter',
    'Invoke-AdoRest',
    'Invoke-AdoRestPaged',
    'Get-AdoProject',
    'Get-AdoAuthenticatedUser',
    'Remove-SecretFromText'
)
