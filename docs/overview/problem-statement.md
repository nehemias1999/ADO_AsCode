# Problem statement

**Purpose.** Explain what was wrong with configuring Azure DevOps by hand, and what
any replacement had to satisfy.

**Scope.** The problem and the requirements. The solution is described in
[capabilities.md](capabilities.md) and [architecture.md](../reference/architecture.md).

**Audience.** Anyone deciding whether this approach is worth adopting, and anyone who
needs to understand why the code refuses to do certain obvious things.

**Related documents**

- [capabilities.md](capabilities.md) — what the solution actually does
- [scope-and-limits.md](scope-and-limits.md) — what it deliberately does not do
- [lessons-learned.md](../process/lessons-learned.md) — what transfers to the next platform

## 1. The starting situation

A team project accumulates configuration the way a house accumulates keys. Teams,
Area Paths, Boards and their columns, Variable Groups, Service Connections — each one
created in the portal, by whoever needed it, on the day they needed it.

Individually each action is a two-minute job. Collectively they produce five specific
failures.

| Failure | What it looks like in practice |
| --- | --- |
| **Drift** | The same application is configured differently in DEV, QA and production. Nobody decided that; it accumulated. The difference is discovered during an incident. |
| **No reviewable intent** | The portal records that a Board column was renamed. It does not record what the columns were supposed to be, so there is nothing to compare against and nothing to approve. |
| **No dry run** | Every change in the portal is applied the instant it is made. The first time anyone sees the consequences is after they have happened. |
| **Undocumented dependencies** | A pipeline reads a variable whose name matches a Variable Group key nobody remembers declaring. Renaming either one breaks a deployment, and the connection between them exists only in somebody's memory. |
| **Onboarding by folklore** | Setting up a new application means asking the person who did the last one. The procedure exists, but only as a habit. |

None of these is dramatic on its own. Together they mean nobody can answer *"is this
project configured the way we intend?"* — which is the question that matters the
morning after something breaks.

## 2. Why the obvious fixes were not enough

| Approach | Why it falls short here |
| --- | --- |
| A written runbook | It describes the intent but cannot detect drift from it. A runbook and reality diverge silently and nobody finds out until they collide. |
| A one-off migration script | Fixes today. Says nothing about tomorrow, and is usually deleted after it runs. |
| An off-the-shelf infrastructure tool | Coverage of Azure DevOps project configuration — Boards, columns, Team membership — is thin, and the destructive edges below are not modelled at all. Bringing an existing estate under management without deleting anything is the hard part, and it is exactly the part a generic tool does not handle. |

## 3. The destructive edges that shape the design

Three properties of the Azure DevOps API turn "just automate it" into a genuine
design problem. Each has a naive implementation that appears to work and destroys
something.

| Edge | The naive implementation | What it destroys |
| --- | --- | --- |
| Board columns have no per-column route. Writing means replacing the whole collection. | Send the declared columns. | Every column somebody added but nobody declared, along with the Work Items sitting on it. |
| A Variable Group `PUT` treats an omitted value as an empty string. | Omit the secret so it is "left alone". | The secret. Invisibly, until a deployment fails to authenticate. |
| A Service Connection `GET` never returns its credential, and the only update route is a full `PUT`. | Read, modify, write. | The credential, replaced with null, while the API reports success. |

These are the reason the repository is more careful than a configuration tool
normally needs to be, and the reason several capabilities are deliberately absent
rather than merely unimplemented. See
[azure-devops-notes.md](../reference/azure-devops-notes.md) for the full list with
symptoms.

## 4. Requirements

What any replacement had to satisfy:

| # | Requirement | How it is met |
| --- | --- | --- |
| 1 | Intent is declared, versioned and reviewable. | Configuration is JSON and CSV with a schema, reviewed as a diff. |
| 2 | Nothing is written before a human has read what would change. | `plan` before `apply`, and `apply` refuses a blocked plan. |
| 3 | Nothing is deleted. | Every writer is additive; undeclared state is preserved. |
| 4 | No credential is ever committed. | Configuration declares the *name* of an environment variable, never its value. |
| 5 | A second run changes nothing. | Idempotency is the acceptance criterion for a change, not a nice property. |
| 6 | An interrupted run leaves a usable record. | The receipt is written after every completed operation. |
| 7 | It runs on a locked-down workstation and on a build agent, unchanged. | No runtime dependency beyond Windows PowerShell 5.1. |
| 8 | Onboarding is a document, not a person. | [getting-started.md](../guides/getting-started.md) and [end-to-end-walkthrough.md](../guides/end-to-end-walkthrough.md). |

## 5. What success looks like

The question in section 1 becomes answerable by running a command:

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA
```

A plan in which every operation is `ok` means the live configuration matches the
declared one. That is the whole point, and it is why idempotency is treated as an
acceptance criterion rather than an optimisation — see
[0006-idempotency-as-acceptance-criterion.md](../adr/0006-idempotency-as-acceptance-criterion.md).
