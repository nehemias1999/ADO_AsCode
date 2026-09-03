<#
    The pure functions that had no test.

    Each of these computes a value from its arguments and touches nothing, which is the
    property the design leans on: the dangerous logic was written as pure functions SO
    THAT it could be tested offline. Four of them were never actually tested - and one
    said in its own help that it was, which is the worse failure of the two, because a
    documented claim of coverage is what stops anyone looking.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
}

Describe 'Format-AdoAsCodeReportMarkdown' {

    BeforeAll {
        $script:plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        Add-PlanOperation -Plan $script:plan -Operation (New-PlanOperation -Resource 'Team' -Name 'APP_TEST_Team' `
                -Action 'create' -Status 'pending' -Reason 'Absent. It will be created.')
        Add-PlanOperation -Plan $script:plan -Operation (New-PlanOperation -Resource 'Variable' -Name 'G/K' `
                -Action 'exists' -Status 'blocked' -Reason 'A secret has no resolvable source.')
        Add-PlanOperation -Plan $script:plan -Operation (New-PlanOperation -Resource 'Board' -Name 'Issues' `
                -Action 'exists' -Status 'ok' -Reason 'Already matches.')

        $script:report = [pscustomobject]@{
            module      = 'team-provisioning'
            command     = $script:plan.command
            target      = $script:plan.target
            generatedAt = $script:plan.generatedAt
            summary     = Get-PlanSummary -Plan $script:plan
            operations  = @($script:plan.operations)
        }
        $script:markdown = Format-AdoAsCodeReportMarkdown -Report $script:report
    }

    It 'puts the operations needing attention before the ones that do not' {
        # The order a reviewer reads in. A report that leads with fifteen 'ok' rows
        # buries the one blocked operation that stops the apply.
        $blockedAt = $script:markdown.IndexOf('### blocked')
        $okAt = $script:markdown.IndexOf('### ok')

        $blockedAt | Should -BeGreaterThan 0
        $okAt | Should -BeGreaterThan 0
        $blockedAt | Should -BeLessThan $okAt
    }

    It 'renders every operation, with its reason' {
        $script:markdown | Should -BeLike '*APP_TEST_Team*'
        $script:markdown | Should -BeLike '*A secret has no resolvable source.*'
        $script:markdown | Should -BeLike '*Already matches.*'
    }

    It 'escapes a pipe in a reason instead of breaking the table' {
        # A reason is free text written for a person, and a bare pipe in a Markdown
        # table silently splits the row into extra cells - so the reason a reviewer
        # needs is the thing that gets mangled.
        $plan = New-Plan -Command 'plan' -Target 'APP_TEST'
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'Variable' -Name 'G/K' `
                -Action 'set' -Status 'pending' -Reason 'Value is a|b|c, which needs escaping.')

        $rendered = Format-AdoAsCodeReportMarkdown -Report ([pscustomobject]@{
                module = 'm'; command = 'plan'; target = 'T'; generatedAt = $plan.generatedAt
                summary = Get-PlanSummary -Plan $plan; operations = @($plan.operations)
            })

        $row = @($rendered -split "`r?`n" | Where-Object { $_ -like '*needs escaping*' })[0]
        $row | Should -BeLike '*a\|b\|c*'
        # Four columns, so four separators plus the two ends - the escaped pipes must
        # not have added cells.
        ([regex]::Matches($row, '(?<!\\)\|')).Count | Should -Be 5
    }

    It 'says so plainly when a plan produced nothing' {
        $empty = New-Plan -Command 'plan' -Target 'APP_TEST'
        $rendered = Format-AdoAsCodeReportMarkdown -Report ([pscustomobject]@{
                module = 'm'; command = 'plan'; target = 'T'; generatedAt = $empty.generatedAt
                summary = Get-PlanSummary -Plan $empty; operations = @()
            })

        $rendered | Should -BeLike '*No operations were produced.*'
    }
}

Describe 'The plan vocabulary' {

    It 'is the same closed list the module enforces' {
        # These exist so a test and a document can assert against the list the module
        # uses, rather than restating it - and then neither did. A typo in the
        # vocabulary breaks New-PlanOperation, every report and the apply gate at once.
        foreach ($status in Get-PlanStatusName) {
            { New-PlanOperation -Resource 'Team' -Name 'T' -Action 'exists' -Status $status -Reason 'r' } |
                Should -Not -Throw -Because "'$status' is offered by Get-PlanStatusName"
        }
        foreach ($action in Get-PlanActionName) {
            { New-PlanOperation -Resource 'Team' -Name 'T' -Action $action -Status 'ok' -Reason 'r' } |
                Should -Not -Throw -Because "'$action' is offered by Get-PlanActionName"
        }
    }

    It 'contains the statuses the apply gate and the reports depend on' {
        Get-PlanStatusName | Should -Contain 'blocked'
        Get-PlanStatusName | Should -Contain 'protected'
        Get-PlanActionName | Should -Contain 'rename'
    }

    It 'offers nothing the module would reject' {
        @(Get-PlanStatusName).Count | Should -BeGreaterThan 0
        { New-PlanOperation -Resource 'T' -Name 'n' -Action 'exists' -Status 'almost' -Reason 'r' } |
            Should -Throw -ExpectedMessage '*Unknown plan status*'
    }
}

