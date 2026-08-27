# Guide: service-connection-provisioning

**Purpose.** The full contract for the Service Connections module, and a plain
explanation of why it does less than you might expect.

**Scope.** `automations/service-connection-provisioning/`. SSH/SFTP endpoints.

**Audience.** Whoever configures or operates it, and whoever holds the credentials.

**Related documents**

- [Module README](../../automations/service-connection-provisioning/README.md) — the short version
- [security-model.md](../reference/security-model.md) — the sentinel and the two force switches
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — why the rename is manual

## 1. The single constraint

Azure DevOps never returns a stored Service Connection credential on a `GET`, and the
only update route is a full-object `PUT`.

So a read-modify-write cycle sends `null` over whatever the owner configured — and
nothing in the response says so. The request succeeds. The next deployment fails to
authenticate, and the cause is three days behind you.

Every design decision below follows from that one fact.

| Situation | What happens | Why |
| --- | --- | --- |
| Connection absent | Created. Private key if available, else password, else the sentinel. | Nothing exists, so nothing can be destroyed. |
| Connection present | `protected`. Not modified. | A full `PUT` would replace a credential this automation cannot read. |
| Connection present, both force switches | `pending` update, payload described in the plan. | An explicit, acknowledged decision — not a default. |
| Connection needs renaming | Reported `manual`. Never automated. | The portal performs a partial update and preserves the credential. The API cannot. |

## 2. `config/service-connections.json`

| Field | Required | Notes |
| --- | --- | --- |
| `namePattern` | Yes | Must contain `{application}` and `{environment}`. |
| `defaults.port` | No | Default 22. |
| `defaults.grantAccessToAllPipelines` | No | Keep `false`. A connection every pipeline may use is a lateral movement path, and the pipelines that need it are known when it is created. |
| `defaults.description` | No | Template; supports the same two placeholders. |
| `credentialVariables.hostEnv` | Yes | Pattern for the environment variable holding the host. |
| `credentialVariables.usernameEnv` | Yes | Pattern for the user name variable. |
| `credentialVariables.passwordEnv` | No | Pattern for the password variable. |
| `credentialVariables.privateKeyEnv` | No | Pattern for the private key variable. |
| `applications[].key` | Yes | Application key. |
| `applications[].environments` | Yes | The environments this application actually deploys to. Listing one it does not is a credential to rotate for no benefit. |
| `applications[].port` | No | Overrides the default for this application. |

Both the connection name and every credential variable name are derived from the same
application and environment. Derivation rather than declaration is deliberate: the
failure mode of a mismatch is silent — the connection is created with the sentinel and
the deployment fails later with an authentication error pointing at the host rather
than at the naming.

## 3. Credential handover

`validate` prints the exact variable names it expects:

```text
[service-connection-provisioning] Credential variables expected in the environment:
  SFTP_APP_ALPHA_DEV: SFTP_APP_ALPHA_DEV_HOST, SFTP_APP_ALPHA_DEV_USERNAME,
                      SFTP_APP_ALPHA_DEV_PASSWORD, SFTP_APP_ALPHA_DEV_PRIVATE_KEY
```

That list is the handover: a checklist somebody can act on rather than a guess. It
needs no credentials to produce, so whoever runs it does not have to be whoever holds
them.

`examples/service-connections.env.example` is the same list with every value empty.
Copy the lines you need into your local `.env` or into pipeline secret variables.
Never fill them in there.

## 4. How the credential is chosen

In this order:

1. A private key, if `privateKeyEnv` has a value.
2. A password, if `passwordEnv` has a value.
3. The sentinel `PENDING_OWNER_CONFIGURATION`.

The private key field is **omitted entirely** when no key is available, rather than
sent empty. An empty `PrivateKey` declares a certificate slot Azure DevOps keeps and
then insists on having filled, which is a confusing state to hand to whoever completes
the credential.

Case 3 is a normal outcome, not a failure. The automation creates the structure; the
credential holder completes it in the portal; no later run overwrites what they set,
because the sentinel is the only value this repository will replace.

## 5. Commands

| Command | Writes | Requires | Notes |
| --- | --- | --- | --- |
| `validate` | No | — | Offline. Also prints the expected credential variable names. |
| `inventory` | No | — | What exists. Cannot report whether a credential is valid. |
| `plan` | No | — | Per connection, plus what its credential will be. |
| `smoke` | No | — | Plan plus the manual checklist. |
| `apply` | Yes | `-ConfirmApply` | Creates missing connections. |

`-ForceUpdate` requires `-ForceCredentialOverwrite`. Supplying the first alone fails
with an explanation rather than a syntax error.

## 6. Personal Access Token scopes

| Scope | Why |
| --- | --- |
| Service Connections — Read, query & manage | Create and list endpoints. |
| Project and Team — Read | Resolve the project id in the endpoint's project reference. |

## 7. Deliberately not implemented

**Renaming.** The clearest example in this repository of a gap being the correct
answer rather than an omission. An automated rename would send `null` over a working
credential and report success. The portal performs a partial update and preserves it.
So the plan reports `manual`, this guide says to use the portal, and there is no
rename path in the code to reach for by accident.

**Verifying a credential.** The automation is not allowed to read it. Use *Verify* in
the portal.

**Deleting a connection.** Every writer here is additive.

## 8. Rollback

| Applied | Reverse it by |
| --- | --- |
| Created with the sentinel | Deleting it in **Project settings > Service connections**. Nothing depended on it yet, because it had no working credential. |
| Created with a real credential | Deleting it after confirming no pipeline references it. The receipt records which credential *kind* was used, never the value. |
| Updated with both force switches | Not reversible from here. Azure DevOps never returned the previous credential, so it was never recorded. Have its owner set it again. That asymmetry is exactly why the two switches exist. |
