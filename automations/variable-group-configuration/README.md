# variable-group-configuration

**Purpose.** Create Azure DevOps Variable Groups from a declared scope and fill their
non-secret values from a CSV, without ever destroying a secret.

**Scope.** Variable Groups, their keys, and their non-secret values.

**Audience.** Whoever operates the automation, and whoever reviews its plan.

**Related documents**

- [Full guide](../../docs/guides/variable-group-configuration.md) — field-by-field contract and rollback
- [Security model](../../docs/reference/security-model.md) — why a secret value never enters a file here
- [Azure DevOps notes](../../docs/reference/azure-devops-notes.md) — the PUT that blanks a secret, measured

## 1. The three rules

| Rule | Why it exists |
| --- | --- |
| The only value overwritten is the sentinel `PENDING_OWNER_CONFIGURATION`. | A key holding anything else was set by somebody on purpose. The automation fills blanks; it does not overrule decisions. |
| A write to a group containing secrets re-posts every secret in the same request, or is refused. | A Variable Group `PUT` sends the whole object, and an omitted `value` is stored as an **empty string** — not "left unchanged". Omitting a secret deletes it. |
| A key listed as forbidden for an environment is refused, and reported if present. | The agent exposes every variable of every linked group as a process environment variable. A stray key can switch on behaviour that appears in no pipeline definition and in no diff. |

The third rule is the one people find surprising. It is the reason
`forbiddenKeysByEnvironment` exists rather than simply not writing the key: absence
has to be **asserted**, because nothing else in the system will notice it came back.

## 2. Configuration

| File | Versioned | Purpose |
| --- | --- | --- |
| `config/scope.example.json` | Yes | Template. Rename to `scope.json` for your active scope. |
| `config/scope.json` | **No** | Which groups exist, which keys they may hold, which keys are forbidden per environment. |
| `config/variable-groups.example.csv` | Yes | Template values, with placeholder hosts. |
| `config/variable-groups.csv` | **No** | Your actual non-secret values. |
| `schemas/scope.schema.json` | Yes | Validated on every `validate`. |

**Secret values appear in neither file.** A key declared `"isSecret": true` is created
at the sentinel and completed by whoever holds the credential. A CSV row for a secret
key is rejected by `validate` — that rejection is the enforcement.

If a secret has to be re-posted so a non-secret key can be written, its value is read
from the environment variable **of the same name** at run time.

## 3. Commands

| Command | Writes to Azure DevOps | Notes |
| --- | --- | --- |
| `validate` | No | Offline. Scope against its schema, CSV against the scope. |
| `inventory` | No | Per-group counts, including how many keys still await configuration. |
| `plan` | No | One operation per group and per key. |
| `smoke` | No | Plan plus the manual verification checklist. |
| `apply` | **Yes**, with `-ConfirmApply` | Creates groups and writes values. |

```powershell
.\Invoke-VariableGroupConfiguration.ps1 -Command validate
.\Invoke-VariableGroupConfiguration.ps1 -Command plan  -ApplicationKey APP_ALPHA -Environment DEV
.\Invoke-VariableGroupConfiguration.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply
.\Invoke-VariableGroupConfiguration.ps1 -Command plan  -ApplicationKey APP_ALPHA -Environment DEV   # nothing pending
```

Start with one application in the lowest environment. `-ApplicationKey` and
`-Environment` are what make a pilot possible.

## 4. Reading the plan

| Status | Meaning here |
| --- | --- |
| `ok` | The live value already matches, or the values file says nothing about the key. |
| `pending` | The key is absent or holds the sentinel, and will be written. |
| `protected` | The key holds a value that is neither absent nor the sentinel, and is left alone. Reconcile the values file, or clear the variable to the sentinel to let the automation fill it. |
| `warning` | A secret waiting for its owner, or a variable present in the group that the scope does not declare. |
| `blocked` | A forbidden key is present, a group name is duplicated, or the group holds a secret with no known value in this session. |

The last blocked case is worth understanding rather than working around: once a
secret is completed in the portal and no matching environment variable exists
locally, this automation cannot write **any** key of that group without blanking the
secret. The correct responses are to supply the value in your environment file, or
to make the change in the portal.

## 5. Personal Access Token scopes

| Scope | Why |
| --- | --- |
| Variable Groups — Read, create & manage | Create groups and write their values. |
| Project and Team — Read | Resolve the project id used in the group's project reference. |

## 6. Output

- Report: `artifacts/plans/variable-group-configuration-<command>[-key][-env].json`,
  plus a Markdown sibling. Values pass through redaction before being written.
- Receipt (apply): `...receipt.json`, updated after every completed group.

## 7. Rollback

| What was applied | How to reverse it |
| --- | --- |
| Group created | Delete it in **Pipelines > Library**, after confirming no pipeline references it. |
| Non-secret value written | The receipt records the previous value where one existed. Set it back in the portal, or reset the key to the sentinel and re-run. |
| Secret re-posted | Nothing to reverse: the value re-posted is the one that was already in effect. If a pipeline starts failing on authentication after an apply, treat the secret as blanked and have its owner set it again. |

## 8. Deliberately not implemented

- **Deleting a variable or a group.** Every writer is additive.
- **Writing a secret value.** The automation cannot read what it would replace, so it
  cannot verify the change, so it does not make it.
- **Importing values from a spreadsheet.** Values arrive as a reviewable CSV diff, or
  they do not arrive.
