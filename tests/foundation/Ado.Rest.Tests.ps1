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
        # the Basic header. The Identity base URI is hardcoded to the real service,
        # so the run partly succeeded and looked legitimate.
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://attacker.example/dev.azure.com/contoso' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
    }

    It 'refuses a look-alike host built by suffixing the real one' {
        { Assert-AdoOrganizationUrl -OrganizationUrl 'https://dev.azure.com.attacker.example/contoso' } |
            Should -Throw -ExpectedMessage '*not a host this repository sends a credential to*'
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
