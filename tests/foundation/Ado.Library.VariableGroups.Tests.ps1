<#
    Variable Group write safety.

    Every test here describes a way the obvious implementation destroys a credential.
    They are cheap to run and they cover behaviour that is expensive to discover in
    production, because a blanked secret is invisible until a pipeline fails.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
    # $script: so the value is visibly shared with the It blocks below, which run
    # in their own scope.
    $script:sentinel = Get-AdoConfigurationSentinel
}

Describe 'Get-AdoVariableGroupUpdate' {

    It 'fills a key that holds the sentinel' {
        $group = New-VariableGroupFixture -Variable @{ DEPLOY_PATH = @{ value = $script:sentinel; isSecret = $false } }

        $result = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ DEPLOY_PATH = '/srv/app' }

        @($result.updates).Count | Should -Be 1
        $result.updates[0].value | Should -Be '/srv/app'
    }

    It 'adds a key that does not exist' {
        $group = New-VariableGroupFixture -Variable @{ DEPLOY_PATH = @{ value = '/srv/app'; isSecret = $false } }

        $result = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ NEW_KEY = 'value' }

        @($result.updates).Count | Should -Be 1
        $result.updates[0].isNew | Should -BeTrue
    }

    It 'leaves a key that already holds a real value' {
        # The central rule. A value that is neither absent nor the sentinel was set
        # by somebody on purpose, and this automation fills blanks rather than
        # overruling decisions.
        $group = New-VariableGroupFixture -Variable @{ DEPLOY_PATH = @{ value = '/srv/chosen'; isSecret = $false } }

        $result = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ DEPLOY_PATH = '/srv/other' }

        @($result.updates).Count | Should -Be 0
    }

    It 'refuses to update a secret key' {
        $group = New-VariableGroupFixture -Variable @{ APP_PASSWORD = @{ value = $null; isSecret = $true } }

        $result = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ APP_PASSWORD = 'anything' }

        @($result.updates).Count | Should -Be 0
        ($result.blocked -join ' ') | Should -BeLike '*secret*'
    }

    It 'applies a forced correction only on an exact, case-sensitive match' {
        # Case sensitivity is deliberate: a nearly equal value has to reach a human,
        # not be overwritten.
        $group = New-VariableGroupFixture -Variable @{ CONNECTION = @{ value = 'SFTP_APP_OLD_DEV'; isSecret = $false } }

        $wrongCase = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{} `
            -Force @{ CONNECTION = @{ from = 'sftp_app_old_dev'; to = 'SFTP_APP_NEW_DEV' } }
        @($wrongCase.updates).Count | Should -Be 0

        $exact = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{} `
            -Force @{ CONNECTION = @{ from = 'SFTP_APP_OLD_DEV'; to = 'SFTP_APP_NEW_DEV' } }
        @($exact.updates).Count | Should -Be 1
        $exact.updates[0].value | Should -Be 'SFTP_APP_NEW_DEV'
    }

    It 'only adds absent keys under OnlyMissing' {
        $group = New-VariableGroupFixture -Variable @{ DEPLOY_PATH = @{ value = $script:sentinel; isSecret = $false } }

        $result = Get-AdoVariableGroupUpdate -VariableGroup $group -DesiredValue @{ DEPLOY_PATH = '/srv/app' } -OnlyMissing

        @($result.updates).Count | Should -Be 0
    }
}

