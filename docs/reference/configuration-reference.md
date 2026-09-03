# Configuration reference

**Purpose.** Every configuration file and every field, in one place.

**Scope.** Files under `foundation/config/` and `automations/*/config/`, plus `.env`.

**Audience.** Anyone editing a declaration.

**Related documents**

- [conventions.md](conventions.md) — how names are derived from these fields
- [security-model.md](security-model.md) — why values live outside these files
- The per-module guides, for the reasoning behind each field

## 1. Which files exist

| File | Versioned | Schema |
| --- | --- | --- |
| `foundation/config/project-context.json` | Yes | `foundation/schemas/project-context.schema.json` |
| `automations/team-provisioning/config/applications.json` | **No** (template is) | `schemas/applications.schema.json` |
| `automations/team-provisioning/config/board-columns.json` | Yes | `schemas/board-columns.schema.json` |
| `automations/team-provisioning/config/members.env` | **No** (template is) | — |
| `automations/variable-group-configuration/config/scope.json` | **No** (template is) | `schemas/scope.schema.json` |
| `automations/variable-group-configuration/config/variable-groups.csv` | **No** (template is) | column contract |
| `automations/service-connection-provisioning/config/service-connections.json` | **No** (template is) | `schemas/service-connections.schema.json` |
| `.env` | **No** (template is) | — |

Every JSON file declares its own schema with a relative `$schema` property, resolved
and validated at load. A file with no `$schema` and no explicit `-SchemaPath` is
rejected rather than accepted unchecked.

## 2. `.env`

| Variable | Required | Notes |
| --- | --- | --- |
| `ADO_ORG_URL` | Yes | `https://dev.azure.com/<organization>`, no trailing slash. |
| `ADO_PROJECT` | Yes | Team project name, matching the portal including case. |
| `ADO_PAT` | Yes | Personal Access Token. See [getting-started.md](../guides/getting-started.md) for minimum scopes. |
| `<APP>_MEMBERS` | Per application | Sign-in addresses, separated by `;`, `,` or newline. |
| `<KEY>_<ENV>` for a secret Variable Group value | When writing such a group | The variable's own name, **qualified with the environment**: the secret `APP_SERVER_PASSWORD` in the PROD group is read from `APP_SERVER_PASSWORD_PROD`. The group name carries the environment and the secret's own name does not, and a live secret cannot be read back to compare against — so an unqualified name would let a DEV value be written over the PROD credential with the API reporting success. Leave one empty and the group is reported `blocked`, which is the safe outcome. `-AllowUnqualifiedSecretName` accepts the bare `<KEY>` instead, and is only correct when one credential is genuinely shared across every environment. |
| `SFTP_<APP>_<ENV>_{HOST,USERNAME,PASSWORD,PRIVATE_KEY}` | When creating connections | Names derived from `credentialVariables`. |

Format: `KEY=value`, one per line. `#` starts a comment. Surrounding single or double
quotes are stripped, so a value with meaningful trailing spaces can be expressed.
Everything after the first `=` is the value, so `a=b=c` works.

## 3. `project-context.json`

| Field | Required | Notes |
| --- | --- | --- |
| `organizationUrlEnv` | Yes | Name of the variable holding the organization URL. The name is versioned; the value is not. |
| `projectEnv` | Yes | Name of the variable holding the project. |
| `expectedOrganizationEnv` | No | Name of the variable holding the organization this configuration belongs to. When declared **and set**, a run refuses if the organization URL resolves to a different organization. A host allowlist cannot catch that — every organization on `dev.azure.com` shares one permitted host. |
| `environments` | Yes | Suffixes used to derive per-environment names. |
| `defaults.boardTemplateTeam` | Yes | Team whose backlog iteration is copied to a new Team. Without it a new Board fails with `TF400509`. |
| `defaults.defaultIterationMacro` | No | Usually `@currentIteration`. |
| `defaults.workingDays` | No | Set alongside the backlog iteration. |
| `defaults.teamAdministratorMode` | No | `authenticatedUser` promotes the token identity; `none` leaves administration alone. |
| `defaults.configurationSentinel` | Yes | The only value an automation will overwrite. |
| `defaults.serviceConnection.*` | No | Type, authorization scheme, port, and `grantAccessToAllPipelines` (keep `false`). |
| `naming.*` | Yes | Patterns for Team, Area Path, Iteration Path, Variable Group and Service Connection. |
| `automations.<module>.*` | Yes | Path registry, so an entry point has a default for every file it reads and a caller overrides only what differs. |

