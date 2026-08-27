# ADR 0004: The shared layer carries no domain rules

**Status.** Accepted, 2026-01.

## Context

Three automations need the same things: authentication, URL construction, retry,
configuration loading, a plan model, report writing.

The natural next step is to let the shared layer do a little more each time. It already
knows how to call the API; it may as well know that a Board has columns. That step is
how a shared layer becomes the monolith described in
[ADR 0001](0001-one-module-per-automation.md) — except distributed across several files,
so it is harder to see.

## Decision

Dependencies point downward and never sideways.

| Layer | Knows | Does not know |
| --- | --- | --- |
| `Ado.Rest` | URLs, authentication, retry, error translation | That Teams or Boards exist |
| `Ado.Identity`, `Ado.Work`, `Ado.Library` | How to read and write one resource family safely | Which applications exist |
| `AdoAsCode.*` | Configuration, plans, reports | Anything about Azure DevOps |
| `automations/*` | The rules of one resource family | Anything another automation needs |

A domain module never calls another domain module. An entry point never calls another
entry point.

## Consequences

**Good.** The shared layer is small and stable. Each domain module is testable with
fixtures. Adding an automation adds no risk to the existing ones.

**Bad.** Coordination that would be natural inside a shared function moves into an
entry point — `team-provisioning` calls the identity, work and configuration modules
itself rather than one `Setup-Application`. That is where it belongs: it is the rule of
one automation, not a shared capability.

**Neutral.** Seven modules rather than one library. Real manifests with explicit exports
make the boundaries enforceable rather than conventional.
