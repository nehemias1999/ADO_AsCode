<#
    Transport-layer safety.

    Ado.Rest had no tests. The justification on record - docs/process/testing-strategy.md
    - is that the HTTP layer needs a live service, and that is true of Invoke-RestMethod
    itself. It is not true of the parts that decide WHERE a credential is sent and
    WHETHER it is masked, which are pure functions over their inputs and are exactly the
    parts whose failure is a credential disclosure rather than a failed run.

    Every URL here uses a .example or .invalid host, both reserved by RFC 2606 and
    therefore unresolvable, so nothing in this file can accidentally address a real
    service.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
}

Describe 'Assert-AdoOrganizationUrl' {

    It 'accepts the Azure DevOps Services form' {
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://dev.azure.com/contoso' |
            Should -Be 'https://dev.azure.com/contoso'
    }

    It 'removes a trailing slash' {
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://dev.azure.com/contoso/' |
            Should -Be 'https://dev.azure.com/contoso'
    }

    It 'accepts the legacy per-organization domain' {
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://contoso.visualstudio.com/DefaultCollection' |
            Should -Not -BeNullOrEmpty
    }

    It 'refuses http, because the token would cross the network in clear text' {
        # A PAT in a Basic header is base64, not encryption.
        { Assert-AdoOrganizationUrl -OrganizationUrl 'http://dev.azure.com/contoso' } |
            Should -Throw -ExpectedMessage '*does not use https*'
    }

    It 'refuses a host that merely contains the real one in its path' {
        # The finding this function exists for. Validation used to inspect only the
        # last path segment, so this URL was accepted and resolved to organization
        # 'contoso' - while every Core request went to the attacker's host carrying
        # the Basic header. The Identity base URI pointed at the real service, so the
        # run partly succeeded and looked legitimate. (That hardcoded identity host
        # was itself the mirror-image disclosure; see Get-AdoIdentityUrl below.)
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://attacker.example/dev.azure.com/contoso' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'refuses a look-alike host built by suffixing the real one' {
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://dev.azure.com.attacker.example/contoso' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'refuses a delegated label under a legacy organization zone' {
        # The suffix test accepted anything ending in .visualstudio.com, so one
        # delegated label under a legacy organization's zone named a host this
        # repository would hand the token to. Anchored to a single label now.
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://anything.delegated.contoso.visualstudio.com/x' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'still accepts the legacy vssps twin' {
        Assert-AdoOrganizationUrl -OrganizationUrl 'https://contoso.vssps.visualstudio.com' |
            Should -Be 'https://contoso.vssps.visualstudio.com'
    }

    It 'refuses a look-alike of the legacy domain' {
        # EndsWith on '.visualstudio.com' must not be satisfied by a host that only
        # contains it.
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://contoso.visualstudio.com.attacker.example/x' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'refuses a relative URL' {
        { Assert-AdoOrganizationUrl -OrganizationUrl 'dev.azure.com/contoso' } |
            Should -Throw -ExpectedMessage '*not an absolute URL*'
    }

    It 'permits an on-premises host only when it is named explicitly' {
        $url = 'https://tfs.onprem.example/tfs/DefaultCollection'

        { Assert-AdoOrganizationUrl -OrganizationUrl $url } | Should -Throw
        Assert-AdoOrganizationUrl -OrganizationUrl $url -AllowedHost 'tfs.onprem.example' | Should -Be $url
    }

    It 'names the offending host in the error, so the message is actionable' {
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://attacker.example/contoso' } |
            Should -Throw -ExpectedMessage '*attacker.example*'
    }
}

