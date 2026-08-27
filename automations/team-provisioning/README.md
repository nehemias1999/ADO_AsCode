# team-provisioning

**Purpose.** Provision and reconcile the Azure DevOps Team, classification paths and
Board of a declared application.

**Scope.** Teams, members, Area and Iteration Paths, Board columns. One application
per execution.

**Audience.** Whoever operates the automation, and whoever reviews its plan.

**Related documents**

- [Full guide](../../docs/guides/team-provisioning.md) — configuration field by field, and rollback
- [Command model](../../docs/reference/command-model.md) — what each verb means and what it may write
- [Azure DevOps notes](../../docs/reference/azure-devops-notes.md) — why the Board needs four things, not one

## 1. Configuration

| File | Versioned | Purpose |
| --- | --- | --- |
| `config/applications.example.json` | Yes | Template. Rename it to `applications.json` to create your active file. |
| `config/applications.json` | **No** | Active declaration. Excluded from Git because it names the environment variables that carry membership, and because it describes a real estate. |
| `config/board-columns.json` | Yes | Shared column template. Policy, not data — it names no application and no person. |
| `config/members.env.example` | Yes | Template for the membership variables. |
| `config/members.env` | **No** | Actual sign-in addresses. Personal data; never committed. |
| `schemas/*.schema.json` | Yes | Validated on every `validate`, not only documented. |

Paths in the configuration are **relative to the project** and use `/` as the
separator. The project segment comes from `ADO_PROJECT`, so the same declaration
works against any organization — and a backslash never has to be escaped in JSON.

## 2. Commands

| Command | Writes to Azure DevOps | Notes |
| --- | --- | --- |
| `validate` | No | Offline. No network call and no credential is read. |
| `inventory` | No | Read-only snapshot. Omit `-ApplicationKey` for all applications. |
| `plan` | No | The artefact a reviewer approves. |
| `smoke` | No | Plan plus the manual verification checklist. |
| `apply` | **Yes**, with `-ConfirmApply` | Creates and reconciles. |
| `reconcile` | **Yes**, with `-ConfirmApply` | Corrects an existing application. Refuses to create a Team. |
| `rename` | **Yes**, with `-ConfirmApply -ConfirmRename` | Renames the Team and its Area Path. |

```powershell
.\Invoke-TeamProvisioning.ps1 -Command validate
.\Invoke-TeamProvisioning.ps1 -Command plan     -ApplicationKey APP_ALPHA
.\Invoke-TeamProvisioning.ps1 -Command smoke    -ApplicationKey APP_ALPHA
.\Invoke-TeamProvisioning.ps1 -Command apply    -ApplicationKey APP_ALPHA -ConfirmApply
.\Invoke-TeamProvisioning.ps1 -Command plan     -ApplicationKey APP_ALPHA   # must come back all ok
```

## 3. Personal Access Token scopes

| Scope | Why |
| --- | --- |
| Work Items — Read & write | Create classification nodes and read Work Item type states. |
| Project and Team — Read, write & manage | Create the Team, set its work configuration, add members. |
| Graph — Read | Resolve a sign-in address to an identity, and read group descriptors. |
| Identity — Read & manage | Promote the token identity to Team administrator. |

A token grants no permission its account does not already hold.

## 4. Output

- Report: `artifacts/reports/team-provisioning-<command>-<key>.json`, plus a
  Markdown sibling for attaching to a change record.
- Receipt (apply, reconcile, rename): `...receipt.json`, updated after **every**
  completed operation, so an interrupted run still records what finished.

`artifacts/` is not versioned.

## 5. What this never does

- Delete a Team, a path, a member, or a Board column. Every writer is additive.
- Touch Service Connections, pipelines, or project-level permissions.
- Commit a membership list.
- Apply a plan that contains a blocked operation.

## 6. Rollback

There is no automatic rollback, and that is a decision rather than an omission:
reversing a Team creation means deleting a Team, and a Team carries Work Items.

| What was applied | How to reverse it |
| --- | --- |
| Team created | Delete the Team from **Project settings > Teams**, by hand, after confirming it holds no Work Items. |
| Area or Iteration Path created | Delete the node in **Project settings > Project configuration**. Azure DevOps requires a destination for any Work Item still on it. |
| Member added | Remove the member from the Team in the portal. |
| Board columns reconciled | Restore the previous columns from the `.receipt.json`, which lists the exact change that was made. There is no version history for Board columns, which is the reason the receipt exists. |
| Area Path renamed | Not reversible in practice. Renaming back rewrites `System.AreaPath` on every Work Item a second time and the revision history keeps both entries. |

Before reversing anything, read the receipt: it is the only record of what the run
actually changed.

## 7. Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TF400509` when opening the Board | Team exists but has no backlog iteration or team field | Run `apply` again; `Initialize-AdoTeamWorkConfiguration` sets all three prerequisites. |
| Plan blocked on a Work Item type | A column maps a state the project process does not define | Correct `stateMappings` in `config/board-columns.json` to a state `inventory` reports as valid. |
| Plan blocked on both names of a column | Someone created the renamed column by hand without retiring the old one | Delete the old column in the portal, then re-plan. The reconciler will not choose which one to keep. |
| `Identity ... was not found` | The sign-in address has no access to the organization | Grant access first. This automation adds people to a Team; it does not license them. |
| Membership operation shows as `warning` | The members environment variable is empty | Fill in `config/members.env`. Existing members are left untouched either way. |
