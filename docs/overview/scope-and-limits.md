# Scope and limits

**Purpose.** State what this repository does not do, and why each gap is a decision
rather than an omission.

**Scope.** Boundaries. What it does do is in [capabilities.md](capabilities.md).

**Audience.** Anyone deciding whether it fits their situation, and anyone about to
add a feature that is missing on purpose.

**Related documents**

- [capabilities.md](capabilities.md) — what is in scope
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — the API behaviour behind several of these limits
- [risk-register.md](../process/risk-register.md) — the risks these limits control

## 1. It never deletes

| What | Instead |
| --- | --- |
| A Team | Reported. Deleted by hand, after confirming it holds no Work Items. |
| An Area or Iteration Path | Reported. Deleted in the portal, which forces you to say where the Work Items go. |
| A Team member | Members are added, never removed. |
| A Board column | An undeclared column is preserved and reported. |
| A Variable Group or one of its keys | An undeclared key is preserved and reported. |
| A Service Connection | Reported. |

Deletion is the one class of operation whose blast radius cannot be predicted from a
plan, because what a resource *contains* is not in the declaration. A Board column
holds Work Items; an Area Path holds a query somebody built a dashboard on. So the
automation reports and a human decides. See
[0005-never-delete-preserve-undeclared-state.md](../adr/0005-never-delete-preserve-undeclared-state.md).

## 2. It never writes a secret value it cannot verify

| What | Why |
| --- | --- |
| Setting a secret Variable Group value | The live value cannot be read, so there is no way to know what would be replaced. A secret key is created at the sentinel and completed by its owner. |
| Overwriting a Service Connection credential | Same reason, plus the update route is a full object `PUT`. Possible with two explicit switches, and not otherwise. |
| Renaming a Service Connection | The API offers no partial update; the portal does. An automated rename would send `null` over a working credential and report success. |

The last one is the clearest example of a gap being the correct answer. There is no
rename path in the code at all, so there is nothing to reach for by accident: the plan
reports `manual` and the guide says to use the portal.

## 3. There is no automatic rollback

Reversing means deleting, and section 1 explains why that is a human decision. What
exists instead:

| Artefact | What it gives you |
| --- | --- |
| The plan | What was about to change, approved before it happened. |
| The receipt | What actually completed, written after every operation — including for a run that died halfway. |
| The module guide | A rollback table per resource type, saying what is reversible and what is not. |

An Area Path rename is not reversible in practice: renaming back rewrites
`System.AreaPath` on every Work Item a second time, and the revision history keeps
both entries. The plan says so, in those words, before you confirm.

## 4. Out of scope by design

| Not covered | Why |
| --- | --- |
| Build and release pipeline definitions | A large surface with its own lifecycle. The repository this one is derived from covered it; it was left out here to keep three modules readable rather than one exhaustive. |
| Repositories, branch policies, project-level permissions | Different review and approval path. Granting permissions from a tool that also creates Teams concentrates too much authority in one token. |
| Work item creation, queries, dashboards | Content, not configuration. |
| Issue tracker integration | Ties the repository to one vendor's tenant and adds a second credential for no gain in what it governs. |
| Provisioning a new organization or project | Both are assumed to exist. Creating them is a one-off with a different approval path. |
| Non-SSH Service Connection types | Only the type actually used is modelled. Declaring types nobody creates is untested code that looks supported. |

## 5. Operational limits

| Limit | Reason |
| --- | --- |
| One application per `apply` | Keeps a plan readable and a failure attributable, and preserves the blast radius that makes a pilot meaningful. |
| No scheduled runs | A plan needs a reader. Nothing here benefits from running unattended. |
| No concurrency control | Two simultaneous applies against the same Team are last-write-wins, as they would be in the portal. Run one at a time; the receipts show who did what. |
| Windows PowerShell 5.1 minimum | Schema validation is reduced on 5.1 — the result says which engine ran, so a report never claims more coverage than it had. |
| No test against a live organization | The suite covers pure functions with fixtures. See [testing-strategy.md](../process/testing-strategy.md) for what that does and does not prove. |

## 6. If you need something in section 4

Add it as a **new automation module**, not as a command on an existing one. The
contract is in [automation-contract.md](../reference/automation-contract.md), and
the dependency rules are in [architecture.md](../reference/architecture.md). The one
thing not to do is grow an existing entry point sideways — that is how the codebase
this one is derived from ended up with a single 3,000-line script that nobody could
change safely.