Describe 'Get-AdoContext' {

    It 'refuses to build a context around an untrusted host' {
        # The check has to sit in Get-AdoContext, not only in the helper: this is the
        # one function every automation calls before its first request.
        { Get-AdoContext -OrganizationUrl 'https://attacker.example/dev.azure.com/contoso' `
                -Project 'Platform' -PersonalAccessToken 'fixture' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'derives the organization name from the last path segment' {
        $context = Get-AdoContext -OrganizationUrl 'https://dev.azure.com/contoso' `
            -Project 'Platform' -PersonalAccessToken 'fixture'

        $context.OrganizationName | Should -Be 'contoso'
        $context.ProjectName | Should -Be 'Platform'
    }

    It 'builds a Basic header with an empty user name' {
        # Azure DevOps accepts the PAT as the password with no user name. Asserted
        # because a wrong encoding here is a bare 401 with no hint as to why.
        $token = 'fixture'
        $context = Get-AdoContext -OrganizationUrl 'https://dev.azure.com/contoso' `
            -Project 'Platform' -PersonalAccessToken $token

        $context.Headers.Authorization | Should -BeLike 'Basic *'
        $encoded = $context.Headers.Authorization.Substring('Basic '.Length)
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | Should -Be ":$token"
    }
}

Describe 'Remove-SecretFromText' {

    It 'masks a Basic authorization header' {
        # The control docs/process/risk-register.md credits for keeping credentials
        # out of error text. It had no test.
        $masked = Remove-SecretFromText -Text 'Authorization: Basic Zm9vOmJhcnBhc3N3b3Jk'

        $masked | Should -Be 'Authorization: Basic ***'
    }

    It 'masks a credential-shaped assignment' {
        $masked = Remove-SecretFromText -Text 'password=hunter2hunter2'

        $masked | Should -Not -BeLike '*hunter2hunter2*'
    }

    It 'returns an empty or null value unchanged' {
        Remove-SecretFromText -Text '' | Should -Be ''
        Remove-SecretFromText -Text $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-AdoRetryDecision' {

    It 'retries a throttled GET' {
        $d = Get-AdoRetryDecision -Method Get -StatusCode 429 -Attempt 1 -MaximumAttempts 4
        $d.ShouldRetry | Should -BeTrue
    }

    It 'never retries a POST, however transient the failure looks' {
        # POST creates. A 502 from a gateway AFTER the server committed, followed by a
        # retry, produces a duplicate Team, group, Variable Group or Service Connection
        # - and a duplicate is precisely what Ado.Identity and Ado.Library treat as a
        # blocking condition. The retry meant to add resilience manufactured the one
        # state the design refuses to guess about.
        foreach ($status in @(429, 500, 502, 503, 504, 408)) {
            $d = Get-AdoRetryDecision -Method Post -StatusCode $status -Attempt 1 -MaximumAttempts 4
            $d.ShouldRetry | Should -BeFalse -Because "POST must not be retried on $status"
            $d.Reason | Should -BeLike '*could create a duplicate*'
        }
    }

    It 'does not retry PATCH either' {
        # Not idempotent in general, and nothing here needs it retried.
        $d = Get-AdoRetryDecision -Method Patch -StatusCode 503 -Attempt 1 -MaximumAttempts 4
        $d.ShouldRetry | Should -BeFalse
    }

    It 'retries a transport failure that carries no status' {
        # DNS failure, TLS reset, connection reset, timeout. These are the MOST
        # transient failures there are, and they were the ones excluded - while 500,
        # which may well have committed server-side, was retried. Risk profile
        # inverted.
        $d = Get-AdoRetryDecision -Method Get -StatusCode $null -Attempt 1 -MaximumAttempts 4
        $d.ShouldRetry | Should -BeTrue
    }

    It 'does not retry a real answer' {
        foreach ($status in @(400, 401, 403, 404, 409, 422)) {
            $d = Get-AdoRetryDecision -Method Get -StatusCode $status -Attempt 1 -MaximumAttempts 4
            $d.ShouldRetry | Should -BeFalse -Because "HTTP $status is an answer, not a failure to repeat"
        }
    }

    It 'retries 408, which was missing from the set' {
        $d = Get-AdoRetryDecision -Method Get -StatusCode 408 -Attempt 1 -MaximumAttempts 4
        $d.ShouldRetry | Should -BeTrue
    }

    It 'stops on the last attempt' {
        $d = Get-AdoRetryDecision -Method Get -StatusCode 503 -Attempt 4 -MaximumAttempts 4
        $d.ShouldRetry | Should -BeFalse
        $d.Reason | Should -BeLike '*was the last*'
    }

    It 'backs off exponentially when the service does not say otherwise' {
        (Get-AdoRetryDecision -Method Get -StatusCode 503 -Attempt 1 -MaximumAttempts 4).DelaySeconds | Should -Be 1
        (Get-AdoRetryDecision -Method Get -StatusCode 503 -Attempt 2 -MaximumAttempts 4).DelaySeconds | Should -Be 2
        (Get-AdoRetryDecision -Method Get -StatusCode 503 -Attempt 3 -MaximumAttempts 4).DelaySeconds | Should -Be 4
    }

    It 'honours Retry-After over its own backoff' {
        $d = Get-AdoRetryDecision -Method Get -StatusCode 429 -RetryAfterSeconds 7 -Attempt 1 -MaximumAttempts 4
        $d.DelaySeconds | Should -Be 7
    }

    It 'caps Retry-After, so a hostile value cannot park the run' {
        # 'Retry-After: 999999' from a service or an intercepting proxy otherwise
        # sleeps for eleven days.
        $d = Get-AdoRetryDecision -Method Get -StatusCode 429 -RetryAfterSeconds 999999 -Attempt 1 -MaximumAttempts 4
        $d.DelaySeconds | Should -BeLessOrEqual 120
        $d.DelaySeconds | Should -BeGreaterThan 0
    }
}

Describe 'Get-AdoIdentityUrl' {

    It 'maps a Services organization to its vssps sibling' {
        # The behaviour that was correct all along, kept.
        Get-AdoIdentityUrl -OrganizationUrl 'https://dev.azure.com/contoso' |
            Should -Be 'https://vssps.dev.azure.com/contoso'
    }

    It 'reads the organization from the subdomain on the legacy domain' {
        # Identity and Graph are account scoped there, so the collection segment is
        # not part of the route. The old code pasted the LAST PATH SEGMENT into a
        # hardcoded host, producing https://vssps.dev.azure.com/DefaultCollection -
        # wrong host and wrong organization at once.
        $identityUrl = Get-AdoIdentityUrl -OrganizationUrl 'https://contoso.visualstudio.com/DefaultCollection'

        $identityUrl | Should -Be 'https://contoso.vssps.visualstudio.com'
        $identityUrl | Should -Not -BeLike '*DefaultCollection*'
    }

    It 'leaves an on-premises collection to serve its own identity routes' {
        # The regression test for the disclosure. An Azure DevOps Server collection has
        # no vssps host, and the old code aimed the Basic header carrying an
        # on-premises token at Microsoft's cloud - the exact scenario
        # Assert-AdoOrganizationUrl exists to prevent, reached from the other side.
        $identityUrl = Get-AdoIdentityUrl -OrganizationUrl 'https://tfs.onprem.example/tfs/DefaultCollection'

        $identityUrl | Should -Be 'https://tfs.onprem.example/tfs/DefaultCollection'
        $identityUrl | Should -Not -BeLike '*dev.azure.com*'
        $identityUrl | Should -Not -BeLike '*visualstudio.com*'
    }
}

Describe 'New-AdoUri and the identity host' {

    BeforeAll {
        $script:onPremContext = Get-AdoContext `
            -OrganizationUrl 'https://tfs.onprem.example/tfs/DefaultCollection' `
            -Project 'Platform' -PersonalAccessToken 'not-a-real-token' `
            -AllowedHost 'tfs.onprem.example'
    }

    It 'never sends an on-premises token to the Microsoft cloud' {
        # End to end: the context is built the way an entry point builds it, and the
        # identity request has to stay on the host the caller actually trusted.
        $uri = New-AdoUri -Context $script:onPremContext -Path '_apis/identities' -Service Identity

        ([Uri]$uri).Host | Should -Be 'tfs.onprem.example'
        $uri | Should -Not -BeLike '*dev.azure.com*'
    }

    It 'refuses a context that carries no identity host rather than guessing one' {
        # A hand-built context reaching this line is a caller who bypassed
        # Get-AdoContext. The old default for that caller was to aim the credential at
        # vssps.dev.azure.com regardless, which is a disclosure and not a failed call.
        $handBuilt = [pscustomobject]@{
            OrganizationUrl   = 'https://dev.azure.com/contoso'
            OrganizationName  = 'contoso'
            DefaultApiVersion = '7.1'
        }

        { New-AdoUri -Context $handBuilt -Path '_apis/identities' -Service Identity } |
            Should -Throw -ExpectedMessage '*carries no IdentityUrl*'
    }

    It 'still routes a Services organization to vssps' {
        $context = Get-AdoContext -OrganizationUrl 'https://dev.azure.com/contoso' `
            -Project 'Platform' -PersonalAccessToken 'not-a-real-token'

        New-AdoUri -Context $context -Path '_apis/identities' -Service Identity |
            Should -BeLike 'https://vssps.dev.azure.com/contoso/_apis/identities*'
    }
}

Describe 'Organization pinning' {

    AfterEach { [Environment]::SetEnvironmentVariable('ADO_EXPECTED_ORG', $null, 'Process') }

    It 'refuses an organization the configuration does not expect' {
        # A host allowlist cannot answer "which organization": every organization on
        # dev.azure.com shares one permitted host, so a mistyped or tampered
        # ADO_ORG_URL pointing at somebody else's organization passes every host check
        # and still receives the token.
        [Environment]::SetEnvironmentVariable('ADO_EXPECTED_ORG', 'contoso', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_ORG_URL', 'https://dev.azure.com/someone-else', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PROJECT', 'Platform', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PAT', 'not-a-real-token', 'Process')

        $projectContext = [pscustomobject]@{ expectedOrganizationEnv = 'ADO_EXPECTED_ORG' }

        { Get-AdoContext -ProjectContext $projectContext } |
            Should -Throw -ExpectedMessage "*does not expect*"
    }

    It 'accepts the organization the configuration names' {
        [Environment]::SetEnvironmentVariable('ADO_EXPECTED_ORG', 'contoso', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_ORG_URL', 'https://dev.azure.com/contoso', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PROJECT', 'Platform', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PAT', 'not-a-real-token', 'Process')

        $projectContext = [pscustomobject]@{ expectedOrganizationEnv = 'ADO_EXPECTED_ORG' }

        (Get-AdoContext -ProjectContext $projectContext).OrganizationName | Should -Be 'contoso'
    }

    It 'changes nothing when the variable is declared but unset' {
        # Opt-in by presence of a VALUE, so shipping the field breaks no existing run.
        [Environment]::SetEnvironmentVariable('ADO_ORG_URL', 'https://dev.azure.com/contoso', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PROJECT', 'Platform', 'Process')
        [Environment]::SetEnvironmentVariable('ADO_PAT', 'not-a-real-token', 'Process')

        $projectContext = [pscustomobject]@{ expectedOrganizationEnv = 'ADO_EXPECTED_ORG' }

        (Get-AdoContext -ProjectContext $projectContext).OrganizationName | Should -Be 'contoso'
    }
}
