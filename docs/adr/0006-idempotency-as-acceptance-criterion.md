# ADR 0006: A change is done when a second run does nothing

**Status.** Accepted, 2026-01.

## Context

An apply can succeed on every request and still leave the platform different from the
declaration: a step skipped, a resource created with the wrong name, an operation the
plan never modelled. Exit code zero says the API accepted what it was sent, not that the
outcome is correct.

Something has to define "done", and it has to be observable rather than a judgement.

## Decision

A change is complete when re-running `plan` reports nothing `pending` and nothing
`blocked`.

That criterion only works if the tool is genuinely idempotent, which required defining
drift carefully. The obvious definition — *the declaration differs from live state* — is
wrong wherever anything is preserved: one undeclared Board column shifts every position
after it, so every plan reports drift, every apply rewrites, and no run is ever a no-op.

So drift is defined as **the write would produce a different result**. The comparison is
made against the payload the reconciler would actually send, not against the declaration
alone.

## Consequences

**Good.** A second apply genuinely does nothing. A clean re-plan is a real acceptance
criterion, usable in a change record and by somebody who was not present. It also
catches the failure a green apply hides: an operation that succeeded without achieving
what was intended.

**Bad.** Drift detection has to build the full payload, so it is slightly more expensive
than comparing two lists, and it depends on the payload builder being pure. Both were
acceptable; the second is enforced by the payload builder having no side effects and
being covered by tests.

**Neutral.** Every guide ends the same way — *run plan again* — and every apply prints
the same reminder. The repetition is the point.
