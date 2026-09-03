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

## 2b. Where the credential is allowed to go

The organization URL is **lower trust than the token**. The token comes from a secret
store; the URL comes from a `.env` file or a pipeline parameter. Since the URL decides
which host receives the `Basic` header, it is validated before a context is built:

| Rule | Enforced by |
| --- | --- |
| Scheme must be `https` | `Assert-AdoOrganizationUrl` |
| Host must be `dev.azure.com`, `<organization>.visualstudio.com`, or one named in `-AllowedHost` | `Assert-AdoOrganizationUrl` |
| The identity host is derived from the same URL, never hardcoded | `Get-AdoIdentityUrl`, read by `New-AdoUri` |
| The organization may be pinned, so the right host is not enough | `expectedOrganizationEnv` in `project-context.json`, checked by `Get-AdoContext` |

Without the host rule only the last path segment was inspected, so
`https://attacker.example/dev.azure.com/contoso` was accepted and resolved to
organization `contoso`. Every `Core` request then went to `attacker.example` with the
token attached, while the `Identity` requests went to the real service — so the run
partly succeeded and looked legitimate.

The identity host was the other half of that. It was the literal
`https://vssps.dev.azure.com/<org>` whatever the organization URL said, so an
**on-premises** token was attached to a request aimed at Microsoft's cloud — the same
disclosure, reached from the opposite direction, and again with the run partly
succeeding because the `Core` calls went to the right place. Both bases are now derived
from the one URL the allowlist approved, so there is no second host the token can reach.

The legacy domain is matched as a single anchored label. A suffix test also accepted
`anything.delegated.contoso.visualstudio.com`, which is one delegated label away from a
host this repository would hand the token to.

**A host allowlist cannot say *which organization*.** Every organization on
`dev.azure.com` shares one permitted host, so a mistyped or tampered `ADO_ORG_URL`
naming somebody else's organization passes every rule above. Declaring
`expectedOrganizationEnv` closes that: the run refuses when the URL resolves to an
organization the configuration does not name. It is opt-in by presence of a value, and
per [ADR 0003](../adr/0003-configuration-declares-secret-names.md) the configuration
declares the variable's **name** — the organization name is itself sensitive and stays
out of Git.

Azure DevOps Server does not use those host names. `-AllowedHost` is a parameter rather
than a configuration field on purpose: trusting a host with a credential should be
visible in a diff at the call site.


## 3. The sentinel

`PENDING_OWNER_CONFIGURATION` is the only **non-secret** value an automation will
overwrite.

Secrets are a separate rule, because they are invisible: Azure DevOps never returns a
stored secret, so the sentinel comparison cannot be performed on one. See section 4b.

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

## 4b. How a secret is resolved when it has to be re-posted

A Variable Group `PUT` sends the whole object, so writing one non-secret key means
re-posting every secret in the same request. The value comes from the environment, and
**which** variable it comes from is the safety question.

| Live secret in the group | Resolved from | If not found |
| --- | --- | --- |
| `APP_SERVER_PASSWORD` in the DEV group | `APP_SERVER_PASSWORD_DEV` | Blocked |
| `APP_SERVER_PASSWORD` in the PROD group | `APP_SERVER_PASSWORD_PROD` | Blocked |
| the same, with `-AllowUnqualifiedSecretName` | `APP_SERVER_PASSWORD_<ENV>`, then `APP_SERVER_PASSWORD` | Blocked |

The qualification exists because the group name carries the environment
(`groupNamePattern`) and the secret's own name does not. With an unqualified lookup, a
stale or DEV-valued `APP_SERVER_PASSWORD` sitting in `.env` was written over the **PROD**
secret by any `apply` that touched a non-secret key in that group — and since the live
value cannot be read back, nothing could detect it. The API reported success.

`-AllowUnqualifiedSecretName` exists for a credential genuinely shared across
environments. It is opt-in rather than the default because the failure mode of guessing
wrong is silent and unrecoverable: nobody learns until a deployment fails to
authenticate, and the previous value is gone.

**Blocked, never blanked.** A secret with no resolvable value is left out of the
resolution map, which makes `New-AdoVariableGroupPayload` refuse the write rather than
send an empty string. Three independent checks enforce that, and the payload's secret
count must match the group's.

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

### How the name is matched

The pattern has two halves, because one unanchored list of words is wrong in both
directions at the same time.

| Half | Matches | Examples |
| --- | --- | --- |
| Long, unambiguous tokens | Anywhere in the name, case-insensitively — which is what covers camelCase | `password`, `secret`, `token`, `apikey`, `privatekey`, `sshkey`, `passphrase`, `connectionstring`, `signature` |
| Short tokens that are also common substrings | Only as a whole name or a whole `_`/`-` delimited segment | `pat`, `key`, `sas`, `cert`, `auth`, `bearer` |

The second half exists because of a real defect: an unanchored `pat` matched
`areaPaths`, `iterationPaths`, `reportPath`, `patch` and `compatible`, so every
`team-provisioning` inventory report replaced its Area Path and Iteration Path
inventory — the data the report exists to carry — with `[redacted]`, and said nothing.
Over-redaction is not the safe direction of this bug; it is the direction nobody
notices, because the artefact still looks well-formed.

### What this does not catch

Name matching cannot see a credential that arrives in a field with an innocent name.
The plan and receipt schema uses `value`, `reason`, `detail` and `message`, none of
which match, so a secret interpolated into free-text prose is written verbatim. Two
consequences follow, and both are live:

- Do not interpolate a value into a plan `reason`. Describe the difference instead.
- A future change should honour the `isSecret` flag that sits next to the value in a
  Variable Group payload, and add a value-shape check for high-entropy strings and PEM
  headers. Redaction by name is a first layer, not the whole control.

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
