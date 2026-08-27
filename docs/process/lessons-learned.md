# Lessons learned

**Purpose.** Record what transfers to the next platform of this kind, stated generally
enough to be useful there.

**Scope.** Engineering conclusions. Azure DevOps specifics are in
[azure-devops-notes.md](../reference/azure-devops-notes.md).

**Audience.** Anyone doing this work again, here or elsewhere.

**Related documents**

- [delivery-approach.md](delivery-approach.md) — the method these conclusions come from
- [architecture.md](../reference/architecture.md) — how they are expressed in the structure

## 1. Declare, do not derive

Deriving a previous name from a naming pattern, or an exception from a heuristic, is
correct until the pattern changes — and then it is confidently wrong, which is worse
than failing.

Every identity this repository needs is written down: `previousNames` for a renamed
column, `-PreviousTeamName` for a renamed Team, `manualExclusions` for a group out of
scope. The cost is a line of configuration. The alternative is a diagnosis that sounds
authoritative and points at the wrong thing.

**Transfers as:** when an automation needs to know what something *used to be*, that
is an input, not an inference.

## 2. Documentation not tied to the code will drift, and drift silently

Prose asserting a behaviour, with nothing connecting it to the behaviour, becomes
false the first time the code changes and stays false until somebody is misled by it.

Three mitigations here, in increasing order of strength:

| Mitigation | Strength |
| --- | --- |
| A definition of done that requires updating the guide | Weak — a discipline |
| CI failing on an unindexed document or a broken relative link | Medium — checks structure, not accuracy |
| Tests asserting the contract the documents describe | Strong — the contract test fails if a module stops meeting what the guide claims |

**Transfers as:** prefer a claim a test can check to a claim only a human can.

## 3. Measure before you write

Two of this repository's central guards exist because somebody measured what the API
actually does rather than what its documentation implies:

- A Variable Group `PUT` stores an omitted value as an empty string. The intuitive
  reading — "the server keeps what it had" — is wrong, and the wrong reading deletes
  credentials while returning success.
- A Service Connection `GET` never returns its credential, so a round-trip writes
  `null` over a working one and reports success.

Both were confirmed against a disposable resource before any writer was built.

**Transfers as:** for any API operation that could destroy something, verify the
destructive case on a throwaway resource first. It costs an hour. Discovering it in
production costs considerably more, and the evidence is gone by the time anyone looks.

## 4. A monolith makes reuse happen inside a file

The codebase this one derives from grew into a single 3,000-line entry point. Nothing
was wrong with any individual addition; each was the smallest change that worked.

The cost was not readability. It was that reuse happened *within* the file — a helper
called from four places, sharing script-scope variables — so nothing had a contract,
nothing could be tested in isolation, and every change had a blast radius the size of
the file.

**Transfers as:** the unit of reuse should be a component with a contract, not a
function inside a large script. When a script grows a second unrelated responsibility,
that is the moment to split it, not later.

## 5. A test suite without a runner is not a test suite

The same codebase had four test scripts and no runner. Running them meant knowing they
existed and invoking each by hand. By the time anyone looked, several assertions were
false — asserting a catalogue version that had since been bumped, and a behaviour that
had since been deliberately reversed.

Nothing failed. The suite was simply not running, and its existence was doing the work
of confidence without providing any.

**Transfers as:** one command, in the contributing guide, executed identically by CI.
If running the tests requires knowledge, they are not part of the build.

## 6. Idempotency has to be designed for, not hoped for

Defining drift as *"the declaration differs from live state"* is the obvious choice
and it is wrong wherever anything is preserved: one undeclared column shifts every
position after it, so every run reports drift, every apply rewrites, and no run is
ever a no-op.

Defining it as *"the write would produce a different result"* makes a second apply
genuinely do nothing — which is what allows a clean re-plan to be used as the
acceptance criterion for a change.

**Transfers as:** decide what "no change needed" means before writing the comparison,
and make it a property of the payload rather than of the declaration.

## 7. Some gaps are the answer

Not automating the Service Connection rename is not a backlog item. The API cannot do
it without destroying the credential; the portal can. Writing the rename anyway — with
a warning, behind a switch — would have produced a feature whose successful path is a
silent failure.

**Transfers as:** when an operation cannot be made safe, the correct implementation is
a plan entry that says `manual` and a guide that says why. Leave no code path to reach
for by accident.

## 8. Language shapes what people check

Two vocabulary choices did more work than expected.

`protected` as a status distinct from `ok`: both mean "nothing will change", but
`protected` means "and that is a decision" — which prompts a reviewer to ask whether
it is still the right one.

Reasons written for the approver rather than for a log: `pending` on its own is not
reviewable. `Missing: backlog iteration; default Area Path. Without these the Board
fails to open with TF400509` tells the reviewer what they are approving and what
happens if they do not.

**Transfers as:** a closed status vocabulary with a distinct name per meaning, and
every operation carrying a reason a person can act on.

## 9. What would be done differently

| | |
| --- | --- |
| **Write the guards first, always** | They were written first here — deliberately, after seeing the alternative — and it is the single decision that made the rollout dull. It is easy to defer them under time pressure. |
| **Diff two plans automatically** | "Explain any change to plan output" is currently a review discipline. A tool could compare two plans and show what moved. That gap is [risk 17](risk-register.md). |
| **Model the retry path in tests** | Retry behaviour is untested, which is named as a gap rather than implied. It needs an injectable transport. |
| **Decide the deny-list boundary earlier** | The sensitive data gate splits into structural rules (committed) and literal terms (local). Getting that split wrong in either direction is bad: committing the terms leaks them, and omitting the structural rules makes the gate useless without local setup. |
