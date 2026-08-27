# ADR 0001: One automation is one visible module

**Status.** Accepted, 2026-01.

## Context

The codebase this repository derives from grew into a single entry point of roughly
3,000 lines, covering Teams, Boards, Service Connections, Work Items, reporting and an
external tracker.

No individual addition was wrong. Each was the smallest change that worked. The cost
appeared later, and it was not readability:

- Reuse happened *inside* the file. A helper called from four places shared script-scope
  variables, so nothing had a contract and nothing could be tested alone.
- Every change had a blast radius the size of the file.
- The command surface accumulated selectors, so one verb meant different things
  depending on which parameters were supplied.

## Decision

One automation is one directory under `automations/`, with one entry point, its own
configuration, its own schema, its own guide and its own tests. A new capability is a
new module, never a new command on an existing entry point.

The full contract is in [automation-contract.md](../reference/automation-contract.md).

## Consequences

**Good.** A module can be read, tested and reviewed alone. A failure is attributable.
The contract is enforced by a test rather than by a habit.

**Bad.** Some duplication between modules — three entry points each parse an
environment file list and resolve a report path. That is accepted: the alternative is a
shared layer that knows which module is calling it, which is a monolith with extra
steps.

**Neutral.** Three command surfaces to learn instead of one. They are deliberately
identical in shape, which is what the shared command model is for.
