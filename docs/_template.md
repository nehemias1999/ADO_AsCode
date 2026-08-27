# Title: the result, not the topic

**Purpose.** One sentence. What question does this document answer?

**Scope.** What it covers, and what it deliberately does not.

**Audience.** Who is expected to read it, and what they already know.

**Related documents**

- [Previous document in the flow](../README.md) — why you would have read it first
- [Next document in the flow](../README.md) — where to go after this

## 1. First section

Body in numbered sections. Prefer a table to a paragraph whenever the content is a
set of cases, rules or mappings — which it usually is.

| Case | Result | Why |
| --- | --- | --- |
| ... | ... | ... |

## 2. Second section

State the reason, not only the rule. A rule with no reason attached is the first
thing somebody removes when it becomes inconvenient, and the second thing they
reinstate after an incident.

## Acceptance criteria

Where the document describes work rather than a contract, close with how anyone can
tell it was done.

---

**Format rules for this repository**

1. Purpose, Scope, Audience and Related documents at the top. A reader must be able
   to tell in ten seconds whether this is the document they need.
2. Numbered sections. Tables over prose.
3. A date only in historical or decision records — a changelog entry, an ADR. A
   contract with a date on it looks stale the moment it is correct.
4. Concrete references: file paths, command names, configuration keys.
5. **An unindexed document is treated as incomplete.** Link it from
   [docs/README.md](README.md) in the same change that creates it. Continuous
   integration checks this, so an unlinked document fails the build rather than
   quietly rotting.