Describe 'New-AdoVariableGroupPayload' {

    It 're-posts every secret with its resolved value' {
        # Not "omit the secret and let Azure DevOps keep it". An omitted value is
        # stored as an empty string, which deletes the credential.
        $group = New-VariableGroupFixture -Variable @{
            DEPLOY_PATH  = @{ value = '/srv/app'; isSecret = $false }
            APP_PASSWORD = @{ value = $null; isSecret = $true }
        }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group `
            -SetValue @{ DEPLOY_PATH = '/srv/new' } `
            -SecretSource @{ APP_PASSWORD = 'resolved-value' }

        @($payload.blocked).Count | Should -Be 0
        $payload.variables['APP_PASSWORD'].value | Should -Be 'resolved-value'
        $payload.variables['APP_PASSWORD'].isSecret | Should -BeTrue
        $payload.restoredSecrets | Should -Contain 'APP_PASSWORD'
    }

    It 'blocks when a secret has no known value' {
        $group = New-VariableGroupFixture -Variable @{
            DEPLOY_PATH  = @{ value = '/srv/app'; isSecret = $false }
            APP_PASSWORD = @{ value = $null; isSecret = $true }
        }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group -SetValue @{ DEPLOY_PATH = '/srv/new' } -SecretSource @{}

        @($payload.blocked).Count | Should -BeGreaterThan 0
        ($payload.blocked -join ' ') | Should -BeLike '*would blank it*'
    }

    It 'blocks when a resolved secret value is empty' {
        $group = New-VariableGroupFixture -Variable @{ APP_PASSWORD = @{ value = $null; isSecret = $true } }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group -SecretSource @{ APP_PASSWORD = '' }

        @($payload.blocked).Count | Should -BeGreaterThan 0
    }

    It 'refuses to set a secret by explicit value' {
        $group = New-VariableGroupFixture -Variable @{ APP_PASSWORD = @{ value = $null; isSecret = $true } }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group `
            -SetValue @{ APP_PASSWORD = 'nope' } -SecretSource @{ APP_PASSWORD = 'resolved' }

        ($payload.blocked -join ' ') | Should -BeLike '*cannot be set by explicit value*'
    }

    It 'carries every non-secret variable through untouched' {
        $group = New-VariableGroupFixture -Variable @{
            KEEP_ME     = @{ value = 'unchanged'; isSecret = $false }
            DEPLOY_PATH = @{ value = '/srv/app'; isSecret = $false }
        }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group -SetValue @{ DEPLOY_PATH = '/srv/new' } -SecretSource @{}

        $payload.variables['KEEP_ME'].value | Should -Be 'unchanged'
        $payload.variables['DEPLOY_PATH'].value | Should -Be '/srv/new'
    }

    It 'keeps the secret count identical' {
        $group = New-VariableGroupFixture -Variable @{
            FIRST_SECRET  = @{ value = $null; isSecret = $true }
            SECOND_SECRET = @{ value = $null; isSecret = $true }
        }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group `
            -SecretSource @{ FIRST_SECRET = 'a'; SECOND_SECRET = 'b' }

        $payload.secretCount | Should -Be 2
        @($payload.restoredSecrets).Count | Should -Be 2
        @($payload.variables.Keys | Where-Object { $payload.variables[$_].isSecret }).Count | Should -Be 2
    }

    It 'does nothing when the declared value is already in place' {
        $group = New-VariableGroupFixture -Variable @{ DEPLOY_PATH = @{ value = '/srv/app'; isSecret = $false } }

        $payload = New-AdoVariableGroupPayload -VariableGroup $group -SetValue @{ DEPLOY_PATH = '/srv/app' } -SecretSource @{}

        @($payload.applied).Count | Should -Be 0
    }
}

Describe 'Get-AdoServiceEndpointStatus' {

    It 'plans a create when the connection is absent' {
        $status = Get-AdoServiceEndpointStatus -Name 'SFTP_APP_TEST_DEV' -ExistingEndpoint @()

        $status.action | Should -Be 'create'
        $status.status | Should -Be 'pending'
    }

    It 'protects an existing connection instead of updating it' {
        $existing = @([pscustomobject]@{ name = 'SFTP_APP_TEST_DEV'; type = 'ssh' })

        $status = Get-AdoServiceEndpointStatus -Name 'SFTP_APP_TEST_DEV' -ExistingEndpoint $existing

        $status.status | Should -Be 'protected'
        $status.reason | Should -BeLike '*GET does not return the stored value*'
    }

    It 'allows an update only when force is supplied' {
        $existing = @([pscustomobject]@{ name = 'SFTP_APP_TEST_DEV'; type = 'ssh' })

        $status = Get-AdoServiceEndpointStatus -Name 'SFTP_APP_TEST_DEV' -ExistingEndpoint $existing -Force

        $status.action | Should -Be 'update'
        $status.status | Should -Be 'pending'
    }

    It 'blocks on a duplicated connection name' {
        $existing = @(
            [pscustomobject]@{ name = 'SFTP_APP_TEST_DEV'; type = 'ssh' }
            [pscustomobject]@{ name = 'SFTP_APP_TEST_DEV'; type = 'ssh' }
        )

        $status = Get-AdoServiceEndpointStatus -Name 'SFTP_APP_TEST_DEV' -ExistingEndpoint $existing

        $status.status | Should -Be 'blocked'
    }
}

