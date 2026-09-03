<#
    Provenance: who ran a command, from where, and at which commit.

    A report said what would change and a receipt said what did. Neither said who, nor
    from which revision of the declarations - and for a product whose premise is that
    configuration is versioned in Git, that was the missing link.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
}

Describe 'New-AdoAsCodeProvenance' {

    BeforeEach {
        # Set and restored around every test: these are read from the ambient
        # environment, and a workstation running the suite must not change the answer.
        $script:savedEnvironment = @{}
        foreach ($name in @('TF_BUILD', 'GITHUB_ACTIONS', 'BUILD_SOURCEVERSION', 'GITHUB_SHA',
                'BUILD_BUILDID', 'BUILD_REQUESTEDFOR', 'BUILD_DEFINITIONNAME', 'BUILD_SOURCEBRANCH',
                'AGENT_MACHINENAME', 'ADO_ASCODE_PROVENANCE_OMIT_ORIGIN')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    AfterEach {
        foreach ($name in @($script:savedEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name], 'Process')
        }
    }

    It 'carries a run id, an actor, an origin and a source' {
        $provenance = New-AdoAsCodeProvenance -Module 'team-provisioning' -Command 'plan'

        foreach ($field in @('runId', 'module', 'command', 'actor', 'origin', 'source', 'tool')) {
            $provenance.PSObject.Properties.Name | Should -Contain $field
        }
    }

    It 'gives every run a distinct, sortable id' {
        $first = New-AdoAsCodeProvenance -Module 'm' -Command 'plan'
        $second = New-AdoAsCodeProvenance -Module 'm' -Command 'plan'

        $first.runId | Should -Not -Be $second.runId
        $first.runId | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{8}$'
    }

    It 'records the build and the commit when it runs on a pipeline' {
        [Environment]::SetEnvironmentVariable('TF_BUILD', 'True', 'Process')
        [Environment]::SetEnvironmentVariable('BUILD_BUILDID', '4821', 'Process')
        [Environment]::SetEnvironmentVariable('BUILD_REQUESTEDFOR', 'Dana Reyes', 'Process')
        [Environment]::SetEnvironmentVariable('BUILD_SOURCEVERSION', '9f1c2ab4d7e83f5109b6c2d84a71fe30cbb59d12', 'Process')

        $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'apply'

        $provenance.origin.kind | Should -Be 'pipeline'
        $provenance.origin.pipeline.buildId | Should -Be '4821'
        $provenance.origin.pipeline.requestedFor | Should -Be 'Dana Reyes'
        $provenance.source.commit | Should -Be '9f1c2ab4d7e83f5109b6c2d84a71fe30cbb59d12'
        $provenance.source.commitOrigin | Should -Be 'environment'
    }

    It 'says workstation when there is no build around it' {
        $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'plan'

        $provenance.origin.kind | Should -Be 'workstation'
        $provenance.origin.PSObject.Properties.Name | Should -Not -Contain 'pipeline'
    }

    It 'never fails a run because it could not find the commit' {
        # The rule the whole block is built on. An apply that refused to start because
        # it could not read a SHA would have traded the change for the record of it.
        # commitOrigin is what distinguishes "there is no commit" from "nobody looked".
        $savedPath = $env:PATH
        try {
            $env:PATH = ''
            $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'apply'

            $provenance | Should -Not -BeNullOrEmpty
            $provenance.source.commitOrigin | Should -BeIn @('git', 'unavailable')
        }
        finally { $env:PATH = $savedPath }
    }

    It 'survives redaction with its identifying fields intact' {
        # Redaction matches PROPERTY NAMES, and 'pat' once matched 'areaPaths' and
        # replaced the very inventory a report existed to carry. A field named
        # carelessly here would be silently replaced with the marker, and nobody would
        # notice until they needed it.
        $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'apply' -ActorDisplayName 'Dana Reyes'
        $sanitized = Remove-SensitiveValue -InputObject $provenance

        $sanitized.runId | Should -Be $provenance.runId
        $sanitized.actor.adoDisplayName | Should -Be 'Dana Reyes'
        $sanitized.actor.osUser | Should -Not -Be '[redacted]'
        $sanitized.source.commitOrigin | Should -Be $provenance.source.commitOrigin
    }

    It 'drops the identifying fields on request, keeping the useful ones' {
        [Environment]::SetEnvironmentVariable('ADO_ASCODE_PROVENANCE_OMIT_ORIGIN', '1', 'Process')
        [Environment]::SetEnvironmentVariable('BUILD_SOURCEVERSION', '9f1c2ab4d7e83f5109b6c2d84a71fe30cbb59d12', 'Process')

        $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'apply' -ActorDisplayName 'Dana Reyes'

        $provenance.origin.machine | Should -BeNullOrEmpty
        $provenance.actor.osUser | Should -BeNullOrEmpty
        $provenance.runId | Should -Not -BeNullOrEmpty
        $provenance.source.commit | Should -Be '9f1c2ab4d7e83f5109b6c2d84a71fe30cbb59d12'
    }
}

Describe 'Provenance in the evidence' {

    It 'writes the same run id into the report and the receipt' {
        # The correlation the whole change exists for: a receipt detached from its
        # build still joins back to the plan that was approved.
        $provenance = New-AdoAsCodeProvenance -Module 'm' -Command 'apply' -RunId '20260902T141233Z-7f3a9c21'
        $plan = New-Plan -Command 'apply' -Target 'APP_TEST'
        $reportPath = Join-Path $TestDrive 'report.json'
        $receiptPath = Get-AdoAsCodeReceiptPath -ReportPath $reportPath

        Write-AdoAsCodeReport -Plan $plan -Path $reportPath -Module 'm' -Provenance $provenance | Out-Null
        Save-AdoAsCodeReceipt -Path $receiptPath -Target 'APP_TEST' -Status 'completed' -Provenance $provenance

        (Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json).provenance.runId |
            Should -Be '20260902T141233Z-7f3a9c21'
        (Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json).provenance.runId |
            Should -Be '20260902T141233Z-7f3a9c21'
        Get-Content -Raw -LiteralPath ([System.IO.Path]::ChangeExtension($reportPath, '.md')) |
            Should -BeLike '*20260902T141233Z-7f3a9c21*'
    }

    It 'still writes a report when no provenance is supplied' {
        # -Provenance is optional so the writers stay usable without one, and under
        # Set-StrictMode the Markdown renderer would throw on the missing property if
        # the render were not guarded.
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        $reportPath = Join-Path $TestDrive 'no-provenance.json'

        { Write-AdoAsCodeReport -Plan $plan -Path $reportPath -Module 'm' } | Should -Not -Throw
        Get-Content -Raw -LiteralPath ([System.IO.Path]::ChangeExtension($reportPath, '.md')) |
            Should -Not -BeLike '*## Provenance*'
    }

    It 'writes JSON without a byte order mark' {
        # Set-Content -Encoding UTF8 emits one in Windows PowerShell 5.1, the floor this
        # repository supports, and a strict JSON parser rejects it. Both committed
        # examples carried one, which is how it was found.
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        $reportPath = Join-Path $TestDrive 'encoding.json'
        Write-AdoAsCodeReport -Plan $plan -Path $reportPath -Module 'm' | Out-Null

        $firstBytes = [System.IO.File]::ReadAllBytes($reportPath)[0..2]
        ($firstBytes -join ',') | Should -Not -Be '239,187,191'
    }

    It 'calls the foundation with parameters the foundation declares' {
        # This exists because of a real defect. The line that builds provenance runs
        # only after a connection context, so it is unreachable from the offline
        # validate path the suite otherwise exercises - and an edit that passed a
        # parameter no function declares sat there passing every test, ready to throw
        # on the first real plan. Parse the calls and check them against the actual
        # parameter sets, rather than trusting a path nothing runs.
        $repositoryRoot = Get-RepositoryRoot
        $checked = @('New-AdoAsCodeProvenance', 'Write-AdoAsCodeReport', 'Save-AdoAsCodeReceipt')

        foreach ($entryPoint in (Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'automations') -Recurse -Filter 'Invoke-*.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPoint.FullName, [ref] $tokens, [ref] $errors)

            $commands = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in $checked
                }, $true)

            foreach ($command in $commands) {
                $declared = (Get-Command $command.GetCommandName()).Parameters.Keys
                foreach ($element in $command.CommandElements) {
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    $declared | Should -Contain $element.ParameterName `
                        -Because "$($entryPoint.Name) passes -$($element.ParameterName) to $($command.GetCommandName()), which does not declare it"
                }
            }
        }
    }

    It 'every evidence write in every automation records its provenance' {
        # -Provenance is optional, so a call site can silently drop it - and a receipt
        # with no actor and no commit is exactly the gap this closes. Asserted
        # statically rather than trusted, because the failure is invisible in a run
        # that otherwise passes.
        $repositoryRoot = Get-RepositoryRoot
        foreach ($entryPoint in (Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'automations') -Recurse -Filter 'Invoke-*.ps1')) {
            $text = Get-Content -Raw -LiteralPath $entryPoint.FullName
            foreach ($writer in @('Write-AdoAsCodeReport', 'Save-AdoAsCodeReceipt')) {
                # A backtick continuation means a line-based match reports false
                # positives, so the call is matched up to its final line.
                foreach ($call in [regex]::Matches($text, [regex]::Escape($writer) + '(?:[^\r\n]|`\r?\n)*')) {
                    $call.Value | Should -BeLike '*-Provenance*' `
                        -Because "$($entryPoint.Name) calls $writer without provenance: $($call.Value.Trim())"
                }
            }
        }
    }
}
