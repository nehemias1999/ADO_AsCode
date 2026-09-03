# Capability catalogue

**Purpose.** List every capability this repository provides, where it lives, how it is
invoked, and whether it can change Azure DevOps.

**Scope.** Functional capabilities only. Configuration fields are in
[configuration-reference.md](../reference/configuration-reference.md); command
semantics are in [command-model.md](../reference/command-model.md).

**Audience.** Anyone evaluating what this does, and anyone looking for the module that
owns a given resource.

**Related documents**

- [scope-and-limits.md](scope-and-limits.md) — the capabilities that are deliberately absent
- [command-model.md](../reference/command-model.md) — what each verb means
- [security-model.md](../reference/security-model.md) — why some capabilities stop where they do

## 1. At a glance

| Module | Owns | Entry point |
| --- | --- | --- |
| `team-provisioning` | Teams, members, Area and Iteration Paths, Board columns | `automations/team-provisioning/Invoke-TeamProvisioning.ps1` |
| `variable-group-configuration` | Variable Groups and their non-secret values | `automations/variable-group-configuration/Invoke-VariableGroupConfiguration.ps1` |
| `service-connection-provisioning` | SSH/SFTP Service Connections | `automations/service-connection-provisioning/Invoke-ServiceConnectionProvisioning.ps1` |

Each is invoked the same way: `-Command <verb>`, with `-ApplicationKey` and often
`-Environment` to narrow the target.

## 2. Teams, paths and Boards

| Capability | What it does | Command | Writes | Confirmation |
| --- | --- | --- | --- | --- |
| Create a Team | Creates the Team if absent; adopts it as is if present. | `apply` | Yes | `-ConfirmApply` |
| Grant Team administrator | Adds the token identity as a member and promotes it. Creating a Team through the API does not do this. | `apply` | Yes | `-ConfirmApply` |
| Create Area Paths | Creates every declared node, segment by segment. Never removes one. | `apply` | Yes | `-ConfirmApply` |
| Create Iteration Paths | Creates the node **and** subscribes the Team to it. Two separate operations; doing only the first looks like nothing happened. | `apply` | Yes | `-ConfirmApply` |
| Set the backlog iteration | Copied from a template Team. Without it the Board fails to open with `TF400509`. | `apply` | Yes | `-ConfirmApply` |
| Set the team field | Points the Team at its default Area Path, so its Board shows anything at all. | `apply` | Yes | `-ConfirmApply` |
| Add members | Resolves each sign-in address to an identity and adds it. Members are added, never removed. | `apply` | Yes | `-ConfirmApply` |
| Validate Work Item states | Checks every state a column maps to exists in the project process, before writing columns. | `plan`, `apply` | No | — |
| Reconcile Board columns | Rewrites the column collection to match the declaration, preserving undeclared columns and reusing existing ids. | `apply` | Yes | `-ConfirmApply` |
| Rename a Board column | Declared with `previousNames`, so the existing column keeps its id and its Work Items. | `apply` | Yes | `-ConfirmApply` |
| Correct an existing application | Same as apply, but refuses to create a Team, so it can only correct. | `reconcile` | Yes | `-ConfirmApply` |
| Rename a Team and its Area Path | Compares nodes by id, because Azure DevOps matches an Area Path case insensitively. | `rename` | Yes | `-ConfirmApply -ConfirmRename` |

## 3. Variable Groups

| Capability | What it does | Command | Writes | Confirmation |
| --- | --- | --- | --- | --- |
| Create a group | Creates it with the complete declared key set; secret keys start at the sentinel. | `apply` | Yes | `-ConfirmApply` |
| Fill a non-secret value | Only where the key is absent or holds exactly the sentinel. | `apply` | Yes | `-ConfirmApply` |
| Preserve a deliberate value | A key holding anything other than the sentinel is reported `protected` and left. | `plan` | No | — |
| Re-post secrets on write | Every secret is re-sent with a value resolved from the environment, in the same request. Without this, writing one key blanks every secret in the group. | `apply` | Yes | `-ConfirmApply` |
| Refuse an unverifiable write | Blocks when a secret in the group has no known value in this session. | `plan`, `apply` | No | — |
| Enforce a forbidden key | Reports as blocked any key that must not exist in that environment. | `plan` | No | — |
| Report undeclared keys | Preserves them, and says they are there. | `plan` | No | — |
| Validate the values file | Rejects an out-of-scope application, an undeclared key, a secret value in the CSV, a forbidden key, a duplicate row. | `validate` | No | — |

## 4. Service Connections

| Capability | What it does | Command | Writes | Confirmation |
| --- | --- | --- | --- | --- |
| Create an SSH connection | Uses a private key if available, else a password, else the sentinel. | `apply` | Yes | `-ConfirmApply` |
| Protect an existing connection | Reported `protected` and not modified. A full `PUT` would replace a credential that cannot be read back. | `plan` | No | — |
| Overwrite an existing connection | Available, and hard to reach on purpose. | `apply` | Yes | `-ConfirmApply -ForceUpdate -ForceCredentialOverwrite` |
| List the expected credential variables | Prints the exact names a credential handover needs. | `validate` | No | — |
| Restrict pipeline access | `grantAccessToAllPipelines` defaults to false. | `apply` | Yes | `-ConfirmApply` |

## 5. Cross-cutting

| Capability | What it does | Where |
| --- | --- | --- |
| Offline validation | Configuration against its JSON Schema plus the invariants a schema cannot express. No network, no token. | Every module, `-Command validate` |
| Read-only inventory | A snapshot of what exists today. | Every module, `-Command inventory` |
| Plan | Classifies every operation as `ok`, `pending`, `warning`, `protected` or `blocked`. | Every module, `-Command plan` |
| Apply gate | `apply` refuses to run while any operation is blocked. | `Assert-PlanApplicable` |
| Manual verification checklist | The checks a person has to run afterwards, generated per application. | Every module, `-Command smoke` |
| Report | JSON plus a Markdown sibling, redacted at the writer. | `artifacts/` |
| Incremental receipt | Rewritten after **every** completed operation, so an interrupted run still records what finished. | `artifacts/`, `*.receipt.json` |
| Secret redaction | Values are replaced by the *name* of their property, so a weak password is redacted too. | `Remove-SensitiveValue` |
| Sensitive data gate | Fails the build on credential-shaped strings, private addresses, internal host names, workstation paths. | `scripts/Test-NoSensitiveData.ps1` |
| Retry with backoff | `GET`, `PUT` and `DELETE` only — `POST` creates, so retrying one manufactures a duplicate. Retried on `408`, `429`, `500`, `502`, `503`, `504`, and on a failure with **no** status at all (DNS, TLS, timeout). A `400` or `409` is a real answer and is never retried. `Retry-After` is honoured, capped at 120s. | `Get-AdoRetryDecision` |

## 6. Where each capability is proven

| Capability group | Proven by |
| --- | --- |
| Board column reconciliation | `tests/foundation/Ado.Work.BoardColumns.Tests.ps1` — id reuse, preservation, rename, conflict, idempotency |
| Variable Group write safety | `tests/foundation/Ado.Library.VariableGroups.Tests.ps1` — sentinel policy, secret re-posting, refusal to write blind |
| Plan model and the apply gate | `tests/foundation/AdoAsCode.Core.Tests.ps1` |
| The automation contract | `tests/automations/Automations.Tests.ps1` — every module has the seven required parts |
| Offline validation | `tests/automations/Automations.Tests.ps1` — runs with the credential variables cleared |
