# Delivery approach

**Purpose.** Describe how a platform like this is brought under configuration
management, stage by stage, so the method can be reused rather than rediscovered.

**Scope.** The engineering process from an unmanaged estate to a verified one. The
resulting design is in [architecture.md](../reference/architecture.md).

**Audience.** Anyone doing this work on another platform, and anyone reviewing how it
was done here.

**Related documents**

- [problem-statement.md](../overview/problem-statement.md) — what the work started from
- [verification-and-evidence.md](verification-and-evidence.md) — how each stage was shown to be complete
- [lessons-learned.md](lessons-learned.md) — what would be done differently

## 1. Shape of the method

Seven stages. Each has inputs, activities, outputs and an exit criterion, and the exit
criterion is always something observable rather than a judgement.

The ordering carries one non-obvious constraint: **nothing is written until stage 5**,
and stage 5 touches one application in the lowest environment. Four stages of reading
before the first write is not caution for its own sake — it is what makes the first
write boring.

| # | Stage | Writes? |
| --- | --- | --- |
| 1 | Discovery and inventory | No |
| 2 | Cataloguing the desired state | No |
| 3 | Designing the automation contract | No |
| 4 | Building the shared layer | No |
| 5 | Pilot | Yes, one application |
| 6 | Controlled rollout | Yes, one application per run |
| 7 | Verification and handover | No |

## 2. Stage 1 — Discovery and inventory

| | |
| --- | --- |
| **Inputs** | Read access to the organization. A token with read scopes only. |
| **Activities** | Enumerate every resource in scope through the REST API. Record what exists, not what should. Note where environments differ from each other — the differences are the finding, not noise. |
| **Outputs** | A read-only inventory. In this repository that became `-Command inventory`, which is the same operation, kept. |
| **Exit criterion** | The inventory runs end to end and its counts agree with the portal. |

The discovery step became a permanent command rather than a throwaway script,
deliberately. It is the same question — *what is actually there?* — and it is asked
again every time something looks wrong.

## 3. Stage 2 — Cataloguing the desired state

| | |
| --- | --- |
| **Inputs** | The inventory, and whoever knows why each resource exists. |
| **Activities** | Write the intended state as versioned data, with a schema. Where live state and intent disagree, decide which is right and record the decision. Where nobody knows why something exists, say so rather than declaring it. |
| **Outputs** | The configuration files and their JSON Schemas. |
| **Exit criterion** | The declaration validates offline, and a person who was not involved can read it and say what the platform is supposed to look like. |

Two rules were set here and never relaxed:

- **Declare, do not derive.** A previous name, an exception, a scope boundary is
  written down. Deriving an identity from a naming pattern produces confident, wrong
  answers the moment the pattern changed.
- **Names, not values.** Configuration holds the *name* of the environment variable
  carrying a secret. This is what allows the whole declaration to be committed.

## 4. Stage 3 — Designing the automation contract

| | |
| --- | --- |
| **Inputs** | The catalogue, and the API's destructive edges from stage 1. |
| **Activities** | Define what every automation must provide, the command vocabulary, and the plan model. Decide what will never be automated. |
| **Outputs** | [automation-contract.md](../reference/automation-contract.md), [command-model.md](../reference/command-model.md). |
| **Exit criterion** | Two different resource families can be expressed in the same contract without special cases. |

The exit criterion matters more than it sounds. A contract validated against one
module is a description of that module. Boards and Variable Groups have almost nothing
in common, so a vocabulary that fits both is likely to fit a third.

## 5. Stage 4 — Building the shared layer

| | |
| --- | --- |
| **Inputs** | The contract. |
| **Activities** | Build transport, identity, work-tracking and library modules with no domain rules in them. Cover the dangerous logic with tests before any of it runs against a live organization. |
| **Outputs** | `foundation/modules/`, and the tests. |
| **Exit criterion** | The tests pass, and the shared layer contains no reference to any specific application. |

The order here is the point: the guards were written and tested **before** the first
apply, not after the first incident. Board column reconciliation and Variable Group
writing were both fully covered by offline tests while the code had never once been
run against a real project.

## 6. Stage 5 — Pilot

| | |
| --- | --- |
| **Inputs** | One application, the lowest environment, a reviewed plan. |
| **Activities** | `validate`, `plan`, review with whoever owns the project, `apply`, re-plan, manual smoke. |
| **Outputs** | One correctly configured application, a receipt, and a list of everything the plan did not predict. |
| **Exit criterion** | The re-plan comes back entirely `ok`, and the manual checklist passes. |

The list of surprises is the real output. Anything the plan did not predict is a gap in
the plan, and it is fixed in the code before stage 6 — not worked around by hand.

## 7. Stage 6 — Controlled rollout

| | |
| --- | --- |
| **Inputs** | The pilot, corrected. |
| **Activities** | One application per execution, lowest environment first. Read every plan. Stop on the first surprise and fix the cause. |
| **Outputs** | The estate under management, one receipt per application. |
| **Exit criterion** | Every application in scope re-plans clean. |

One application per run is not slower in any way that matters. It is the difference
between "the rollout failed" and "APP_BETA in QA failed for this reason".

## 8. Stage 7 — Verification and handover

| | |
| --- | --- |
| **Inputs** | The applied estate. |
| **Activities** | Re-plan everything. Reconcile the declaration against anything that has drifted since. Write the guides. Hand over the credential list produced by `validate`. |
| **Outputs** | A clean plan across the estate, and documentation somebody can operate from without asking a person. |
| **Exit criterion** | Somebody who was not involved provisions a new application from the guides alone. |

That last criterion is the only honest test of documentation. Everything else measures
whether the author understood it.

## 9. What was deliberately not done

| Not done | Why |
| --- | --- |
| A big-bang migration | Nothing forces every application to move at once, and a staged rollout keeps every failure attributable. |
| Automating the destructive operations | See [scope-and-limits.md](../overview/scope-and-limits.md). Some gaps are the answer. |
| Fixing drift found during discovery, while discovering | Stage 1 writes nothing. Mixing observation with correction means never being sure what the starting state was. |
| Deferring the tests until after the rollout | The guards exist to make the rollout safe. Written afterwards, they would only document what already happened. |
