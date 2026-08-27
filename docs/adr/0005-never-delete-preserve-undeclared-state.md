# ADR 0005: Nothing is deleted, and undeclared state is preserved

**Status.** Accepted, 2026-01.

## Context

A declarative tool normally converges: whatever is not declared is removed. That model
works when the declaration is complete and the resources are disposable.

Neither holds here.

- The estate exists before the tool. Adoption means bringing live resources under
  management without disturbing them.
- Resources contain things the declaration says nothing about. A Board column holds
  Work Items. An Area Path holds a query somebody built a dashboard on. A Variable Group
  holds a key another team added.
- The blast radius of a delete cannot be predicted from a plan, because what a resource
  *contains* is not in the plan.

Board columns make it acute: there is no per-column API route, so writing means
replacing the whole collection. The naive implementation deletes every column it did not
know about, along with the Work Items on it.

## Decision

No writer performs a delete. Anything present but not declared is **preserved** and
**reported**.

For Board columns specifically: an undeclared column is kept, re-typed to `inProgress`
if its type would invalidate the Board, and inserted before the declared outgoing column
so the outgoing column stays last.

Where removal is genuinely required, the plan reports it and a person does it in the
portal — where the portal will ask them where the contents should go.

## Consequences

**Good.** Adoption is safe: pointing this at an existing project cannot destroy
anything. A plan can be approved without auditing what each resource contains.

**Bad.** Drift accumulates in one direction. Something added by hand stays until
somebody removes it. Mitigated by reporting every undeclared resource on every plan, so
it is visible rather than forgotten.

**Neutral.** "Declared state" means *at least this*, not *exactly this*. That is a
weaker guarantee than convergence, and it is the correct one for a shared platform where
this tool is not the only actor.
