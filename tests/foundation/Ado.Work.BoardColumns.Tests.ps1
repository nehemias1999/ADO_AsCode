<#
    Board column reconciliation.

    This is the highest-value test file in the repository, because the code it covers
    is the only place where a routine, approved change can destroy work somebody did.
    Every test below corresponds to a rule stated in the module header, and several
    correspond to a specific way the naive implementation fails.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    $repoRoot = Get-RepositoryRoot
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')
}

Describe 'Test-AdoBoardColumnTemplate' {

    It 'accepts the template shipped with the repository' {
        $template = Get-AdoAsCodeConfiguration -Path (Join-Path (Get-RepositoryRoot) 'automations/team-provisioning/config/board-columns.json')
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Not -Throw
    }

    It 'refuses a template that turns off preservation' {
        $template = [pscustomobject]@{
            name                      = 'Issues'
            preserveUndeclaredColumns = $false
            columns                   = New-BoardFixture
        }
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Throw -ExpectedMessage '*never deletes a column*'
    }

    It 'refuses a template whose outgoing column is not last' {
        $columns = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
            (New-BoardColumnFixture -Name 'Extra' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
        )
        $template = [pscustomobject]@{ name = 'Issues'; preserveUndeclaredColumns = $true; columns = $columns }
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Throw -ExpectedMessage '*outgoing column*last*'
    }

    It 'refuses a previous name that is also a declared column name' {
        # Unresolvable: the declared column claims the name by exact match, and the
        # other one would have to be deleted - which never happens.
        $columns = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'To Do')
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $template = [pscustomobject]@{ name = 'Issues'; preserveUndeclaredColumns = $true; columns = $columns }
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Throw -ExpectedMessage '*also a declared column name*'
    }

    It 'refuses two columns claiming the same previous name' {
        $columns = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'A' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Old')
            (New-BoardColumnFixture -Name 'B' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Old')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $template = [pscustomobject]@{ name = 'Issues'; preserveUndeclaredColumns = $true; columns = $columns }
        { Test-AdoBoardColumnTemplate -Template $template } | Should -Throw -ExpectedMessage '*more than one column*'
    }
}

Describe 'New-AdoBoardColumnPayload' {

    It 'reuses the existing id of every matched column' {
        # Reusing the id is what renames a column instead of replacing it. A new id
        # moves the Work Items to a new column and leaves the old one behind.
        $payload = @(New-AdoBoardColumnPayload -DesiredColumns (New-BoardFixture) -ExistingColumns (New-BoardFixture -Live))

        @($payload | ForEach-Object { $_.id }) | Should -Be @('col-todo', 'col-doing', 'col-done')
    }

    It 'preserves a column nobody declared, keeping its id' {
        $existing = @(New-BoardFixture -Live)
        $existing = @($existing[0], $existing[1],
            (New-BoardColumnFixture -Name 'Owner Column' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-owner'),
            $existing[2])

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns (New-BoardFixture) -ExistingColumns $existing -WarningAction SilentlyContinue)
        $preserved = @($payload | Where-Object { $_.name -eq 'Owner Column' })

        $preserved.Count | Should -Be 1
        $preserved[0].id | Should -Be 'col-owner'
    }

    It 'keeps the outgoing column last when a column is preserved' {
        # Azure DevOps rejects the whole write otherwise, and the message does not
        # say which column is at fault.
        $existing = @(New-BoardFixture -Live)
        $existing = @($existing[0], $existing[1],
            (New-BoardColumnFixture -Name 'Owner Column' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-owner'),
            $existing[2])

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns (New-BoardFixture) -ExistingColumns $existing -WarningAction SilentlyContinue)

        $payload[$payload.Count - 1].columnType | Should -Be 'outgoing'
        @($payload | Where-Object { $_.columnType -eq 'outgoing' }).Count | Should -Be 1
        @($payload | Where-Object { $_.columnType -eq 'incoming' }).Count | Should -Be 1
    }

    It 'retypes a preserved incoming or outgoing column to inProgress' {
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-todo')
            (New-BoardColumnFixture -Name 'Old Entry' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-old')
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-doing')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' } -Id 'col-done')
        )

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns (New-BoardFixture) -ExistingColumns $existing -WarningAction SilentlyContinue)
        $preserved = @($payload | Where-Object { $_.name -eq 'Old Entry' })

        $preserved.Count | Should -Be 1
        $preserved[0].columnType | Should -Be 'inProgress'
    }

    It 'renames by previous name, reusing the id of the renamed column' {
        # The regression this guards: without previousNames, a renamed column falls
        # through to the state-mapping fallback, which picks the first free column
        # sharing that mapping - possibly one somebody else added.
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'In QA' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Testing Done')
            (New-BoardColumnFixture -Name 'Done'  -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-todo')
            (New-BoardColumnFixture -Name 'Owner Column' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-owner')
            (New-BoardColumnFixture -Name 'Testing Done' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-testing')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' } -Id 'col-done')
        )

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing -WarningAction SilentlyContinue)
        $renamed = @($payload | Where-Object { $_.name -eq 'In QA' })

        $renamed.Count | Should -Be 1
        $renamed[0].id | Should -Be 'col-testing'
        @($payload | Where-Object { $_.name -eq 'Owner Column' })[0].id | Should -Be 'col-owner'
    }

    It 'never claims one existing column for two declared columns' {
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'A' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
            (New-BoardColumnFixture -Name 'B' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $existing = @(New-BoardFixture -Live)

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing -WarningAction SilentlyContinue)
        $ids = @($payload | Where-Object { $_.PSObject.Properties.Name -contains 'id' } | ForEach-Object { $_.id })

        @($ids | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }

    It 'blocks when the Board holds both the new and the old name' {
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'In QA' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Testing Done')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-todo')
            (New-BoardColumnFixture -Name 'Testing Done' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-testing')
            (New-BoardColumnFixture -Name 'In QA' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-inqa')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' } -Id 'col-done')
        )

        { New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing } |
            Should -Throw -ExpectedMessage '*retire the old column by hand*'
    }

    It 'honours a declared item limit and keeps an undeclared one' {
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -ItemLimit 7)
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        # 'To Do' carries a limit somebody set in the portal, and the declaration
        # says nothing about it. Resetting it to zero would quietly discard a
        # decision, so the existing value has to survive.
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-todo' -ItemLimit 3)
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-doing')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' } -Id 'col-done')
        )

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing -WarningAction SilentlyContinue)

        @($payload | Where-Object { $_.name -eq 'Doing' })[0].itemLimit | Should -Be 7
        @($payload | Where-Object { $_.name -eq 'To Do' })[0].itemLimit | Should -Be 3
    }
}

