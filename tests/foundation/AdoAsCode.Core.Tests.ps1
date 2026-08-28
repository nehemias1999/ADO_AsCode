<#
    The plan model, configuration loading, and evidence writing.

    These three modules carry no Azure DevOps knowledge, so everything in them is
    testable offline - which is the point of having separated them.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
}

Describe 'AdoAsCode.Plan' {

    It 'rejects a status outside the closed vocabulary' {
        # A free-text status is how a plan turns into prose that nothing can
        # enforce - in particular, apply cannot refuse a status it does not know.
        { New-PlanOperation -Resource 'Team' -Name 'T' -Action 'create' -Status 'almost' -Reason 'r' } |
            Should -Throw -ExpectedMessage '*Unknown plan status*'
    }

    It 'rejects an action outside the closed vocabulary' {
        { New-PlanOperation -Resource 'Team' -Name 'T' -Action 'obliterate' -Status 'pending' -Reason 'r' } |
            Should -Throw -ExpectedMessage '*Unknown plan action*'
    }

    It 'counts operations by status' {
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'A' -Action 'create' -Status 'pending' -Reason 'r')
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'B' -Action 'exists' -Status 'ok' -Reason 'r')
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'C' -Action 'exists' -Status 'ok' -Reason 'r')

        $summary = Get-PlanSummary -Plan $plan

        $summary.total | Should -Be 3
        $summary.ok | Should -Be 2
        $summary.pending | Should -Be 1
        $summary.blocked | Should -Be 0
    }

    It 'accepts an operation built from a status triple' {
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        Add-PlanOperation -Plan $plan -Resource 'Board column' -Name 'Issues' `
            -Status ([pscustomobject]@{ action = 'exists'; status = 'ok'; reason = 'Matches.' })

        @($plan.operations).Count | Should -Be 1
        $plan.operations[0].resource | Should -Be 'Board column'
    }

    It 'refuses to apply a plan with a blocked operation' {
        # The single gate every apply passes through. One testable statement rather
        # than a convention each module re-implements.
        $plan = New-Plan -Command 'apply' -Target 'APP_TEST'
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'A' -Action 'create' -Status 'pending' -Reason 'r')
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'B' -Action 'resolve' -Status 'blocked' -Reason 'ambiguous')

        Test-PlanBlocked -Plan $plan | Should -BeTrue
        { Assert-PlanApplicable -Plan $plan } | Should -Throw -ExpectedMessage '*Apply refused*'
    }

    It 'allows a plan with no blocked operation' {
        $plan = New-Plan -Command 'apply' -Target 'APP_TEST'
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'A' -Action 'create' -Status 'pending' -Reason 'r')
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'X' -Name 'Y' -Action 'exists' -Status 'protected' -Reason 'r')

        { Assert-PlanApplicable -Plan $plan } | Should -Not -Throw
    }
}

Describe 'AdoAsCode.Configuration' {

    BeforeAll {
        $envFile = Join-Path $TestDrive 'sample.env'
        @(
            '# a comment',
            '',
            'SIMPLE=value',
            'QUOTED="spaced value"',
            'SINGLE=''other value''',
            'WITH_EQUALS=a=b=c',
            'not a variable line'
        ) | Set-Content -LiteralPath $envFile -Encoding UTF8
    }

    It 'loads variables, ignoring comments and blank lines' {
        Import-AdoAsCodeEnvironment -Path $envFile | Out-Null

        [Environment]::GetEnvironmentVariable('SIMPLE', 'Process') | Should -Be 'value'
        [Environment]::GetEnvironmentVariable('QUOTED', 'Process') | Should -Be 'spaced value'
        [Environment]::GetEnvironmentVariable('SINGLE', 'Process') | Should -Be 'other value'
    }

    It 'keeps everything after the first equals sign' {
        Import-AdoAsCodeEnvironment -Path $envFile | Out-Null
        [Environment]::GetEnvironmentVariable('WITH_EQUALS', 'Process') | Should -Be 'a=b=c'
    }

    It 'fails on a missing file rather than continuing without credentials' {
        { Import-AdoAsCodeEnvironment -Path (Join-Path $TestDrive 'absent.env') } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    It 'skips a missing optional file' {
        { Import-AdoAsCodeEnvironment -Path (Join-Path $TestDrive 'absent.env') -Optional } | Should -Not -Throw
    }

    It 'splits a membership list on any of the accepted separators' {
        [Environment]::SetEnvironmentVariable('TEST_MEMBERS', 'a@contoso.com;b@contoso.com, c@contoso.com', 'Process')

        $members = Get-AdoAsCodeMemberList -VariableName 'TEST_MEMBERS'

        @($members).Count | Should -Be 3
        $members | Should -Contain 'c@contoso.com'
    }

    It 'fails on a membership variable that is not set' {
        { Get-AdoAsCodeMemberList -VariableName 'TEST_MEMBERS_ABSENT' } | Should -Throw -ExpectedMessage '*is not set*'
    }

    It 'returns an empty membership list under AllowEmpty' {
        @(Get-AdoAsCodeMemberList -VariableName 'TEST_MEMBERS_ABSENT' -AllowEmpty).Count | Should -Be 0
    }

    It 'refuses a variable name that steers the interpreter' {
        # Without this, a .env file is a code execution path rather than a
        # configuration one: the name is written straight into the process
        # environment, and the next Import-Module in Import-Foundation.ps1 resolves
        # modules from PSModulePath.
        $hostileFile = Join-Path $TestDrive 'hostile.env'
        @('ADO_PAT=fixture', 'PSModulePath=C:ttacker\modules') |
            Set-Content -LiteralPath $hostileFile -Encoding UTF8

        { Import-AdoAsCodeEnvironment -Path $hostileFile } |
            Should -Throw -ExpectedMessage '*Refusing to set*'
    }

    It 'refuses the interpreter names case-insensitively' {
        # The Windows environment is case-insensitive, so a denylist that is not
        # would be decorative.
        $hostileFile = Join-Path $TestDrive 'hostile-case.env'
        'psmodulepath=C:ttacker\modules' | Set-Content -LiteralPath $hostileFile -Encoding UTF8

        { Import-AdoAsCodeEnvironment -Path $hostileFile } |
            Should -Throw -ExpectedMessage '*Refusing to set*'
    }

    It 'refuses a name that is not shaped like a variable' {
        $oddFile = Join-Path $TestDrive 'odd-name.env'
        'NOT A NAME=value' | Set-Content -LiteralPath $oddFile -Encoding UTF8

        { Import-AdoAsCodeEnvironment -Path $oddFile } |
            Should -Throw -ExpectedMessage '*Invalid variable name*'
    }

    It 'refuses rather than skipping, so a run cannot proceed half-loaded' {
        # The variable before the hostile line is deliberately checked: a skip would
        # leave the caller with a partially loaded environment and no signal.
        $mixedFile = Join-Path $TestDrive 'mixed.env'
        @('K5_BEFORE=set', 'Path=C:ttacker', 'K5_AFTER=set') |
            Set-Content -LiteralPath $mixedFile -Encoding UTF8

        { Import-AdoAsCodeEnvironment -Path $mixedFile } | Should -Throw
        [Environment]::GetEnvironmentVariable('K5_AFTER', 'Process') | Should -BeNullOrEmpty
    }

    It 'validates the shipped project context against its schema' {
        $root = Get-RepositoryRoot
        $result = Test-AdoAsCodeConfiguration `
            -Json (Get-Content -Raw -LiteralPath (Join-Path $root 'foundation/config/project-context.json')) `
            -SchemaPath (Join-Path $root 'foundation/schemas/project-context.schema.json')

        $result.isValid | Should -BeTrue
    }

    It 'rejects an undeclared property' {
        $root = Get-RepositoryRoot
        $json = (Get-Content -Raw -LiteralPath (Join-Path $root 'foundation/config/project-context.json')).Replace(
            '"projectEnv": "ADO_PROJECT",', '"projectEnv": "ADO_PROJECT", "typo": 1,')

        $result = Test-AdoAsCodeConfiguration -Json $json -SchemaPath (Join-Path $root 'foundation/schemas/project-context.schema.json')

        $result.isValid | Should -BeFalse
    }

    It 'rejects a missing required property' {
        $root = Get-RepositoryRoot
        $json = (Get-Content -Raw -LiteralPath (Join-Path $root 'foundation/config/project-context.json')).Replace(
            '"projectEnv": "ADO_PROJECT",', '')

        $result = Test-AdoAsCodeConfiguration -Json $json -SchemaPath (Join-Path $root 'foundation/schemas/project-context.schema.json')

        $result.isValid | Should -BeFalse
    }
}

Describe 'AdoAsCode.Report' {

    It 'redacts a value by the name of its property' {
        # Name matching rather than value matching: a weak password does not look
        # like a secret, but its property name always does.
        # The fixture values come from a variable rather than a literal, because a
        # credential-shaped literal in a test file is precisely what this
        # repository's own secret gate is meant to catch - and the gate should not
        # need an exemption for the test suite that proves redaction works.
        $fixtureValue = 'fixture'
        $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            host     = 'app-dev-01.contoso.local'
            password = $fixtureValue
            nested   = [pscustomobject]@{ apiKey = $fixtureValue; port = 22 }
        })

        $sanitized.host | Should -Be 'app-dev-01.contoso.local'
        $sanitized.password | Should -Be '[redacted]'
        $sanitized.nested.apiKey | Should -Be '[redacted]'
        $sanitized.nested.port | Should -Be 22
    }

    It 'leaves a property whose name merely contains a sensitive substring' {
        # The test this suite was missing. Redaction had only ever been asserted in
        # the direction of "the secret is gone", so an over-broad pattern was
        # invisible: an unanchored 'pat' matched areaPaths and iterationPaths, and
        # every team-provisioning inventory report replaced its path inventory - the
        # data the report exists to carry - with the redaction marker.
        #
        # Destroying evidence is not the safe direction of a redaction bug. It is
        # the direction nobody notices.
        $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            areaPaths      = @('APP_TEST', 'APP_TEST\Sub')
            iterationPaths = @('APP_TEST\Sprint 1')
            reportPath     = 'artifacts/reports/plan.json'
            patch          = 'applied'
            compatible     = $true
        })

        @($sanitized.areaPaths).Count | Should -Be 2
        $sanitized.areaPaths[0] | Should -Be 'APP_TEST'
        # A one-element list has to stay a list. It did not: the function's output was
        # enumerated on return, so this arrived as a bare string and indexing it gave
        # 'A' - the first character.
        $sanitized.iterationPaths -is [array] | Should -BeTrue
        @($sanitized.iterationPaths).Count | Should -Be 1
        $sanitized.iterationPaths[0] | Should -Be 'APP_TEST\Sprint 1'
        $sanitized.reportPath | Should -Be 'artifacts/reports/plan.json'
        $sanitized.patch | Should -Be 'applied'
        $sanitized.compatible | Should -BeTrue
    }

    It 'redacts a whole-segment sensitive name' {
        # The other half: 'pat' and 'key' still have to match when they ARE the name
        # or a delimited segment of it, which is how the real variables are spelled.
        $fixtureValue = 'fixture'
        $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            ADO_PAT      = $fixtureValue
            SFTP_KEY     = $fixtureValue
            SIGNING_CERT = $fixtureValue
        })

        $sanitized.ADO_PAT | Should -Be '[redacted]'
        $sanitized.SFTP_KEY | Should -Be '[redacted]'
        $sanitized.SIGNING_CERT | Should -Be '[redacted]'
    }

    It 'redacts credential names the previous pattern missed' {
        # Every name here passed through in clear text before this change, because
        # the pattern listed only password/secret/token/apikey shapes.
        $fixtureValue = 'fixture'
        $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            passphrase       = $fixtureValue
            connectionString = $fixtureValue
            sshKey           = $fixtureValue
            accessKey        = $fixtureValue
            signature        = $fixtureValue
            bearerToken      = $fixtureValue
        })

        foreach ($property in $sanitized.PSObject.Properties) {
            $property.Value | Should -Be '[redacted]' -Because "$($property.Name) names a credential"
        }
    }

    It 'redacts inside a collection' {
        $sanitized = Remove-SensitiveValue -InputObject @(
            [pscustomobject]@{ name = 'a'; token = 'secret-a' }
            [pscustomobject]@{ name = 'b'; token = 'secret-b' }
        )

        @($sanitized).Count | Should -Be 2
        $sanitized[0].token | Should -Be '[redacted]'
        $sanitized[1].name | Should -Be 'b'
    }

    It 'writes a report and a Markdown sibling, with the detail redacted' {
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST' -GeneratedAt '2026-01-01T00:00:00.0000000Z'
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Team' -Name 'APP_TEST_Team' -Action 'create' -Status 'pending' -Reason 'Missing.')

        $fixtureValue = 'must-not-appear'
        $reportPath = Join-Path $TestDrive 'plan.json'
        $result = Write-AdoAsCodeReport -Plan $plan -Path $reportPath -Module 'test' `
            -Detail ([pscustomobject]@{ password = $fixtureValue; count = 1 })

        Test-Path -LiteralPath $result.JsonPath | Should -BeTrue
        Test-Path -LiteralPath $result.MarkdownPath | Should -BeTrue
        (Get-Content -Raw -LiteralPath $result.JsonPath) | Should -Not -BeLike "*$fixtureValue*"
        (Get-Content -Raw -LiteralPath $result.MarkdownPath) | Should -BeLike '*APP_TEST_Team*'
    }

    It 'derives the receipt path from the report path' {
        Get-AdoAsCodeReceiptPath -ReportPath 'artifacts/plans/apply-APP_TEST.json' |
            Should -Be 'artifacts/plans/apply-APP_TEST.receipt.json'
    }

    It 'writes a receipt that records what completed' {
        # The receipt exists for the run that dies partway through, so its status
        # stays in_progress and its list is what the next run resumes from.
        $receiptPath = Join-Path $TestDrive 'apply.receipt.json'
        Save-AdoAsCodeReceipt -Path $receiptPath -Target 'APP_TEST' -Status 'in_progress' `
            -CompletedOperations @([pscustomobject]@{ resource = 'Team'; name = 'APP_TEST_Team'; action = 'create' })

        $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json

        $receipt.status | Should -Be 'in_progress'
        @($receipt.completedOperations).Count | Should -Be 1
        $receipt.completedOperations[0].name | Should -Be 'APP_TEST_Team'
    }
}
