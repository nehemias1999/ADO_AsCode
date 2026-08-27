# service-connection-provisioning

**Purpose.** Create SSH/SFTP Service Connections from a declaration, without ever
overwriting a credential that already exists.

**Scope.** Service Connections of type `ssh`. Creation only — see section 5.

**Audience.** Whoever operates the automation, and whoever reviews its plan.

**Related documents**

- [Full guide](../../docs/guides/service-connection-provisioning.md) — field-by-field contract and rollback
- [Security model](../../docs/reference/security-model.md) — the sentinel, and the two force switches
- [Azure DevOps notes](../../docs/reference/azure-devops-notes.md) — why a rename is manual

## 1. The constraint that shapes this module

Azure DevOps never returns a stored Service Connection credential on a `GET`, and the
only update route is a full-object `PUT`. So a read-modify-write cycle sends a null
credential over whatever the owner configured — and there is no way to detect that
from the response, because the response looks fine.

Everything below follows from that one fact.

| Situation | What happens | Why |
| --- | --- | --- |
| Connection absent | Created. Uses a private key if one is available, otherwise a password, otherwise the sentinel `PENDING_OWNER_CONFIGURATION`. | Nothing exists, so nothing can be destroyed. |
| Connection present | `protected`. Not modified. | A full `PUT` would replace a credential this automation cannot read. |
| Connection present, both force switches supplied | `pending` update, with the payload described in the plan. | An explicit, acknowledged decision — not a default. |
| Connection needs renaming | Reported as manual work. Never automated. | The portal performs a partial update and preserves the credential. The API cannot. |

The private key field is omitted entirely when no key is available, rather than sent
empty: an empty `PrivateKey` declares a certificate slot Azure DevOps keeps and then
insists on having filled, which is a confusing state to hand to whoever completes the
credential.

## 2. Configuration

| File | Versioned | Purpose |
| --- | --- | --- |
| `config/service-connections.example.json` | Yes | Template. Rename to `service-connections.json`. |
| `config/service-connections.json` | **No** | Your active declaration. |
| `examples/service-connections.env.example` | Yes | The credential variable names, with no values. |
| `schemas/service-connections.schema.json` | Yes | Validated on every `validate`. |

Both the connection name and every credential variable name are derived from the same
application and environment. Derivation rather than declaration is deliberate: the
failure mode of a mismatch is silent — the connection is created with the sentinel and
the deployment fails later with an authentication error that points at the host rather
than at the naming.

`validate` prints the exact environment variable names it expects, so a credential
handover is a list somebody can act on rather than a guess.

## 3. Commands

| Command | Writes to Azure DevOps | Notes |
| --- | --- | --- |
| `validate` | No | Offline. Also prints the expected credential variable names. |
| `inventory` | No | What exists. Cannot report whether a credential is valid. |
| `plan` | No | Per connection, plus what its credential will be. |
| `smoke` | No | Plan plus the manual verification checklist. |
| `apply` | **Yes**, with `-ConfirmApply` | Creates missing connections. Never updates without both force switches. |

```powershell
.\Invoke-ServiceConnectionProvisioning.ps1 -Command validate
.\Invoke-ServiceConnectionProvisioning.ps1 -Command plan  -ApplicationKey APP_ALPHA
.\Invoke-ServiceConnectionProvisioning.ps1 -Command apply -ApplicationKey APP_ALPHA -Environment DEV -ConfirmApply
```

## 4. Personal Access Token scopes

| Scope | Why |
| --- | --- |
| Service Connections — Read, query & manage | Create and list endpoints. |
| Project and Team — Read | Resolve the project id used in the endpoint's project reference. |

## 5. Deliberately not implemented

**Renaming a connection.** This is the clearest example in the repository of a gap
that is a decision rather than an omission. The API accepts only a full-object `PUT`,
and `GET` never returns the credential, so an automated rename would send `null` over
a working credential and report success. The portal performs a partial update and
preserves it. So the plan reports the rename as `manual`, the guide says to do it in
the portal, and the code contains no rename path to reach for by accident.

**Verifying a credential.** The automation is not allowed to read it. Use *Verify* in
the portal.

**Deleting a connection.** Every writer here is additive.

## 6. Rollback

| What was applied | How to reverse it |
| --- | --- |
| Connection created with the sentinel | Delete it in **Project settings > Service connections**. Nothing depended on it yet, because it had no working credential. |
| Connection created with a real credential | Delete it after confirming no pipeline references it. The receipt records which credential kind was used, never the value. |
| Connection updated with both force switches | Not reversible from here. Azure DevOps did not return the previous credential, so it was never recorded. Have its owner set it again in the portal. That asymmetry is exactly why the two switches exist. |
