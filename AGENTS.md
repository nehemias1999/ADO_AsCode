# AGENTS.md

Maintenance contract for this repository. Written for an automated agent, and equally
usable by a person picking it up cold.

## 1. Read this first, in this order

1. This file.
2. `git status --short --branch`.
3. [docs/README.md](docs/README.md) — the index routes by need, so you read one document
   rather than all of them.
4. Only what the task needs:
   - Structure and dependency rules: [docs/reference/architecture.md](docs/reference/architecture.md)
   - Adding a capability: [docs/reference/automation-contract.md](docs/reference/automation-contract.md)
   - Verb and status meanings: [docs/reference/command-model.md](docs/reference/command-model.md)
   - Shared context: `foundation/config/project-context.json`
   - The module you are changing: `automations/<name>/`

**Never read or print** `.env`, anything under `.local/`, or anything under
`artifacts/`. They hold credentials, workstation values and execution records. If a task
seems to require reading one, it does not: what you need is the *name* of a variable,
and that is in the configuration.

## 2. Rules that are not negotiable

| Rule | Where it is enforced |
| --- | --- |
| No writer deletes anything. | Every writer is additive; no delete path exists. |
| `apply` refuses a plan with any blocked operation. | `Assert-PlanApplicable` |
| Writing requires an explicit confirmation switch. | Every entry point |
| Configuration declares a secret **name**, never a value. | Schemas, plus the sensitive data gate |
| The only value overwritten is `PENDING_OWNER_CONFIGURATION`. | `Get-AdoVariableGroupUpdate` |
| A write to a group with secrets re-posts them, or is refused. | `New-AdoVariableGroupPayload` |
| The shared layer carries no domain rules. | Review, and [ADR 0004](docs/adr/0004-shared-foundation-without-domain-rules.md) |

Changing any of these is an ADR, not a commit.

## 3. Where things go

| Adding | Goes in |
| --- | --- |
| A capability for an existing resource family | That automation's entry point |
| A capability for a new resource family | A **new** automation module |
| Something every automation needs | The relevant `foundation/` module |
| Something one automation needs, in shared code | Nowhere. It belongs in that automation. |

The last row is the pressure point. If the shared layer seems to need a special case for
your module, the logic belongs in your module.

## 4. Before you commit

```powershell
.\scripts\Invoke-Tests.ps1
.\automations\<module>\Invoke-<Module>.ps1 -Command validate
```

Parse check, static analysis, unit suite, sensitive data gate. Continuous integration
runs the same command, so there is no second definition of passing.

## 5. Definition of done

| # | Requirement |
| --- | --- |
| 1 | Static analysis and the unit suite pass. |
| 2 | The module guide under `docs/guides/` reflects the new behaviour. |
| 3 | The document is linked from `docs/README.md`. CI fails on an unindexed document. |
| 4 | `CHANGELOG.md` names the module and the observable result. |
| 5 | A test covers the new rule, with fixtures containing no real data. |
| 6 | `plan` produces the same output for unchanged input, or the difference is explained in the changelog entry. |
| 7 | If the change adds a way to write, the guide says how to reverse it. |

## 6. Commits

```text
#42 reconcile board columns without dropping undeclared ones
```

Imperative, prefixed with the issue it closes.

## 7. PowerShell conventions worth knowing before you edit

| Convention | Why |
| --- | --- |
| Collection parameters are **plural**; loop variables singular. | Variable names are case insensitive, so `foreach ($existingColumn in ...)` against a parameter `[object[]] $ExistingColumn` assigns to the typed parameter and silently wraps each item in an array. Property reads keep working through member enumeration, so nothing throws — it just stops behaving. |
| `Set-StrictMode -Version Latest` in every module. | A typo in a property name is an error, not `$null`. Read optional properties through a guard. |
| Approved verbs only. | `Initialize`, `Sync`, `Set` — not `Ensure`, which is not approved. |
| A plan operation is a `Get-*Status` function returning action, status and reason. | Keeps the decision a pure function, which is what makes it testable offline. |
| Comment-based help on every function; comments say **why**. | What the code does is in the code. |

`foundation/Import-Foundation.ps1` is **dot-sourced**, so it shares the caller's scope.
Every variable in it is prefixed for that reason — an unprefixed loop variable there once
overwrote a caller's own `$moduleName`, and the error surfaced three layers away.

## 8. Never in a commit

Tokens, passwords, private keys, membership lists, host names, IP addresses, customer or
employer names, execution reports, anything under `.env`, `.local/` or `artifacts/`.

The sensitive data gate enforces the mechanical half. If it flags something you believe
is a false positive, narrow the rule's allow expression — never widen the rule to make
the finding disappear.

## 9. If something is unsafe to automate

Do not ship it behind a warning. The plan reports `manual`, the guide says why, and no
code path exists to reach for by accident. Renaming a Service Connection is the worked
example: the API cannot do it without destroying the credential, and the portal can. See
[docs/overview/scope-and-limits.md](docs/overview/scope-and-limits.md).
