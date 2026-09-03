# Contributing

## Purpose

Describe the change process so a contribution arrives reviewable and a
reviewer knows what to check.

## Scope

Applies to every change in this repository: code, configuration, schema,
pipeline definition and documentation.

## Related documents

- [docs/process/working-agreements.md](docs/process/working-agreements.md) — full change-control contract
- [docs/reference/automation-contract.md](docs/reference/automation-contract.md) — what a new automation must provide
- [AGENTS.md](AGENTS.md) — maintenance contract, including for automated agents

## 1. Before you start

Read [docs/reference/architecture.md](docs/reference/architecture.md) and
[docs/reference/automation-contract.md](docs/reference/automation-contract.md).
A new capability belongs in a new automation module, not in an existing entry
point and never in the shared layer.

## 2. Branch and commit

One branch per change. Commit subject in the imperative, prefixed with the
issue it closes:

```text
#42 reconcile board columns without dropping undeclared ones
```

## 3. Minimum validation before you push

```powershell
.\scripts\Invoke-Tests.ps1
.\automations\<module>\Invoke-<Module>.ps1 -Command validate
```

`Invoke-Tests.ps1` runs static analysis, the unit suite, and the sensitive
data gate. All three must pass.

## 4. Definition of done

A functional change is not done until all of these are true:

| # | Requirement |
| --- | --- |
| 1 | The code passes static analysis and the unit suite. |
| 2 | The module guide under `docs/guides/` reflects the new behaviour. |
| 3 | The document is linked from `docs/README.md`. An unindexed document counts as incomplete. |
| 4 | `CHANGELOG.md` has an entry naming the module and the observable result. |
| 5 | A test covers the new rule, using fixtures that contain no real data. |
| 6 | `plan` still produces the same output for unchanged input, or the difference is explained in the changelog entry. |
| 7 | If the change adds a way to write, the guide says how to reverse it. |

## 5. What never enters a commit

Personal Access Tokens, passwords, private keys, member lists, host names,
IP addresses, customer or employer names, execution reports, and anything
under `.env`, `.local/` or `artifacts/`.
