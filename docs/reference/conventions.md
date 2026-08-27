# Conventions

**Purpose.** Record how names are derived, inside Azure DevOps and inside this
repository.

**Scope.** Naming and marker values. Field definitions are in
[configuration-reference.md](configuration-reference.md).

**Audience.** Anyone adding an application, a module or a document.

**Related documents**

- [configuration-reference.md](configuration-reference.md) — where these patterns are configured
- [security-model.md](security-model.md) — the role of the sentinel

## 1. The rule behind the rules

**Every resource name is derived from the application key and the environment. There
are no per-environment overrides.**

An override looks harmless — one resource whose name did not fit the pattern, so it
was declared explicitly. The failure it produces is not: a pipeline references
`Credentials_APP_ALPHA_PROD`, the group is actually called something else, and the
variable resolves to empty at run time. No error, no diff, a deployment that quietly
uses a default.

So the patterns are configuration, applied uniformly. What changes per application is
the key; what changes per environment is the suffix. Nothing else.

## 2. Azure DevOps resources

Patterns live in `foundation/config/project-context.json` under `naming`, and in each
module's own configuration.

| Resource | Pattern | Example |
| --- | --- | --- |
| Team | `{application}_Team` | `APP_ALPHA_Team` |
| Area Path | `{project}\{application}_Team` | `Platform\APP_ALPHA_Team` |
| Iteration Path | `{project}\{application}_Team\{iteration}` | `Platform\APP_ALPHA_Team\Sprint 01` |
| Variable Group | `Credentials_{application}_{environment}` | `Credentials_APP_ALPHA_DEV` |
| Service Connection | `SFTP_{application}_{environment}` | `SFTP_APP_ALPHA_DEV` |
| Approver group | `{application}_{environment}_Approvers` | `APP_ALPHA_PROD_Approvers` |

## 3. Environment variables

| Purpose | Pattern | Example |
| --- | --- | --- |
| Connection details | fixed | `ADO_ORG_URL`, `ADO_PROJECT`, `ADO_PAT` |
| Team membership | `{application}_MEMBERS` | `APP_ALPHA_MEMBERS` |
| Secret Variable Group value | the variable's own name | `APP_SERVER_PASSWORD` |
| Service Connection credential | `SFTP_{application}_{environment}_{FIELD}` | `SFTP_APP_ALPHA_DEV_PASSWORD` |

A secret Variable Group value resolving from a variable of the **same name** is what
makes re-posting possible without a mapping table that could drift.

## 4. Application keys

| Rule | Reason |
| --- | --- |
| Uppercase with underscores | Reads clearly inside a derived name. |
| No spaces | Safe on a command line and in a resource name. |
| Unique across the declaration | The key identifies the application everywhere. |
| Stable | Changing a key renames every derived resource. That is a `rename`, not an edit. |

Placeholder keys in this repository are `APP_ALPHA` and `APP_BETA`. Real ones name the
application, not the team that owns it or the system it talks to.

## 5. Marker values

| Marker | Meaning |
| --- | --- |
| `PENDING_OWNER_CONFIGURATION` | Not configured yet, and **the only value an automation will overwrite**. Anything else carries a decision. |

The sentinel is deliberately unmistakable. A blank would be ambiguous — it could mean
"intentionally empty" — and something like `TODO` could plausibly be a real value.

Reading it in the portal tells whoever holds the credential exactly what is expected of
them, which is why it is a sentence rather than a symbol.

## 6. Repository layout

| Element | Convention | Example |
| --- | --- | --- |
| Automation folder | lowercase, hyphenated, named after the **result** | `team-provisioning` |
| Entry point | `Invoke-<PascalCase>.ps1` | `Invoke-TeamProvisioning.ps1` |
| Module | `<Area>.<Concern>` | `Ado.Work`, `AdoAsCode.Report` |
| Configuration collection | plural | `applications.json` |
| Template | the active name plus `.example` | `applications.example.json` |
| Schema | `<subject>.schema.json` | `board-columns.schema.json` |
| Pipeline | the automation name | `pipelines/team-provisioning.yml` |
| Document | lowercase, hyphenated, visible purpose | `azure-devops-notes.md` |
| Test | `<Subject>.Tests.ps1` | `Ado.Work.BoardColumns.Tests.ps1` |

Naming a folder after the result rather than the mechanism — `team-provisioning`, not
`board-tool` — is what keeps the scope of a module obvious as it grows.

## 7. PowerShell

| Convention | Reason |
| --- | --- |
| Approved verbs only | `Get`, `New`, `Set`, `Test`, `Initialize`, `Sync`, `Add`, `Remove`, `Invoke`, `Write`, `Save`, `Resolve`. Not `Ensure`, which is not one. |
| Collection parameters are **plural**; loop variables are singular | PowerShell variable names are case insensitive, so `foreach ($existingColumn in ...)` against a parameter named `$ExistingColumn` assigns to the *typed parameter* and silently wraps each item in an array. Property reads keep working through member enumeration, so nothing throws — it just stops behaving. |
| `Set-StrictMode -Version Latest` in every module | A typo in a property name is an error, not `$null`. |
| Optional properties read through a guard | The consequence of strict mode: partial objects have to be read deliberately. |
| Comment-based help on every function | `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`. |
| Comments say **why** | What the code does is in the code. Why it is written that way is not. |

The plural rule is not style. It is written down because the bug it prevents is
invisible: a rename-by-previous-name that silently stopped firing, with no error
anywhere.

## 8. Commits and documents

| Convention | Example |
| --- | --- |
| Commit subject | `#42 reconcile board columns without dropping undeclared ones` |
| Document header | Purpose, Scope, Audience, Related documents |
| Dates | Only in a changelog entry or an ADR. A contract with a date looks stale the moment it is correct. |
| Indexing | Every document linked from `docs/README.md`. CI fails otherwise. |
