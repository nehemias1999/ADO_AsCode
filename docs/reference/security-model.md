# Security model

**Purpose.** State where credentials live, what is never written, and what enforces
each rule.

**Scope.** Credential handling and the guards around destructive writes.

**Audience.** Reviewers, and anyone adding a capability that touches a secret.

**Related documents**

- [SECURITY.md](../../SECURITY.md) — the policy summary and how to report a problem
- [risk-register.md](../process/risk-register.md) — the risks these controls address
- [azure-devops-notes.md](azure-devops-notes.md) — the API behaviour behind several of them

## 1. One principle

**Configuration declares the name of a secret. It never holds one.**

```json
{ "hostEnv": "SFTP_APP_ALPHA_DEV_HOST", "passwordEnv": "SFTP_APP_ALPHA_DEV_PASSWORD" }
```

Not the host. Not the password. The **names** of the environment variables that carry
them.

Everything else follows. Configuration can be committed, reviewed as a diff and shared,
because there is nothing in it to leak. Values live in `.env` on a workstation or in a
secret variable group on an agent, and the code path is identical in both — which means
one path to reason about instead of two.

## 2. Where values live

| Value | Lives in | Reaches the code as |
| --- | --- | --- |
| Personal Access Token | `.env` or a pipeline secret variable | `ADO_PAT` |
| Organization URL, project | `.env` or a pipeline parameter | `ADO_ORG_URL`, `ADO_PROJECT` |
| Membership | `members.env` or a pipeline secret variable | `<APP>_MEMBERS` |
| Secret Variable Group value | `.env` or a pipeline secret variable | a variable of the same name |
| Connection credential | `.env` or a pipeline secret variable | `SFTP_<APP>_<ENV>_<FIELD>` |

None of those files is versioned. `.gitignore` excludes `.env*`, `.local/`,
`artifacts/`, and every active configuration file created by renaming a template.

### What a `.env` file is allowed to set

`.env` is operator-edited, unsigned and unhashed, and `Import-AdoAsCodeEnvironment`
writes whatever it names into the process environment. So the *name* is validated, not
just the value:

| Rule | Why |
| --- | --- |
| Name must match `^[A-Za-z_][A-Za-z0-9_]*$` | Anything else is not an environment variable, and accepting it hides a typo |
| `PSModulePath`, `Path`, `PSExecutionPolicyPreference`, `PSHOME`, `PATHEXT`, `ComSpec`, `DOTNET_STARTUP_HOOKS`, `DOTNET_ADDITIONAL_DEPS`, `LD_PRELOAD`, `LD_LIBRARY_PATH` are refused | Each changes where the interpreter finds code or executables |

Without the second rule a `.env` file is a **code execution** path rather than a
configuration one: a line reading `PSModulePath=\somewhere\share` was applied
verbatim, and the next `Import-Module` in `foundation/Import-Foundation.ps1` resolved
modules from it.

Both refusals throw rather than skip the line. A silently ignored line in a credential
file is how a run proceeds without the credential it needed and fails later somewhere
unrelated.

## 3. The sentinel

`PENDING_OWNER_CONFIGURATION` is the only value an automation will overwrite.

| Live value | What happens |
| --- | --- |
| Absent | Written. |
| Exactly the sentinel | Written. |
| Anything else | `protected`. Left alone. |

That single rule is what lets the platform owner complete a credential in the portal
and know no later run will undo it. Comparisons are **case sensitive**: a nearly equal
value has to reach a human, not be overwritten.

## 4. Secrets are never read, and never blindly written

| Operation | Behaviour |
| --- | --- |
| Setting a secret Variable Group value | Refused. The live value cannot be read, so there is nothing to verify against. |
| Writing a non-secret key in a group that holds secrets | Every secret is re-posted with a value resolved from the environment, in the same request. |
| The same, when a secret cannot be resolved | **Blocked.** Nothing is written. |
| Overwriting a Service Connection credential | Two switches: `-ForceUpdate -ForceCredentialOverwrite`. |
| Renaming a Service Connection | Not implemented. Reported `manual`. |

The second row exists because of measured API behaviour: a Variable Group `PUT` sends
the whole object, and an omitted `value` is stored as an **empty string**. "Leave the
secret alone by not sending it" deletes the secret, and the response reports success.

The mitigation is to re-post each secret with a value the caller can prove it knows —
and to refuse when it cannot. `New-AdoVariableGroupPayload` blocks if a secret has no
source, if a resolved value is empty, or if the payload's secret count would differ
from the group's.

## 5. Two switches, not one

`-ForceUpdate` alone fails:

```text
-ForceUpdate requires -ForceCredentialOverwrite. Updating an existing connection sends
the whole object, so the stored credential is replaced by whatever this run can supply -
and Azure DevOps will not give the old value back.
```

One switch is a habit. Two, with different names, is a decision — and the second one
names the consequence rather than the action.

## 6. Nothing leaves without redaction

| Stage | Control |
| --- | --- |
| Report and receipt | `Remove-SensitiveValue` replaces a value whose **property name** looks credential-shaped. |
| Error messages | `Remove-SecretFromText` masks authorization headers and credential-shaped assignments. |
| Progress output | Reports what happened, never a value. A connection receipt names the credential *kind*, not the credential. |

Redaction matches on the **name**, not the value, and that is the important part: a
weak password does not look like a secret, but its property name always does.

## 7. The sensitive data gate

`scripts/Test-NoSensitiveData.ps1` runs in `Invoke-Tests.ps1` and in CI. Two layers:

| Layer | Contents | Committed |
| --- | --- | --- |
| Structural rules | Token formats, private address ranges, internal DNS suffixes, workstation paths, UNC paths, email addresses outside the placeholder domains, credential-shaped assignments | Yes |
| Deny list | Literal organization names, host names, project code names | **No** — `.local/sensitive-terms.txt` |

The split matters. Organization names and host names are themselves sensitive, so they
must not be committed inside the script that looks for them. The structural rules work
without the deny list; when the list is absent the gate says so, so a silent pass is
never mistaken for a full scan.

Each rule may carry an allow list for deliberate placeholders — `contoso.local`,
`@contoso.com`, a value that is a variable rather than a literal. When a finding is a
false positive, narrow the allow expression. Never widen the rule to make it go away.

## 8. Minimum token scopes

| Module | Scopes |
| --- | --- |
| `team-provisioning` | Work Items (read & write); Project and Team (read, write & manage); Graph (read); Identity (read & manage) |
| `variable-group-configuration` | Variable Groups (read, create & manage); Project and Team (read) |
| `service-connection-provisioning` | Service Connections (read, query & manage); Project and Team (read) |

A token grants no permission its account does not already hold. Use the shortest
expiry that covers the change window, and replace rather than extend.

Nothing here can inspect the scopes it was handed, so this is documented rather than
enforced — [risk 12](../process/risk-register.md).

## 9. What is never in a commit

Tokens, passwords, private keys, membership lists, host names, IP addresses, customer
or employer names, execution reports.

If one does reach a commit, rotate it first and worry about the history afterwards. A
credential in a pushed commit is compromised the moment it is pushed, whatever happens
next.
