# ADR 0002: Nothing is written without a reviewed plan and an explicit confirmation

**Status.** Accepted, 2026-01.

## Context

Configuring a platform through a portal applies every change the instant it is made.
The first time anyone sees the consequences is after they have happened, and there is
no artefact to approve beforehand or to point at afterwards.

Automation makes that worse before it makes it better: a script can do in one second
what a person would have done in twenty minutes of clicking, including the wrong thing.

## Decision

Every automation exposes a command ladder in which only the last rung writes.

```text
validate -> inventory -> plan -> smoke -> apply
```

- `plan` computes the full set of operations and writes nothing.
- `apply` recomputes the plan from live state, then refuses to run if **any** operation
  is blocked.
- Writing requires an explicit `-ConfirmApply`. Without it, `apply` is a pure simulation
  that still produces a report.
- An irreversible operation requires a second switch: `rename` also needs
  `-ConfirmRename`.

## Consequences

**Good.** A plan is a review artefact, the way a diff is for application code. A
simulated apply is a usable approval record. An operator can always answer *what would
this do?* without risk.

**Bad.** Every operation has to be classifiable before it is performed, which constrains
how the code is written: the decision must be a pure function over data rather than
something discovered mid-write. That constraint turned out to be the reason the
dangerous logic is testable at all.

**Neutral.** Two commands where a portal needs one click. In exchange, the click is
recorded and reviewable.
