# Guide: variable-group-configuration

**Purpose.** The full contract for the Variable Groups module: every configuration
field, every command, and how to reverse what it did.

**Scope.** `automations/variable-group-configuration/`.

**Audience.** Whoever configures or operates it.

**Related documents**

- [Module README](../../automations/variable-group-configuration/README.md) — the short version
- [security-model.md](../reference/security-model.md) — why a secret value never enters a file here
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — the `PUT` that blanks a secret

## 1. What it owns

Variable Groups in scope, the keys they may contain, and the values of the non-secret
ones. It never sets a secret to a value you name, and it never deletes. It does
**re-post** every secret when it writes to a group that holds one - see section 4b,
because that is the one operation here that can lose a credential.

## 2. The three rules

| Rule | Consequence you will see |
| --- | --- |
| The only value overwritten is the sentinel `PENDING_OWNER_CONFIGURATION`. | A key holding anything else is reported `protected`, not updated. |
| A write to a group containing secrets re-posts every secret in the same request, or is refused. | A group whose secret has no local value becomes `blocked` for **every** key. |
| A key forbidden in an environment is refused, and reported if present. | `ENABLE_BACKUP` in `DEV` is a blocked operation, not a silent skip. |

The second rule is the one that surprises people, so state it plainly: a Variable
Group `PUT` sends the whole object, and Azure DevOps stores an omitted `value` as an
**empty string**. "Leave the secret alone by not sending it" deletes the secret. The
only correct behaviour is to re-post it with a value you can prove you know — or to
refuse to write at all.

The third rule is not cosmetic either. A pipeline agent exposes every variable of
every linked group as a process environment variable, so a stray key can switch on
behaviour that appears in no pipeline definition and in no diff. Absence has to be
**asserted**, because nothing else in the system will notice it came back.

## 3. `config/scope.json`

| Field | Required | Notes |
| --- | --- | --- |
| `applications` | Yes | Application keys in scope. A group outside the derived names is not touched, and is not reported as drift either — it belongs to somebody else. |
| `environments` | Yes | Environment suffixes. |
| `groupNamePattern` | Yes | Must contain `{application}` and `{environment}`. Derived with no per-environment override: an override is how a pipeline's reference and a group's real name stop matching. |
| `declaredKeys[].name` | Yes | Variable name. Also the environment variable name a secret is resolved from. |
| `declaredKeys[].isSecret` | Yes | A secret key is created at the sentinel and completed by its owner. This automation never writes its value. |
| `declaredKeys[].description` | No | For the reader. |
| `forbiddenKeysByEnvironment` | No | Environment to keys that must not exist there. |
| `manualExclusions[]` | No | Group names deliberately out of scope, each with a `reason` of at least ten characters. An exclusion with no reason becomes folklore. |

## 4. `config/variable-groups.csv`

```csv
application,environment,variable,value
APP_ALPHA,DEV,APP_SERVER_HOST,app-dev-01.contoso.local
APP_ALPHA,DEV,DEPLOY_PATH,/srv/app-alpha
```

Four columns, exactly. `validate` rejects a row for each of:

| Rejected | Message says |
| --- | --- |
| Application not in scope | which application |
| Environment not in scope | which environment |
| Variable not a declared key | which key |
| **Variable declared secret** | remove the row; the key is created at the sentinel and completed by whoever holds the credential |
| Key forbidden in that environment | that writing it would switch on behaviour no pipeline definition mentions |
| Empty value | that an empty value is not the same as "leave it alone" — remove the row instead |
| Same application/environment/variable twice | both values, when they differ |

The secret rejection is the enforcement of "a secret value never travels through a
CSV". It is a rule with a check behind it, not a convention.

## 4b. Secret re-posting, and the variable it reads

Writing any non-secret key in a group that holds secrets means re-posting **every**
secret in the same request, because a Variable Group `PUT` sends the whole object and an
omitted value is stored as an empty string.

Each secret is resolved from an **environment-qualified** variable:

```text
Group  Credentials_APP_ALPHA_PROD
Secret APP_SERVER_PASSWORD
Reads  APP_SERVER_PASSWORD_PROD
```

