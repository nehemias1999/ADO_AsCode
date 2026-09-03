# Guide: team-provisioning

**Purpose.** The full contract for the Teams, classification paths and Boards module:
every configuration field, every command, and how to reverse what it did.

**Scope.** `automations/team-provisioning/`.

**Audience.** Whoever configures or operates it.

**Related documents**

- [Module README](../../automations/team-provisioning/README.md) — the short version
- [command-model.md](../reference/command-model.md) — verb and status semantics
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — why a Board needs four things, not one

## 1. What it owns

The Team, its members, its Area and Iteration Paths, its work settings, and the
columns of one Board. One application per execution.

## 2. `config/applications.json`

Rename `applications.example.json` to create it. The active name is the one
`.gitignore` excludes.

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `key` | Yes | string | Passed as `-ApplicationKey`. No spaces, so it is safe on a command line. Must be unique. |
| `description` | No | string | For the reader. |
| `membersEnv` | No | string | **Name** of the environment variable holding the membership list. Never the list itself. Omit it and membership is not managed. |
| `team.name` | Yes | string | Team name. Two applications may not share one. |
| `team.description` | No | string | Set at creation. |
| `board.name` | Yes | string | The Board to reconcile. Must match `name` in `board-columns.json`. |
| `board.workItemTypes` | No | string[] | Types checked against the project process before columns are written. |
| `areaPaths.default` | Yes | string | Assigned as the Team default. Relative to the project, `/` separated. |
| `areaPaths.additional` | No | string[] | Further paths. Missing ones are created; existing ones are never removed. |
| `iterationPaths.default` | No | string | The Team's default sprint. |
| `iterationPaths.additional` | No | string[] | Further sprints. |

Paths use `/` because a backslash has to be escaped in JSON and an escaped separator
is a reliable source of typos. Conversion happens in one place, at load.

The project segment is **not** part of the declaration. It comes from `ADO_PROJECT`,
so the same file works against any organization.

## 3. `config/board-columns.json`

Versioned, not a template: it names no application and no person, so it is policy
rather than data.

| Field | Required | Notes |
| --- | --- | --- |
| `name` | Yes | The Board these columns belong to. |
| `preserveUndeclaredColumns` | Yes | Must be `true`. Declared rather than assumed, so turning the guarantee off would be a visible change — and the validator refuses it anyway. |
| `columns[].name` | Yes | Column name. |
| `columns[].columnType` | Yes | `incoming`, `inProgress` or `outgoing`. Exactly one incoming, first; exactly one outgoing, last. |
| `columns[].stateMappings` | Yes | Work Item type to state. State names come from the project process. |
| `columns[].itemLimit` | No | `0` means no limit. **Omit it to leave whatever the Board already has** — declaring `0` sets it to zero. |
| `columns[].isSplit` | No | Split column. |
| `columns[].description` | No | Shown in the portal. |
| `columns[].previousNames` | No | Names this column used to have. See below. |

### `previousNames` and how a rename works

Renaming a Board column is not a label change. Azure DevOps has no per-column route,
so writing means replacing the whole collection, and a column carries Work Items.

`previousNames` tells the reconciler that the column now called `In QA` is the one
that used to be called `Testing Done`, so it reuses that column's **id**. Reusing the
id renames it and its Work Items follow. Allocating a new id creates a second column
and leaves the first behind — permanently, because the automation never deletes.

The matcher tries three things, in order:

1. Exact name.
2. A declared `previousNames` entry.
3. An identical state mapping — and it warns when this fires, because several columns
   usually share one mapping and this stage is a guess.

Stage 2 exists precisely so stage 3 does not have to guess: without it, a renamed
column falls through to the fallback, which picks the first free column with that
mapping — possibly one the platform owner added.

Remove a `previousNames` entry once every environment has been reconciled. It is
transitional.

### Two states the reconciler refuses

| State | Why it blocks |
| --- | --- |
| The Board has both the new and the old name | Unresolvable. The declared column claims the new name by exact match, and the old one would be preserved as a permanent duplicate. Retire the old column in the portal first. |
| A `previousNames` entry is also a declared column name | Same, detected at `validate` before anything is read. |

