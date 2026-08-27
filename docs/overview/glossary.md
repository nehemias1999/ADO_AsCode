# Glossary

**Purpose.** Define the terms used across this repository, so a reader is never left
guessing whether a word means the Azure DevOps concept or a local one.

**Scope.** Azure DevOps vocabulary as it is used here, plus the terms this repository
introduces.

**Audience.** Anyone reading a plan, a guide or the code for the first time.

**Related documents**

- [command-model.md](../reference/command-model.md) — the verbs and statuses in detail
- [conventions.md](../reference/conventions.md) — how names are derived

## 1. Azure DevOps concepts

| Term | Meaning here |
| --- | --- |
| **Organization** | The `dev.azure.com/<organization>` container. Assumed to exist. |
| **Team project** | The project holding Teams, Boards, Variable Groups and connections. Assumed to exist. |
| **Team** | A named group with a Board and a set of Area Paths. Creating one creates a security group; it does **not** produce a working Board on its own. |
| **Area Path** | A classification node that assigns a Work Item to a part of the project. Renaming one rewrites `System.AreaPath` on every Work Item below it. |
| **Iteration Path** | A classification node representing a sprint. Creating the node and subscribing a Team to it are two separate operations. |
| **Backlog iteration** | The iteration a Team treats as the root of its backlog. Unset, the Board fails to open with `TF400509`. |
| **Team field** | The Area Path values a Team owns. `defaultValue` is stamped on new Work Items; `values` decides what appears on the Board. |
| **Board** | The card view of one Work Item type for one Team. |
| **Board column** | A column on that Board. Carries Work Items, so losing one loses work. There is no per-column API route: writing means replacing the whole collection. |
| **`columnType`** | `incoming`, `inProgress` or `outgoing`. Exactly one incoming, first; exactly one outgoing, last. |
| **`stateMappings`** | Which Work Item state a column corresponds to, per type. State names come from the project process, not from this repository. |
| **`itemLimit`** | Work-in-progress limit on a column. `0` means no limit. |
| **Variable Group** | A named set of key/value pairs a pipeline can link. A key may be marked secret, after which its value is never returned by the API. |
| **Service Connection** | A stored credential a pipeline uses to reach something outside Azure DevOps. Its credential is never returned by a `GET`. |
| **Personal Access Token (PAT)** | The credential this repository authenticates with. Grants no permission its account does not already hold. |
| **Process** | The Work Item type and state definitions of the project. This repository reads it and never modifies it. |
| **`TF400509`** | The error a Board returns when its Team is missing a backlog iteration, an Area Path, or a team field value. |

## 2. Terms this repository introduces

| Term | Meaning |
| --- | --- |
| **Automation** | One module under `automations/`, owning one resource family, with one entry point. |
| **Foundation** | The shared layer under `foundation/modules/`. Carries no domain rules. |
| **Declaration** | The versioned configuration describing the intended state. |
| **Plan** | A flat list of operations, each with a resource, a name, an action, a status and a reason. Written by `plan`; approved by a person. |
| **Operation** | One row of a plan, describing one resource. |
| **Action** | What would happen: `create`, `exists`, `update`, `set`, `add`, `reconcile`, `rename`, `authorize`, `validate`, `resolve`, `manual`, `skip`, `adopt`. |
| **Status** | Whether it may proceed: `ok`, `pending`, `warning`, `protected`, `blocked`. |
| **`protected`** | Deliberately not changed, to avoid destroying something. Distinct from `ok`, which means nothing needs changing. |
| **`blocked`** | Cannot proceed, and stops the entire apply — not only this operation. |
| **Sentinel** | The literal `PENDING_OWNER_CONFIGURATION`. The only value an automation will overwrite. |
| **Drift** | A difference between the declaration and the live state that a write would change. Defined against the payload that would be sent, not against the declaration alone — see [0006](../adr/0006-idempotency-as-acceptance-criterion.md). |
| **Adopt** | Bring an existing resource under management without modifying it. |
| **Receipt** | `*.receipt.json`. Written after every completed operation, so an interrupted run still records what finished. |
| **Report** | The plan or result as JSON plus a Markdown sibling, redacted at the writer. |
| **Smoke** | The manual verification checklist for after an apply. Deliberately performed by a person. |
| **Idempotent** | A second run produces no change. Here it is the acceptance criterion for a change, not a nice property. |
| **`previousNames`** | The names a Board column used to have. Transitional: it is how a rename reuses the existing column id so the Work Items follow. |
| **Forbidden key** | A Variable Group key that must not exist in a given environment. Asserted, because the agent exposes every key as a process environment variable. |

## 3. Words used precisely

| Word | Means | Does not mean |
| --- | --- | --- |
| **Declared** | Present in a versioned configuration file. | Present in Azure DevOps. |
| **Live** | Present in Azure DevOps right now. | Correct. |
| **Preserved** | Left in place although nothing declares it. | Approved. |
| **Verified** | A person or a test confirmed the outcome. | The API returned 200. |
| **Manual** | Deliberately performed by a person. | Not yet automated. |
