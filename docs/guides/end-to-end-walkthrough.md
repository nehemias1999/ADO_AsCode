# End-to-end walkthrough

**Purpose.** Provision one application from nothing to verified, showing what each
command prints and how to read it.

**Scope.** `APP_ALPHA` in `DEV`, across all three modules. Field-by-field contracts
are in the per-module guides.

**Audience.** Someone who has finished [getting-started.md](getting-started.md).

**Related documents**

- [command-model.md](../reference/command-model.md) — the meaning of each status
- [verification-and-evidence.md](../process/verification-and-evidence.md) — why the last step matters
- [troubleshooting.md](troubleshooting.md) — when a step does not behave

## 1. The shape of the work

Same five steps for every module, and the order is not negotiable:

```text
validate  ->  plan  ->  read the plan  ->  apply  ->  plan again
 offline      no write    a person          writes    must be all ok
```

The last step is not a formality. A re-plan that comes back entirely `ok` is this
repository's definition of a finished change — see
[0006-idempotency-as-acceptance-criterion.md](../adr/0006-idempotency-as-acceptance-criterion.md).

## 2. Declare the application

In `automations/team-provisioning/config/applications.json`:

```json
{
  "key": "APP_ALPHA",
  "description": "Customer portal. Managed manually, no CI/CD pipeline.",
  "membersEnv": "APP_ALPHA_MEMBERS",
  "team": { "name": "APP_ALPHA_Team", "description": "Delivery team for APP_ALPHA." },
  "board": { "name": "Issues", "workItemTypes": ["Epic", "Issue", "Task"] },
  "areaPaths": {
    "default": "APP_ALPHA_Team",
    "additional": ["APP_ALPHA_Team/Development", "APP_ALPHA_Team/Testing"]
  },
  "iterationPaths": {
    "default": "APP_ALPHA_Team/Sprint 01",
    "additional": ["APP_ALPHA_Team/Sprint 02"]
  }
}
```

Paths are relative to the project and use `/`. The project segment comes from
`ADO_PROJECT`, so the same declaration works against any organization.

In `automations/team-provisioning/config/members.env`:

```text
APP_ALPHA_MEMBERS=dana.reyes@contoso.com;sam.okafor@contoso.com
```

That file is excluded from version control. The configuration names the *variable*;
the variable holds the people.

## 3. Validate

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command validate
```

```text
[team-provisioning] Valid. 1 application(s) declared, 8 Board column(s).
[team-provisioning] No network call was made and no credential was read.
```

Validation covers the schema plus the things a schema cannot express: duplicate keys,
two applications sharing a Team, a default path repeated in `additional`, a Board name
that does not match the column template.

## 4. Plan

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA
```

```text
[team-provisioning] Connected to 'https://dev.azure.com/contoso' project 'Platform'.
Plan for 'APP_ALPHA' (plan): 12 operation(s) - ok 0, pending 9, warning 0, protected 0, blocked 0.
  [pending]
    create     Team: APP_ALPHA_Team - The Team does not exist.
    authorize  Team administrator: APP_ALPHA_Team - The identity behind the Personal Access Token is added as a member and promoted to Team administrator. Creating a Team through the API does not do this.
    create     Area Path: APP_ALPHA_Team - The Areas node is missing and will be created. Existing nodes are never removed.
    create     Area Path: APP_ALPHA_Team\Development - ...
    create     Iteration Path: APP_ALPHA_Team\Sprint 01 - ...
    set        Team work configuration: APP_ALPHA_Team - Missing: backlog iteration (copied from 'Platform Team'); default Area Path 'Platform\APP_ALPHA_Team'. Without these the Board fails to open with TF400509.
    add        Team member: dana.reyes@contoso.com - Declared but not a member yet. Members are only added, never removed.
    reconcile  Board column: Issues - The Board does not exist yet because the Team does not. Columns are reconciled once the Team is created.
[team-provisioning] Report: ...\artifacts\reports\team-provisioning-plan-APP_ALPHA.json
```

### Reading it

| Status | What to do |
| --- | --- |
| `ok` | Nothing. Counted, not listed. |
| `pending` | Will be written. Check it is what you meant. |
| `warning` | Will proceed. Read the reason. |
| `protected` | Deliberately not changed. Usually correct. |
| `blocked` | Stops the **whole** apply, not just that operation. |

Every `pending` operation names both what and why. If a name is wrong here, it will be
wrong in Azure DevOps — fix the declaration, not the result.

### If the plan is blocked

```text
  [blocked]
    resolve    Work Item type: Issue - State(s) 'Committed' are mapped by the column template
               but do not exist in the project process. Writing the columns would fail with an
               error that does not name the state.
```

`apply` refuses to run at all. Fix the cause — here, a `stateMappings` value in
`config/board-columns.json` — and re-plan. Do not work around a block; it is
describing something the API would have failed on later, less clearly.