## 4. `applications.json` — team-provisioning

| Field | Required | Notes |
| --- | --- | --- |
| `applications[].key` | Yes | Passed as `-ApplicationKey`. Unique. No spaces. |
| `applications[].description` | No | For the reader. |
| `applications[].membersEnv` | No | **Name** of the membership variable. Omit and membership is not managed. |
| `applications[].team.name` | Yes | Unique across applications. |
| `applications[].team.description` | No | Set at creation. |
| `applications[].board.name` | Yes | Must match `name` in `board-columns.json`. |
| `applications[].board.workItemTypes` | No | Checked against the project process before columns are written. |
| `applications[].areaPaths.default` | Yes | The Team default. Relative to the project, `/` separated. |
| `applications[].areaPaths.additional` | No | Further paths. Created if missing, never removed. |
| `applications[].iterationPaths.default` | No | The Team default sprint. |
| `applications[].iterationPaths.additional` | No | Further sprints. |

The project segment is never declared. It comes from `ADO_PROJECT`.

## 5. `board-columns.json` — team-provisioning

| Field | Required | Notes |
| --- | --- | --- |
| `name` | Yes | The Board these columns belong to. |
| `preserveUndeclaredColumns` | Yes | Must be `true`. |
| `columns[].name` | Yes | |
| `columns[].columnType` | Yes | `incoming` first, `outgoing` last, exactly one of each. |
| `columns[].stateMappings` | Yes | Work Item type to state, from the project process. |
| `columns[].itemLimit` | No | `0` means no limit. **Omit to keep whatever the Board has**; declaring `0` sets it to zero. |
| `columns[].isSplit` | No | |
| `columns[].description` | No | |
| `columns[].previousNames` | No | Former names, so a rename reuses the existing column id. Transitional; remove once every environment is reconciled. |

## 6. `scope.json` — variable-group-configuration

| Field | Required | Notes |
| --- | --- | --- |
| `applications` | Yes | Keys in scope. |
| `environments` | Yes | |
| `groupNamePattern` | Yes | Must contain `{application}` and `{environment}`. |
| `declaredKeys[].name` | Yes | Variable name, and the environment variable name a secret resolves from. |
| `declaredKeys[].isSecret` | Yes | A secret key is created at the sentinel and completed by its owner. |
| `declaredKeys[].description` | No | |
| `forbiddenKeysByEnvironment` | No | Keys that must not exist in that environment. |
| `manualExclusions[].group` | No | A group deliberately out of scope. |
| `manualExclusions[].reason` | With `group` | At least ten characters. An exclusion with no reason becomes folklore. |

## 7. `variable-groups.csv` — variable-group-configuration

```csv
application,environment,variable,value
```

Four columns, exactly. Rejected rows and their messages are listed in
[variable-group-configuration.md](../guides/variable-group-configuration.md). The one
worth repeating: a row for a key declared secret is rejected, which is how "a secret
value never travels through a CSV" is enforced rather than merely stated.

## 8. `service-connections.json` — service-connection-provisioning

| Field | Required | Notes |
| --- | --- | --- |
| `namePattern` | Yes | Must contain `{application}` and `{environment}`. |
| `defaults.port` | No | Default 22. |
| `defaults.grantAccessToAllPipelines` | No | Keep `false`. |
| `defaults.description` | No | Template supporting both placeholders. |
| `credentialVariables.hostEnv` | Yes | Pattern for the host variable name. |
| `credentialVariables.usernameEnv` | Yes | Pattern for the user name variable. |
| `credentialVariables.passwordEnv` | No | Pattern for the password variable. |
| `credentialVariables.privateKeyEnv` | No | Pattern for the private key variable. |
| `applications[].key` | Yes | |
| `applications[].environments` | Yes | Environments this application actually deploys to. |
| `applications[].port` | No | Overrides the default. |

## 9. Editing safely

| Do | Do not |
| --- | --- |
| Run `validate` after every edit. It is offline and instant. | Edit an active file and apply without planning. |
| Rename the template to create the active file. | Copy its contents into a new name — that name is not excluded from Git. |
| Declare a value you want managed. | Leave a value out and expect the automation to invent it. |
| Remove a `previousNames` entry once the rename is complete everywhere. | Leave it forever; it is transitional. |
| Put a reason on every `manualExclusions` entry. | Exclude something silently. |
