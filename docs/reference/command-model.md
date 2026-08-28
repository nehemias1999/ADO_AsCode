# Command model

**Purpose.** Define every verb, every status and every action, and state the rule that
governs when a write may happen.

**Scope.** The vocabulary shared by all three automations.

**Audience.** Anyone reading a plan or writing an automation.

**Related documents**

- [architecture.md](architecture.md) — where the plan model sits
- [verification-and-evidence.md](../process/verification-and-evidence.md) — what the plan is used for
- [report.example.md](../examples/report.example.md) — a rendered plan

## 1. Verbs

| Verb | Reads live state | Writes | Confirmation | Purpose |
| --- | --- | --- | --- | --- |
| `validate` | No | No | — | Configuration against its schema, plus invariants a schema cannot express. |
| `inventory` | Yes | No | — | What exists today, without reference to the declaration. |
| `plan` | Yes | No | — | Classify every operation. The artefact somebody approves. |
| `smoke` | Yes | No | — | Plan plus the manual verification checklist. |
| `apply` | Yes | **Yes** | `-ConfirmApply` | Create and reconcile. |
| `reconcile` | Yes | **Yes** | `-ConfirmApply` | Correct an existing application. Refuses to create. |
| `rename` | Yes | **Yes** | `-ConfirmApply -ConfirmRename` | Rename a Team and its Area Path. |

Without its confirmation switch, a writing verb is a **pure simulation** and says so:

```text
[team-provisioning] Simulation only: 'apply' requires -ConfirmApply. Nothing was modified.
```

The report is still written, so a simulated apply is a usable review artefact.

## 2. Status

Five values, closed. A free-text status is how a plan becomes prose nothing can
enforce — in particular, `apply` cannot refuse a status it does not recognise.

| Status | Means | Appears in the summary |
| --- | --- | --- |
| `ok` | Live state already matches. Nothing to do. | Counted, not listed. |
| `pending` | A change is required and is safe to make. | Listed. |
| `warning` | Will proceed, but a person should read the reason. | Listed. |
| `protected` | Deliberately not changed, to avoid destroying something. | Listed. |
| `blocked` | Cannot proceed, and stops the whole apply. | Listed first. |

### `ok` versus `protected`

Both mean nothing will change, and the difference matters.

- `ok` — the live state is what the declaration asks for.
- `protected` — the live state is **not** what the declaration asks for, and the
  automation is deliberately leaving it alone.

`protected` is an invitation to check whether the decision behind it still holds. A
Variable Group key holding a value that is neither absent nor the sentinel is
`protected`, not `ok`, because somebody chose that value and the declaration disagrees.

### `blocked` stops everything

Not just that operation. `apply` calls `Assert-PlanApplicable`, which throws with every
blocked operation listed:

```text
Apply refused: the plan has 1 blocked operation(s).
  - Work Item type 'Issue': State(s) 'Committed' are mapped by the column template but
    do not exist in the project process.
```

The reason is that a plan is approved as a whole. Applying the applicable half produces
a state nobody declared and nobody reviewed.

## 3. Action

What would happen to the resource. Also closed.

| Action | Means |
| --- | --- |
| `create` | Does not exist; will be created. |
| `exists` | Present and already correct. |
| `adopt` | Present, created outside this repository, brought under management unchanged. |
| `update` | A property will be changed. |
| `set` | A value will be written into an existing container. |
| `add` | A member or child will be added. |
| `reconcile` | A collection will be rewritten to match the declaration. |
| `rename` | Will be renamed. |
| `authorize` | A permission or access grant will be given. |
| `validate` | A check with no possible write. |
| `resolve` | A human must resolve an ambiguity before anything can proceed. |
| `manual` | Deliberately not automated; a person performs it. |
| `skip` | Intentionally out of scope for this run. |

`manual` is worth distinguishing from `resolve`. `resolve` means *something is wrong,
fix it and re-plan*. `manual` means *this is correct, and a person does it* — a Service
Connection rename, or a secret whose owner completes it in the portal.

## 4. Combinations you will see

| Action + status | Meaning |
| --- | --- |
| `create` + `pending` | Normal. It will be created. |
| `exists` + `ok` | Normal. Nothing to do. |
| `exists` + `protected` | Present, differs from the declaration, deliberately untouched. |
| `set` + `blocked` | The write is understood but cannot be performed safely. The reason says why. |
| `manual` + `warning` | Correct, and waiting on a person. |
| `resolve` + `blocked` | Ambiguous. A person decides before anything proceeds. |
| `rename` + `warning` | Will proceed, and the consequence is irreversible. Read the reason. |

## 5. The summary line

```text
Plan for 'APP_ALPHA' (plan): 12 operation(s) - ok 11, pending 1, warning 0, protected 0, blocked 0.
```

Then the operations that need attention, grouped, `blocked` first. Operations that are
`ok` are counted but not listed: on an idempotent re-run they are almost the entire
plan, and printing hundreds of "already correct" lines is what trains people to stop
reading the output.

When a group has more operations than the display limit, the count that was omitted is
stated:

```text
    ... 7 more pending operation(s) not listed; see the report file.
```

A silent cap reads as full coverage. This one is never silent.

## 6. Narrowing a run

| Parameter | Effect |
| --- | --- |
| `-ApplicationKey` | One application. **Required** by every writing verb, and enforced before any credential is read. |
| `-Environment` | One environment, where the module has environments. |
| `-ConfigurationPath`, `-ScopePath`, `-CsvPath`, `-BoardColumnsPath` | Override a declaration file. |
| `-ReportPath` | Override where evidence is written. |
| `-EnvFile` | One or more environment files, comma or list separated. |

Which verbs require it, per module — the table above states the rule, this states the
enforcement:

| Module | Requires `-ApplicationKey` | Does not |
| --- | --- | --- |
| `team-provisioning` | `plan`, `smoke`, `apply`, `reconcile`, `rename` | `validate`, `inventory` |
| `variable-group-configuration` | `apply` | `validate`, `inventory`, `plan`, `smoke` |
| `service-connection-provisioning` | `apply` | `validate`, `inventory`, `plan`, `smoke` |

`inventory` may cover the whole scope, and in the two environment-aware modules so may
`plan` — surveying everything is the point of a read. Writing is narrowed to one
application, which is what keeps a plan readable and a failure attributable.

The check runs **before** the environment file is read and before the first request, so
a missing argument is reported as a missing argument rather than as a missing `.env`, and
no token is read on the way to refusing.

## 7. Exit behaviour

| Situation | Result |
| --- | --- |
| Success | Returns the plan object; exit code 0. |
| Blocked plan on a writing verb | Throws before the first write. |
| Invalid configuration | Throws during `validate`, with every error listed rather than only the first. |
| Missing credential | Throws, naming the environment variable. |
| Transient API failure | Retried with backoff on `429` and `5xx` only. A `400` or `409` is a real answer and is never retried. |