## 5. Apply

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command apply -ApplicationKey APP_ALPHA -ConfirmApply
```

Without `-ConfirmApply` this is a pure simulation and says so.

```text
[team-provisioning] create Team 'APP_ALPHA_Team': Created.
[team-provisioning] create Area Path 'APP_ALPHA_Team': Created.
[team-provisioning] create Iteration Path 'APP_ALPHA_Team\Sprint 01': Created.
[team-provisioning] add Team iteration 'APP_ALPHA_Team\Sprint 01': Subscribed the Team to the iteration.
[team-provisioning] set Team work configuration 'APP_ALPHA_Team': Backlog iteration copied from the template Team.
[team-provisioning] authorize Team administrator 'APP_ALPHA_Team': The identity behind the Personal Access Token is now a Team administrator.
[team-provisioning] add Team member 'dana.reyes@contoso.com': Added to the Team.
[team-provisioning] reconcile Board column 'Issues': Reconciled. Changes: ...
[team-provisioning] apply complete: 9 operation(s) written.
[team-provisioning] Receipt: ...\team-provisioning-apply-APP_ALPHA.receipt.json
[team-provisioning] Next: run 'plan' again. Every operation should be ok, which is how this repository defines a finished change.
```

The receipt is rewritten after **every** line above, not at the end. If the run dies
partway — an expired token, a recycled agent — the receipt still lists exactly what
completed, and its `status` stays `in_progress`. That is what you resume from.

## 6. Re-plan: the acceptance criterion

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA
```

```text
Plan for 'APP_ALPHA' (plan): 12 operation(s) - ok 11, pending 1, warning 0, protected 0, blocked 0.
  [pending]
    authorize  Team administrator: APP_ALPHA_Team - ...
  Nothing to change: the live state already matches the declaration.
```

Everything is `ok` except the administrator grant, which is idempotent at the API and
is always planned. Anything else still `pending` means the apply did not finish — read
the receipt before running `apply` again.

## 7. Smoke: the part a person does

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command smoke -ApplicationKey APP_ALPHA
```

```text
[team-provisioning] Manual verification checklist:
  1. Project settings > Teams lists 'APP_ALPHA_Team' with the expected members.
  2. Board 'Issues' shows these columns in order: To Do | Doing | Blocked | Dev Done | Ready for QA | In QA | Ready for Prod | Done. Columns the automation did not declare are still there.
  3. Create a Work Item of type 'Epic' as a Team member, not as the automation identity.
  4. Assign it to a Team member and move it across every column.
  5. Add a comment and an attachment, to prove the permissions are real and not only visible.
  6. New Work Items carry Area Path 'Platform\APP_ALPHA_Team' by default.
  7. Re-run plan. Every operation should be ok. ...
```

Step 3 says *as a Team member* on purpose. An automated check that creates a throwaway
Work Item proves the API works, which was never in doubt. What needs proving is that a
real person can see the Board and move a card with their own permissions.

## 8. The other two modules

Same ladder.

```powershell
# Variable Groups
.\automations\variable-group-configuration\Invoke-VariableGroupConfiguration.ps1 -Command validate
.\automations\variable-group-configuration\Invoke-VariableGroupConfiguration.ps1 -Command plan  -ApplicationKey APP_ALPHA -Environment DEV
.\automations\variable-group-configuration\Invoke-VariableGroupConfiguration.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply

# Service Connections
.\automations\service-connection-provisioning\Invoke-ServiceConnectionProvisioning.ps1 -Command validate
.\automations\service-connection-provisioning\Invoke-ServiceConnectionProvisioning.ps1 -Command plan  -ApplicationKey APP_ALPHA -Environment DEV
.\automations\service-connection-provisioning\Invoke-ServiceConnectionProvisioning.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply
```

Two outcomes are worth expecting rather than being surprised by.

**A secret waits for its owner.**

```text
  [warning]
    manual     Variable: Credentials_APP_ALPHA_DEV/APP_SERVER_PASSWORD - Secret. Created at
               'PENDING_OWNER_CONFIGURATION'; the value has to be completed in the portal by
               whoever holds it.
```

That is the design: the automation creates the structure, the credential holder fills
it in, and no later run overwrites what they set.

**A group becomes unwritable by automation.**

```text
  [blocked]
    set        Variable: Credentials_APP_ALPHA_DEV/DEPLOY_PATH - The group holds secret(s) with no
               known value in this session: APP_SERVER_PASSWORD. Any write sends the complete
               object, and an omitted secret is stored as an empty string, so writing would blank
               them. Supply the value in your environment file under the same name, or make the
               change in the portal.
```

Once a secret is completed in the portal, no key of that group can be written unless
the session can also re-post the secret. That is a real constraint of the API, not a
limitation to route around: supply the value under the same name in your environment
file, or make the change in the portal.

## 9. Where the evidence ends up

| File | Contains |
| --- | --- |
| `artifacts/reports/<module>-<command>-<key>.json` | The full plan, redacted. |
| `artifacts/reports/<module>-<command>-<key>.md` | The same, rendered for a change record. |
| `artifacts/reports/<module>-apply-<key>.receipt.json` | What actually completed. |

`artifacts/` is excluded from version control: it describes one run of one
environment, and is evidence rather than a contract. See
[report.example.md](../examples/report.example.md) for what these look like.
