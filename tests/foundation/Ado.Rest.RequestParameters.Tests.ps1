<#
    Request-level protections that are invisible when they are missing.

    A request without -MaximumRedirection 0 or without -TimeoutSec behaves normally
    against a healthy service. The first only matters when something answers 3xx, the
    second only when something stops answering - so neither shows up in manual testing,
    and both are credential- or availability-affecting. That combination is exactly what
    a test is for.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

    # A hand-built context, which is possible because Get-AdoContext returns a plain
    # object with no methods. The token is a fixture.
    $script:context = [pscustomobject]@{
        OrganizationUrl   = 'https://dev.azure.com/contoso'
        OrganizationName  = 'contoso'
        ProjectName       = 'Platform'
        DefaultApiVersion = '7.1'
        Headers           = @{ Authorization = 'Basic Zml4dHVyZQ=='; Accept = 'application/json' }
    }
    $script:uri = 'https://dev.azure.com/contoso/Platform/_apis/projects?api-version=7.1'
}

Describe 'New-AdoRequestParameter' {

    It 'never follows a redirect while carrying the credential' {
        # Windows PowerShell 5.1 forwards caller-supplied headers verbatim across a
        # redirect, cross-origin included, and has no
        # -PreserveAuthorizationOnRedirect. So a 3xx from a captive portal or a
        # misconfigured gateway would be handed the PAT.
        $parameters = New-AdoRequestParameter -Context $script:context -Method Get -Uri $script:uri

        $parameters.ContainsKey('MaximumRedirection') | Should -BeTrue
        $parameters.MaximumRedirection | Should -Be 0
    }

    It 'bounds every request with a timeout' {
        $parameters = New-AdoRequestParameter -Context $script:context -Method Get -Uri $script:uri

        $parameters.ContainsKey('TimeoutSec') | Should -BeTrue
        $parameters.TimeoutSec | Should -BeGreaterThan 0
    }

    It 'applies both protections to a request that carries a body' {
        # Asserted separately because the body branch is where a future edit is most
        # likely to rebuild the hashtable and drop them.
        $parameters = New-AdoRequestParameter -Context $script:context -Method Post -Uri $script:uri `
            -Body @{ name = 'APP_TEST' }

        $parameters.MaximumRedirection | Should -Be 0
        $parameters.TimeoutSec | Should -BeGreaterThan 0
    }

    It 'carries the context headers through unchanged' {
        $parameters = New-AdoRequestParameter -Context $script:context -Method Get -Uri $script:uri

        $parameters.Headers.Authorization | Should -Be $script:context.Headers.Authorization
        $parameters.Headers.Accept | Should -Be 'application/json'
    }

    It 'omits the body and content type when there is no body' {
        $parameters = New-AdoRequestParameter -Context $script:context -Method Get -Uri $script:uri

        $parameters.ContainsKey('Body') | Should -BeFalse
        $parameters.ContainsKey('ContentType') | Should -BeFalse
    }

    It 'encodes the body as UTF-8 bytes rather than a string' {
        # A non-ASCII name sent with the default encoding arrives as mojibake, and the
        # symptom appears in Azure DevOps rather than here.
        #
        # The accented character is built from its code point rather than typed, so
        # this file stays ASCII. Every other file in the repository is UTF-8 without a
        # BOM (.editorconfig: charset = utf-8), and PSScriptAnalyzer's
        # PSUseBOMForUnicodeEncodedFile would flag a literal here - adding a BOM to one
        # file to satisfy it would break the convention instead.
        $accented = "Presupuestaci$([char]0xF3)n"

        $parameters = New-AdoRequestParameter -Context $script:context -Method Post -Uri $script:uri `
            -Body @{ name = "Equipo Alfa - $accented" }

        $parameters.Body -is [byte[]] | Should -BeTrue
        $parameters.ContentType | Should -Be 'application/json'
        [Text.Encoding]::UTF8.GetString($parameters.Body) | Should -BeLike "*$accented*"
    }
}
