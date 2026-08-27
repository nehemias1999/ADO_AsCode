# Working agreements

**Purpose.** State how a change gets from an idea into `main`, and what "done" means.

**Scope.** Change control for every artefact here: code, configuration, schema,
pipeline, documentation.

**Audience.** Contributors and reviewers.

**Related documents**

- [CONTRIBUTING.md](../../CONTRIBUTING.md) — the short version
- [automation-contract.md](../reference/automation-contract.md) — what a new module must provide
- [verification-and-evidence.md](verification-and-evidence.md) — what a reviewer is shown

## 1. Branch and commit

One branch per change. Commit subject in the imperative, prefixed with the issue it
closes:

```text
#42 reconcile board columns without dropping undeclared ones
```

The prefix is not decoration: it is what lets somebody reading `git log` two years
later find the discussion that explains why.

## 2. Before you push

```powershell
.\scripts\Invoke-Tests.ps1
.\automations\<module>\Invoke-<Module>.ps1 -Command validate
```

`Invoke-Tests.ps1` runs the parse check, static analysis, the unit suite and the
sensitive data gate. Continuous integration runs the same command, so "it passed
locally" and "it passed in CI" describe the same set of checks.

## 3. What a reviewer is given

| For a change to | Attach |
| --- | --- |
| Shared code (`foundation/`) | The test that covers the new rule. |
| An automation | A `plan` before and after, if the change alters what a plan says. |
| Configuration | The `validate` output. |
| Anything that writes | The receipt from applying it in the lowest environment. |

A plan is the review artefact for this repository the way a diff is for application
code. A change that alters behaviour without altering any plan is either safe or
untested, and the reviewer needs to know which.

## 4. Definition of done

A functional change is not done until all seven are true.

| # | Requirement |
| --- | --- |
| 1 | Static analysis and the unit suite pass. |
| 2 | The module guide under `docs/guides/` reflects the new behaviour. |
| 3 | The document is linked from `docs/README.md`. An unindexed document counts as incomplete, and CI enforces it. |
| 4 | `CHANGELOG.md` names the module and the observable result. |
| 5 | A test covers the new rule, with fixtures containing no real data. |
| 6 | `plan` still produces the same output for unchanged input, or the difference is explained in the changelog entry. |
| 7 | If the change adds a way to write, the guide says how to reverse it. |

Item 6 is the one people skip. A change that quietly alters an existing plan is how a
routine apply becomes a surprise.

## 5. Versioned and not versioned

| Versioned | Never versioned |
| --- | --- |
| Configuration templates (`*.example.*`) | The active configuration files renamed from them |
| Schemas | `.env`, `.env.pipeline` |
| Shared code, entry points, pipeline definitions | Membership lists |
| Documentation, ADRs, changelog | Reports, receipts, anything under `artifacts/` |
| Tests and their fixtures | Anything under `.local/` |

If you are unsure, ask whether the file would still make sense in someone else's
organization. If not, it is local.

## 6. Adding a new automation

Read [automation-contract.md](../reference/automation-contract.md) first. A new
capability is a new module, never a new command on an existing entry point and never a
new branch in the shared layer.

The shared layer is for things every automation needs. The moment it grows an
`if this is a board` branch, it has become a second monolith with extra steps.

## 7. Never in a commit

Personal Access Tokens, passwords, private keys, membership lists, host names, IP
addresses, customer or employer names, execution reports.

The sensitive data gate enforces the mechanical half of this. The rest is review.

If a credential does reach a commit, treat it as compromised: rotate it first, then
worry about the history. A credential in a pushed commit is compromised the moment it
is pushed, whatever happens afterwards.
