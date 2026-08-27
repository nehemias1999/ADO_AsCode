<#
    Contract tests for the automations.

    These do not exercise Azure DevOps. They verify the things that break quietly
    between releases: a shipped example that stopped matching its schema, an entry
    point that lost a command, a template that acquired a real value.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

    # $script: so the value is visibly shared with the It blocks below.
    $script:automations = @(
        @{ Name = 'team-provisioning';               EntryPoint = 'Invoke-TeamProvisioning.ps1' }
        @{ Name = 'variable-group-configuration';    EntryPoint = 'Invoke-VariableGroupConfiguration.ps1' }
        @{ Name = 'service-connection-provisioning'; EntryPoint = 'Invoke-ServiceConnectionProvisioning.ps1' }
    )
}

Describe 'Automation contract' {

    It 'every automation has an entry point, a guide, a config folder and a schema folder' {
        # The contract in docs/reference/automation-contract.md, enforced rather than
        # only described - which is the difference between a contract and a wish.
        foreach ($automation in $script:automations) {
            $folder = Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)"

            Test-Path -LiteralPath (Join-Path $folder $automation.EntryPoint) | Should -BeTrue -Because "$($automation.Name) needs a single entry point"
            Test-Path -LiteralPath (Join-Path $folder 'README.md') | Should -BeTrue -Because "$($automation.Name) needs a guide"
            Test-Path -LiteralPath (Join-Path $folder 'config') | Should -BeTrue -Because "$($automation.Name) needs a config folder"
            Test-Path -LiteralPath (Join-Path $folder 'schemas') | Should -BeTrue -Because "$($automation.Name) needs a schema folder"
        }
    }

    It 'every entry point exposes validate, plan and apply, and gates apply behind a confirmation' {
        foreach ($automation in $script:automations) {
            $path = Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)/$($automation.EntryPoint)"
            $content = Get-Content -Raw -LiteralPath $path

            $content | Should -BeLike "*'validate'*" -Because "$($automation.Name) must offer an offline check"
            $content | Should -BeLike "*'plan'*" -Because "$($automation.Name) must offer a dry run"
            $content | Should -BeLike "*'apply'*" -Because "$($automation.Name) must offer an apply"
            $content | Should -BeLike '*ConfirmApply*' -Because "$($automation.Name) must not write without an explicit confirmation"
            $content | Should -BeLike '*Assert-PlanApplicable*' -Because "$($automation.Name) must refuse a blocked plan"
        }
    }

    It 'every automation README documents rollback' {
        # The one section people skip, and the one that matters at 2am.
        foreach ($automation in $script:automations) {
            $readme = Get-Content -Raw -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)/README.md")
            $readme | Should -BeLike '*Rollback*' -Because "$($automation.Name) must say how to reverse what it did"
        }
    }

    It 'every automation is registered in the project context' {
        $context = Get-AdoAsCodeConfiguration -Path (Join-Path (Get-RepositoryRoot) 'foundation/config/project-context.json')
        foreach ($automation in $script:automations) {
            @($context.automations.PSObject.Properties.Name) | Should -Contain $automation.Name
        }
    }
}

Describe 'Shipped examples' {

    It 'the team-provisioning application template satisfies its schema' {
        $root = Get-RepositoryRoot
        { Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/team-provisioning/config/applications.example.json') } |
            Should -Not -Throw
    }

    It 'the board column template satisfies its schema and the reconciler rules' {
        $root = Get-RepositoryRoot
        $template = Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/team-provisioning/config/board-columns.json')
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Not -Throw
    }

    It 'the variable group scope template satisfies its schema' {
        $root = Get-RepositoryRoot
        { Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/variable-group-configuration/config/scope.example.json') } |
            Should -Not -Throw
    }

    It 'the service connection template satisfies its schema' {
        $root = Get-RepositoryRoot
        { Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/service-connection-provisioning/config/service-connections.example.json') } |
            Should -Not -Throw
    }

    It 'no .env template carries a credential value' {
        # A template with a credential in it is how a real one reaches a public
        # repository: somebody fills it in "just to test" and commits the file whose
        # name does not look local. Non-secret defaults - an organization URL, a
        # project name - are allowed and useful; anything credential-shaped is not.
        $root = Get-RepositoryRoot
        $templates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.env*' |
            Where-Object { $_.Name -like '*.example' })
        $templates.Count | Should -BeGreaterThan 0

        $credentialKey = '(?i)(pat|password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)'

        foreach ($template in $templates) {
            foreach ($line in (Get-Content -LiteralPath $template.FullName)) {
                if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { continue }
                $name = $Matches[1]
                $value = $Matches[2].Trim()
                if (-not $value) { continue }

                $name | Should -Not -Match $credentialKey -Because "$($template.Name) line '$name' must be left empty"
            }
        }
    }

    It 'the values CSV template declares no secret' {
        $root = Get-RepositoryRoot
        $scope = Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/variable-group-configuration/config/scope.example.json')
        $secretKeys = @($scope.declaredKeys | Where-Object { [bool]$_.isSecret } | ForEach-Object { "$($_.name)" })
        $secretKeys.Count | Should -BeGreaterThan 0

        $csv = @(Import-Csv -LiteralPath (Join-Path $root 'automations/variable-group-configuration/config/variable-groups.example.csv'))
        foreach ($row in $csv) {
            $secretKeys | Should -Not -Contain $row.variable
        }
    }

    It 'the forbidden key is absent from the environments that forbid it' {
        $root = Get-RepositoryRoot
        $scope = Get-AdoAsCodeConfiguration -Path (Join-Path $root 'automations/variable-group-configuration/config/scope.example.json')
        $csv = @(Import-Csv -LiteralPath (Join-Path $root 'automations/variable-group-configuration/config/variable-groups.example.csv'))

        foreach ($environmentProperty in $scope.forbiddenKeysByEnvironment.PSObject.Properties) {
            foreach ($forbidden in @($environmentProperty.Value)) {
                $offending = @($csv | Where-Object { $_.environment -eq $environmentProperty.Name -and $_.variable -eq $forbidden })
                $offending.Count | Should -Be 0 -Because "$forbidden is forbidden in $($environmentProperty.Name)"
            }
        }
    }
}

Describe 'Offline validate' {

    It 'every automation validates with no credentials in the environment' {
        # Proves the claim the guides make. If validate needed a token, a newcomer
        # could not check their configuration before asking for one.
        foreach ($variable in @('ADO_PAT', 'ADO_ORG_URL', 'ADO_PROJECT')) {
            [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
        }

        foreach ($automation in $script:automations) {
            $path = Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)/$($automation.EntryPoint)"
            { & $path -Command validate -InformationAction SilentlyContinue } |
                Should -Not -Throw -Because "$($automation.Name) validate must work offline"
        }
    }
}