Describe 'Get-AdoBoardColumnRenameConflict' {

    It 'reports the column that would collide with its own new name' {
        # The Board holds both the old and the new name. Renaming would produce two
        # columns called the same thing, and this reconciler never deletes - so the
        # conflict has to stop the plan rather than be resolved by guessing.
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'In Progress')
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'In Progress' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )

        $conflicts = @(Get-AdoBoardColumnRenameConflict -DesiredColumns $desired -ExistingColumns $existing)

        $conflicts.Count | Should -Be 1
        $conflicts[0] | Should -BeLike '*Doing*'
    }

    It 'reports nothing when only the old name is present' {
        $desired = @(
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'In Progress')
        )
        $existing = @(
            (New-BoardColumnFixture -Name 'In Progress' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
        )

        @(Get-AdoBoardColumnRenameConflict -DesiredColumns $desired -ExistingColumns $existing) |
            Should -BeNullOrEmpty
    }

    It 'reports nothing when no column claims a previous name' {
        $columns = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )

        @(Get-AdoBoardColumnRenameConflict -DesiredColumns $columns -ExistingColumns $columns) |
            Should -BeNullOrEmpty
    }
}

Describe 'Module manifests' {

    BeforeAll {
        $script:manifests = @(Get-ChildItem -LiteralPath (Join-Path (Get-RepositoryRoot) 'foundation/modules') -Recurse -Filter '*.psd1')
    }

    It 'ships one manifest per module, and every one of them is valid' {
        @($script:manifests).Count | Should -Be 7
        foreach ($manifest in $script:manifests) {
            { Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop | Out-Null } |
                Should -Not -Throw -Because "$($manifest.Name) must be a loadable manifest"
        }
    }

    It 'keeps every module on the same version' {
        # The seven were in step by hand and nothing checked it. A module left behind
        # in a release is the kind of thing found by a consumer, not by the person who
        # forgot it.
        $versions = @($script:manifests | ForEach-Object { (Import-PowerShellDataFile -LiteralPath $_.FullName).ModuleVersion } | Sort-Object -Unique)

        @($versions).Count | Should -Be 1 -Because "the modules must share one version, found: $($versions -join ', ')"
    }

    It 'exports exactly what each module exports' {
        # FunctionsToExport and Export-ModuleMember are two lists of the same thing,
        # maintained separately. When they disagree, the manifest wins and the function
        # is simply missing - with no error anywhere.
        foreach ($manifest in $script:manifests) {
            $declared = @((Import-PowerShellDataFile -LiteralPath $manifest.FullName).FunctionsToExport) | Sort-Object
            $moduleFile = [System.IO.Path]::ChangeExtension($manifest.FullName, '.psm1')
            $text = Get-Content -Raw -LiteralPath $moduleFile

            $match = [regex]::Match($text, "(?s)Export-ModuleMember\s+-Function\s+@\((.*?)\)")
            $match.Success | Should -BeTrue -Because "$($manifest.BaseName) must export explicitly"

            $exported = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) | Sort-Object

            ($declared -join ',') | Should -Be ($exported -join ',') `
                -Because "$($manifest.BaseName): the manifest and Export-ModuleMember must agree"
        }
    }

    It 'never exports a wildcard' {
        # '*' in a manifest turns every private helper into public surface, silently.
        foreach ($manifest in $script:manifests) {
            $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
            $data.FunctionsToExport | Should -Not -Contain '*' -Because "$($manifest.BaseName)"
            @($data.CmdletsToExport) | Should -BeNullOrEmpty -Because "$($manifest.BaseName)"
            @($data.VariablesToExport) | Should -BeNullOrEmpty -Because "$($manifest.BaseName)"
            @($data.AliasesToExport) | Should -BeNullOrEmpty -Because "$($manifest.BaseName)"
        }
    }

    It 'states the same support floor everywhere' {
        # Not asserted here: CompatiblePSEditions, which none of the seven declares.
        # PowerShellVersion 5.1 without it is the signature of a Desktop-only module,
        # while the repository states in three places that PowerShell 7 is supported.
        # That is a real gap, and it is left as a reported finding rather than fixed
        # here, because manifest metadata was scoped out of this pass.
        foreach ($manifest in $script:manifests) {
            $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
            "$($data.PowerShellVersion)" | Should -Be '5.1' -Because "$($manifest.BaseName)"
        }
    }
}