Describe 'New-AdoSshServiceEndpointPayload' {

    BeforeAll {
        $script:project = [pscustomobject]@{ id = 'project-id'; name = 'Platform' }
        # Deliberately NOT a real PEM header. A test fixture carrying the genuine
        # delimiter would be flagged by scripts/Test-NoSensitiveData.ps1 - correctly,
        # since the gate cannot tell a fixture from the real thing. The assertions
        # below only need a token distinctive enough to find in a rendered payload.
        $script:keyMarker = 'INVENTED-KEY-MATERIAL-NOT-A-CREDENTIAL'
        $script:privateKey = "$($script:keyMarker)-line-1`n$($script:keyMarker)-line-2"
    }

    It 'keeps the private key out of the data bag' {
        # The reason this test exists: `data` is returned in clear text by
        # GET _apis/serviceendpoint/endpoints to every identity with project read
        # access, so a key duplicated there stops being a secret. It was duplicated
        # there.
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy' -PrivateKey $script:privateKey

        @($payload.data.Keys) | Should -Be @('Host', 'Port')
        ($payload.data.Values -join ' ') | Should -Not -BeLike "*$($script:keyMarker)*"
    }

    It 'sends the private key as a write-only authorization parameter' {
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy' -PrivateKey $script:privateKey

        $payload.authorization.parameters.privateKey | Should -Be $script:privateKey
    }

    It 'carries no credential outside authorization.parameters' {
        # Stated as a whole-payload assertion rather than per field, so a future
        # field that happens to carry a credential fails here instead of shipping.
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy' `
            -PrivateKey $script:privateKey -Password 'sup3rsecret'

        $withoutAuthorization = @{}
        foreach ($key in $payload.Keys) {
            if ($key -eq 'authorization') { continue }
            $withoutAuthorization[$key] = $payload[$key]
        }
        $rendered = $withoutAuthorization | ConvertTo-Json -Depth 8

        $rendered | Should -Not -BeLike "*$($script:keyMarker)*"
        $rendered | Should -Not -BeLike '*sup3rsecret*'
    }

    It 'prefers the private key over a password' {
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy' `
            -PrivateKey $script:privateKey -Password 'sup3rsecret'

        $payload.authorization.parameters.Contains('password') | Should -BeFalse
    }

    It 'omits the private key field entirely when there is no key' {
        # An empty privateKey declares a certificate slot Azure DevOps keeps, which
        # then has to be filled before the connection works.
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy' -Password 'sup3rsecret'

        $payload.authorization.parameters.Contains('privateKey') | Should -BeFalse
        $payload.authorization.parameters.password | Should -Be 'sup3rsecret'
    }

    It 'falls back to the sentinel when no credential is available' {
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy'

        $payload.authorization.parameters.password | Should -Be (Get-AdoConfigurationSentinel)
    }

    It 'never grants the connection to every pipeline' {
        $payload = New-AdoSshServiceEndpointPayload -Project $script:project -Name 'SFTP_APP_TEST_DEV' `
            -ServerHost 'sftp.example.invalid' -Username 'svc_deploy'

        $payload.isShared | Should -BeFalse
    }
}
