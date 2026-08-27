# Frequently asked questions

**Purpose.** Answer the questions people ask before adopting this, or while reviewing
it.

**Scope.** Design and adoption. Failures are in [troubleshooting.md](troubleshooting.md).

**Audience.** Anyone evaluating the approach.

**Related documents**

- [architecture.md](../reference/architecture.md) — the structure these answers describe
- [scope-and-limits.md](../overview/scope-and-limits.md) — what is deliberately absent

## Why PowerShell and the REST API, rather than Terraform or the `az` CLI?

Three reasons, in order of weight.

1. **Coverage.** The Azure DevOps Terraform provider does not model Board columns,
   Team work settings or Team membership at the level this needs. The `az devops`
   extension covers some of it, unevenly. Both would leave the most dangerous
   operations — the ones that silently destroy something — outside the tool.
2. **Adoption without destruction.** Bringing an existing estate under management
   without deleting anything is the hard part, and it is exactly the part a
   declarative tool with a delete step does not do. Everything here is additive; a
   resource nobody declared is preserved and reported.
3. **Zero runtime dependency.** PowerShell 5.1 is already on every Windows workstation
   and on `windows-latest`. Nothing to install means nothing to get approved, which on
   a locked-down machine is the difference between a tool that runs and one that does
   not.

The trade-off is real and worth naming: no state file, no graph, no `destroy`. That is
acceptable here because the plan is computed by reading live state every time, which
is also why there is no state file to drift.

## Why one application per `apply`?

Because a plan that covers forty applications is a plan nobody reads, and a failure in
one of them is a failure nobody can attribute. One application also preserves the
blast radius that makes a pilot meaningful: apply to one application in the lowest
environment, verify, then continue.

`inventory` and `plan` happily cover the whole scope. Only writing is narrowed.

## What happens if two people apply at the same time?

Last write wins, exactly as it would in the portal. There is no locking. Run one at a
time; the receipts record who changed what and when.

Adding distributed locking would mean holding state somewhere, which is the thing this
design avoids.

## Why is there no `destroy`?

See [0005-never-delete-preserve-undeclared-state.md](../adr/0005-never-delete-preserve-undeclared-state.md).
Briefly: a plan can predict what a create will do, because the declaration says so. It
cannot predict what a delete will do, because what a resource *contains* is not in the
declaration. A Board column holds Work Items; an Area Path holds a query somebody
built a dashboard on.

## Why does the automation refuse to write a secret?

It cannot read the current value, so it cannot verify what it would replace. Writing
without being able to verify is how a working credential is silently destroyed —
which is what the API's own behaviour makes easy. See
[security-model.md](../reference/security-model.md).

## Why does a group with a secret sometimes become unwritable?

Because a Variable Group `PUT` sends the whole object and an omitted value is stored as
an empty string. To change one non-secret key, every secret has to be re-posted with a
known value. If the session does not have one, the write is refused.

That is a constraint of the API, not a limitation of this tool, and the honest response
is to say so in the plan rather than attempt a write that would blank a credential.

## Could this manage a different resource type?

Yes — as a **new automation module**, not as a command on an existing one. The
contract is in [automation-contract.md](../reference/automation-contract.md). The one
thing not to do is grow an existing entry point sideways; that is how the codebase this
one derives from ended up with a single 3,000-line script nobody could change safely.

## How do I point it at a different organization or project?

Change `ADO_ORG_URL` and `ADO_PROJECT`. Nothing else. No configuration file contains
an organization, a project, or a host name — paths are declared relative to the
project and the project segment is added at run time.

## Why is `validate` offline?

So a newcomer can check their configuration before asking anyone for a token, and so
a malformed catalogue fails in a second rather than halfway through an apply. The test
suite enforces it: the offline validation test runs with the credential variables
cleared.

## Why does the smoke test have to be done by a person?

An automated check that creates a throwaway Work Item proves the API works, which was
never in doubt. What needs proving is that a real member of the Team can open the
Board, move a card and attach a file with **their own** permissions. That is not
something the automation identity can verify on their behalf.

## Why do reports go to `artifacts/` and not into Git?

A report describes one run of one environment. It is evidence, not a contract, and it
would be stale the moment it was committed. What belongs in Git is the declaration
that produced it.

## Why does the repository contain its own secret scanner?

Because the failure it prevents is unrecoverable. A credential pushed to a public
repository is compromised the moment it is pushed, whatever happens next. A review
catches most of them; a mechanical gate catches the rest, and it runs on every commit.

The client-specific deny list lives outside version control on purpose — organization
names and host names are themselves sensitive, so they must not be committed inside
the script that looks for them.