If that variable is not set, the group is reported **blocked** and nothing is written.
That is the intended outcome, not a failure to work around.

`-AllowUnqualifiedSecretName` additionally accepts the bare `APP_SERVER_PASSWORD`, for a
credential that really is the same in every environment. The qualified name still wins
when both are set.

> Declare these in `.env` or as pipeline secret variables, one per environment. The
> reason the plain name is not the default: the group name carries the environment but
> the secret's name does not, and the live value cannot be read back to compare — so a
> DEV value in `APP_SERVER_PASSWORD` used to overwrite the PROD secret with the API
> reporting success.

## 5. Commands

| Command | Writes | Requires | Notes |
| --- | --- | --- | --- |
| `validate` | No | — | Offline. Scope against its schema, CSV against the scope. |
| `inventory` | No | — | Per group: variable count, secret count, how many still hold the sentinel. |
| `plan` | No | — | One operation per group and per key. |
| `smoke` | No | — | Plan plus the manual checklist. |
| `apply` | Yes | `-ConfirmApply` | Creates groups and writes values. |

Narrow with `-ApplicationKey` and `-Environment`. Start with one application in the
lowest environment: that is what makes a pilot meaningful.

## 6. Reading the plan

| Status | Meaning here | What to do |
| --- | --- | --- |
| `ok` | Live value matches, or the CSV says nothing about the key. | Nothing. |
| `pending` | Absent or holding the sentinel; will be written. | Check the value. |
| `protected` | Holds a value that is neither absent nor the sentinel. | Reconcile the CSV, or clear the variable to the sentinel to let the automation fill it. |
| `warning` | A secret waiting for its owner, or a variable the scope does not declare. | Hand over the credential, or declare the key. |
| `blocked` | A forbidden key is present, a name is duplicated, or a secret has no known value. | See below. |

### The blocked case worth understanding

```text
The group holds secret(s) with no known value in this session: APP_SERVER_PASSWORD.
Any write sends the complete object, and an omitted secret is stored as an empty
string, so writing would blank them.
```

Once a secret is completed in the portal and no matching environment variable exists
locally, this automation cannot write **any** key of that group. Three correct
responses, in order of preference:

1. Supply the value in your environment file under the same name, and re-plan.
2. Make the change in the portal.
3. Decide the key is not worth the risk and remove it from the CSV.

What is *not* a correct response is forcing the write. There is no switch for it.

## 7. What `apply` does

| Situation | Action |
| --- | --- |
| Group absent | `POST` with the complete declared key set. Non-secret keys take their CSV value; everything else starts at the sentinel. Nothing can be destroyed because nothing exists. |
| Group present | `PUT` through the secret-preserving writer, containing only keys that are absent or hold the sentinel, plus every secret re-posted from the environment. Refuses if any secret cannot be resolved. |

## 8. Personal Access Token scopes

| Scope | Why |
| --- | --- |
| Variable Groups — Read, create & manage | Create groups and write values. |
| Project and Team — Read | Resolve the project id in the group's project reference. |

## 9. Rollback

| Applied | Reverse it by |
| --- | --- |
| Group created | Deleting it in **Pipelines > Library**, after confirming no pipeline references it. |
| Non-secret value written | Setting it back in the portal, or resetting the key to the sentinel and re-running. The receipt records the previous value where there was one. |
| Secret re-posted | The value re-posted is whatever `<NAME>_<ENVIRONMENT>` held in the environment of the run — **not** necessarily the value that was in effect, because the live value cannot be read back to compare. If a pipeline starts failing on authentication after an apply, have the owner set the secret again, and check which variable the run resolved. |

Every receipt carries a **provenance** block naming the run, the identity behind the
token, the machine or build, and the commit the declarations came from — so a
rollback starts from a record of what changed *and* of which declaration produced
it. See [verification-and-evidence.md](../process/verification-and-evidence.md).

## 10. Deliberately not implemented

- **Deleting a variable or a group.** Every writer is additive.
- **Writing a secret value.** The automation cannot read what it would replace, so it
  cannot verify the change, so it does not make it.
- **Importing values from a spreadsheet.** Values arrive as a reviewable CSV diff, or
  they do not arrive.