## 4. `config/members.env`

```text
APP_ALPHA_MEMBERS=dana.reyes@contoso.com;sam.okafor@contoso.com
```

Separators: semicolon, comma or newline. Every address must already have access to the
organization — this adds people to a Team, it does not license them.

Excluded from version control. A list of people's sign-in addresses is personal data
with no business being in a repository history.

## 5. Commands

| Command | Writes | Requires | Notes |
| --- | --- | --- | --- |
| `validate` | No | — | Offline. No network, no token. |
| `inventory` | No | — | Omit `-ApplicationKey` to cover every declared application. |
| `plan` | No | `-ApplicationKey` | |
| `smoke` | No | `-ApplicationKey` | Plan plus the manual checklist. |
| `apply` | Yes | `-ApplicationKey -ConfirmApply` | Creates and reconciles. |
| `reconcile` | Yes | `-ApplicationKey -ConfirmApply` | Refuses to create a Team, so it can only correct one that exists. |
| `rename` | Yes | `-ApplicationKey -PreviousTeamName -ConfirmApply -ConfirmRename` | See section 7. |

Other parameters: `-EnvFile`, `-ProjectContextPath`, `-ConfigurationPath`,
`-BoardColumnsPath`, `-ReportPath`.

## 6. What `apply` does, in order

Order matters, and each step exists because the previous one is not enough.

1. **Create the Team** if absent. This alone produces a Team whose Board fails to open.
2. **Create the classification nodes**, segment by segment.
3. **Subscribe the Team to each iteration.** Creating the node and subscribing are
   separate operations; doing only the first looks like nothing happened.
4. **Set the work configuration**: the backlog iteration, copied from the template
   Team, and the team field pointing at the default Area Path. Without all three of
   Team, Area Path and team field, the Board returns `TF400509`.
5. **Promote the token identity** to Team administrator. Creating a Team through the
   API does not do this.
6. **Add the declared members.**
7. **Reconcile the Board columns.**

Steps 4 and 7 retry twice with a short pause: a Team created moments earlier is not
immediately queryable for its work settings.

## 7. Renaming

```powershell
.\Invoke-TeamProvisioning.ps1 -Command rename -ApplicationKey APP_ALPHA `
    -PreviousTeamName APP_OLD_Team -ConfirmApply -ConfirmRename
```

Two things happen, and they are not equally safe.

| Resource | Reversible | Why |
| --- | --- | --- |
| Team | Yes | It keeps its id, members and Board. |
| Area Path | **No** | Azure DevOps rewrites `System.AreaPath` on every Work Item below the node. Renaming back rewrites them again, and the revision history keeps both entries. Queries and dashboards filtering on the old path stop matching. |

The plan marks the Area Path rename as `warning` even when it will succeed, so the
sentence above is in front of you before you confirm.

`-PreviousTeamName` is declared, never derived. Inferring a previous identity from a
naming pattern produces confident, wrong diagnoses the moment the pattern changed.

Nodes are compared **by id**, not by name, because Azure DevOps resolves an Area Path
case insensitively: a lookup for the new name succeeds against the old node when the
only difference is capitalisation, and the rename would be skipped as already done.

## 8. Rollback

There is no automatic rollback, and that is a decision: reversing a Team creation
means deleting a Team, and a Team carries Work Items.

| Applied | Reverse it by |
| --- | --- |
| Team created | Deleting it in **Project settings > Teams**, after confirming it holds no Work Items. |
| Area or Iteration Path created | Deleting the node in **Project settings > Project configuration**. Azure DevOps requires a destination for any Work Item still on it. |
| Member added | Removing them from the Team in the portal. |
| Board columns reconciled | Restoring the previous columns from the `.receipt.json`. There is no version history for Board columns — that is why the receipt exists. |
| Area Path renamed | Not reversible in practice. See section 7. |

Read the receipt first. It is the only record of what the run actually changed.

The receipt also carries a **provenance** block naming the run, the identity behind
the token, the machine or build, and the commit the declarations came from — so a
rollback starts from a record of what changed *and* of which declaration produced
it. See [verification-and-evidence.md](../process/verification-and-evidence.md).