Describe 'Test-AdoBoardColumnDrift' {

    It 'reports no drift when the live Board already matches' {
        $drift = Test-AdoBoardColumnDrift -DesiredColumns (New-BoardFixture) -ExistingColumns (New-BoardFixture -Live)
        $drift.hasDrift | Should -BeFalse
    }

    It 'reports no drift when the only difference is a preserved column' {
        # The idempotency test. Defining drift as "the declaration differs from live"
        # would report drift forever here, because preserving a column shifts every
        # position after it - so every apply would rewrite the Board and no run would
        # ever be a no-op.
        $existing = @(New-BoardFixture -Live)
        $existing = @($existing[0], $existing[1],
            (New-BoardColumnFixture -Name 'Owner Column' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-owner'),
            $existing[2])

        $drift = Test-AdoBoardColumnDrift -DesiredColumns (New-BoardFixture) -ExistingColumns $existing
        $drift.hasDrift | Should -BeFalse
    }

    It 'reports drift for a rename, so the rename is actually applied' {
        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'In QA' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Testing Done')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )
        $existing = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' } -Id 'col-todo')
            (New-BoardColumnFixture -Name 'Testing Done' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-testing')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' } -Id 'col-done')
        )

        $drift = Test-AdoBoardColumnDrift -DesiredColumns $desired -ExistingColumns $existing
        $drift.hasDrift | Should -BeTrue
        ($drift.reasons -join ' ') | Should -BeLike "*'In QA'*"
    }

    It 'reports drift on a changed state mapping' {
        $desired = @(New-BoardFixture)
        $desired[1].stateMappings = [pscustomobject]@{ Issue = 'Committed' }

        $drift = Test-AdoBoardColumnDrift -DesiredColumns $desired -ExistingColumns (New-BoardFixture -Live)

        $drift.hasDrift | Should -BeTrue
        ($drift.reasons -join ' ') | Should -BeLike '*state mapping*'
    }

    It 'is idempotent: reconciling twice produces no second change' {
        $existing = @(New-BoardFixture -Live)
        $existing = @($existing[0],
            (New-BoardColumnFixture -Name 'Testing Done' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -Id 'col-testing'),
            $existing[1], $existing[2])

        $desired = @(
            (New-BoardColumnFixture -Name 'To Do' -ColumnType incoming -StateMapping @{ Issue = 'To Do' })
            (New-BoardColumnFixture -Name 'Doing' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' })
            (New-BoardColumnFixture -Name 'In QA' -ColumnType inProgress -StateMapping @{ Issue = 'Doing' } -PreviousName 'Testing Done')
            (New-BoardColumnFixture -Name 'Done' -ColumnType outgoing -StateMapping @{ Issue = 'Done' })
        )

        (Test-AdoBoardColumnDrift -DesiredColumns $desired -ExistingColumns $existing).hasDrift | Should -BeTrue

        $payload = @(New-AdoBoardColumnPayload -DesiredColumns $desired -ExistingColumns $existing -WarningAction SilentlyContinue)
        (Test-AdoBoardColumnDrift -DesiredColumns $desired -ExistingColumns $payload).hasDrift | Should -BeFalse
    }
}
