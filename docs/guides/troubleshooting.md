# Troubleshooting

**Purpose.** Turn a symptom into a cause and a fix, without reading source code.

**Scope.** Failures reachable from normal operation. API behaviour is explained in
[azure-devops-notes.md](../reference/azure-devops-notes.md).

**Audience.** Whoever is running a command right now.

**Related documents**

- [command-model.md](../reference/command-model.md) — what a status means
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — the underlying API behaviour
- [end-to-end-walkthrough.md](end-to-end-walkthrough.md) — the expected output of each step

## 1. First moves

| Situation | Do this first |
| --- | --- |
| Anything at all | `-Command validate`. It is offline and instant, and it eliminates the whole class of configuration mistakes. |
| Something failed against Azure DevOps | `-Command inventory`. Read-only, and it tells you what is actually there. |
| An apply did not finish | Read the `.receipt.json`. Its `status` says whether the run completed, and it lists exactly which operations did. |
| A plan surprised you | Read the `reason` on the operation. Every one names both what and why. |

Do **not** re-run `apply` blindly after a failure. Read the receipt, then re-plan.

## 2. Connection and credentials

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Required environment variable 'ADO_PAT' is not set.` | No `.env`, or the variable is missing from it. | Run `.\scripts\bootstrap.ps1`, then fill in `.env`. |
| `Environment file not found: .env` | `bootstrap.ps1` has not been run. | Run it. A missing file is an error rather than a silent skip, so a run never proceeds without its credentials. |
| `HTTP 401` on the first call | Token expired, revoked, or issued for another organization. | Create a new one. A token is bound to the organization it was created in. |
| `HTTP 403` on a write, `200` on a read | The token lacks a scope, or the account lacks the permission. | Compare against the scope table in [getting-started.md](getting-started.md). A token grants no permission its account does not hold. |
| `The organization URL ... does not end in an organization name` | `ADO_ORG_URL` has a trailing path or a typo. | Use exactly `https://dev.azure.com/<organization>`. |
| `HTTP 404` on the project | `ADO_PROJECT` does not match, including case. | Copy the name from the portal. |

## 3. Configuration

| Symptom | Cause | Fix |
| --- | --- | --- |
| `does not satisfy its schema` | A field is missing, mistyped, or misspelled. | The message lists every error with its JSON path. On PowerShell 5.1 the check is reduced — the message says which engine ran. |
| `application key 'X' is declared 2 times` | Duplicate, usually a merge accident. | Keys must be unique. |
| `Team name 'X' is declared by 2 applications` | Two applications point at one Team. | Two applications cannot share a Team; its Board and Area Path belong to one of them. |
| `areaPaths.default 'X' is repeated in additional` | The default is listed twice. | Remove it from `additional`. It is included automatically. |
| `board.name is 'X' but the column template targets 'Y'` | The application and the column template disagree. | Make them match; the reconciler needs one Board. |
| `Application 'X' is not declared` | `-ApplicationKey` does not match a `key`. | The message lists the declared keys. |
| `Configuration file not found` | The template has not been renamed. | Rename the `.example` file. Until then, commands fall back to the template. |

## 4. Boards and Work Items

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TF400509` opening the Board | The Team exists but lacks a backlog iteration, an Area Path, or a team field value. | Run `apply` again — it sets all three. Creating a Team through the API sets none of them. |
| Plan blocked: `State(s) 'X' are mapped by the column template but do not exist` | A `stateMappings` value is not a state in the project process. | Run `inventory`, or check the process in the portal, and correct `config/board-columns.json`. Writing it would fail with an error that does not name the state. |
| Plan blocked: `the Board has both 'A' and 'B'` | Somebody created the renamed column by hand without retiring the old one. | Delete the old column in the portal, then re-plan. The reconciler will not choose which one to keep. |
| Warning: `reused the existing column ... because its state mapping is identical` | A column matched by state mapping rather than by name — the third and least certain matching stage. | Check its Work Items. If the match is wrong, declare `previousNames` so stage 2 handles it. |
| Warning: `columnType 'incoming' was changed to 'inProgress'` | An undeclared column had a type that would invalidate the Board. | Usually correct. Azure DevOps allows one incoming and one outgoing column, and the outgoing one must be last. |
| A Board column reappears after every apply | Nothing. It is preserved because nothing declares it. | Declare it, or delete it in the portal. |
| Sprint missing from the Team | The iteration node exists but the Team is not subscribed. | Run `apply`. Creating the node and subscribing are separate operations. |

## 5. Members

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Identity 'x@contoso.com' was not found` | No access to the organization. | Grant access first. This adds people to a Team; it does not license them. |
| `Identity 'x' is ambiguous (3 matches)` | A display name matched several people. | Use the exact sign-in address. The automation refuses to guess who you meant. |
| Membership operation shows `warning` | The members variable is empty. | Fill in `config/members.env`. Existing members are untouched either way. |
| A removed member is still in the Team | Members are added, never removed. | Remove them in the portal. |

## 6. Variable Groups

| Symptom | Cause | Fix |
| --- | --- | --- |
| Blocked: `holds secret(s) with no known value in this session` | A secret was completed in the portal; no matching environment variable exists locally. | Supply it under the same name, or make the change in the portal. Not a bug — see [variable-group-configuration.md](variable-group-configuration.md). |
| `protected`: `holds 'A' while the values file declares 'B'` | Somebody set that value on purpose. | Reconcile the CSV, or clear the variable to the sentinel to let the automation fill it. |
| Blocked: `Present in DEV but declared forbidden there` | A key that must not exist in that environment does. | Remove it in the portal. The automation does not delete. |
| `line 15: 'X' is declared secret, so its value must not appear in a values file` | A secret ended up in the CSV. | Remove the row. The key is created at the sentinel and completed by its owner. |
| A pipeline authenticates fine, then stops after an apply | A secret was blanked by a write that omitted it. | Have its owner set it again. If it happened here, the guard failed — open an issue with the receipt. |

## 7. Service Connections

| Symptom | Cause | Fix |
| --- | --- | --- |
| `protected`: not modified | Working as intended. A full `PUT` would replace a credential that cannot be read back. | To change it, use the portal, or both force switches. |
| Blocked: `No value for 'SFTP_..._HOST'` | The host variable is not set. | Set it. There is no sensible placeholder for a host. |
| `-ForceUpdate requires -ForceCredentialOverwrite` | One switch supplied. | Both, deliberately. The message says what will be replaced. |
| Connection created but the deployment cannot authenticate | It holds the sentinel, waiting for its owner. | Complete it in the portal. `validate` prints the variable names for the handover. |
| Connection asks for a certificate nobody has | An empty private key was sent by something other than this automation. | Recreate it. This repository omits the field entirely rather than sending it empty. |

## 8. Transient and environmental

| Symptom | Cause | Fix |
| --- | --- | --- |
| `HTTP 429`, run continues | Throttling. Retried with backoff, honouring `Retry-After`. | Nothing. |
| `HTTP 503` then success | Azure DevOps shedding load. Retried. | Nothing. |
| `HTTP 400` or `409`, no retry | A real answer. Retrying a `400` only multiplies the damage. | Read the message; it carries the service's own explanation. |
| Board not ready right after creating a Team | Propagation delay. | Nothing. Two steps retry twice with a pause. |
| `Pester 5 is required but not available` | Windows ships Pester 3.4, whose syntax is incompatible. | `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force` |
| The sensitive data gate fails on your own file | Something looks like a credential, a private address, an internal host name or a workstation path. | Read the rule name in the output. If it is a false positive, add a narrow allow expression to the rule — never widen it to make the finding go away. |
