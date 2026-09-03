# Verification and evidence

**Purpose.** Describe how a change is shown to have worked, and what artefact proves
each claim.

**Scope.** Verification of a change to the platform. Verification of a change to the
code is in [testing-strategy.md](testing-strategy.md).

**Audience.** Whoever applies a change, whoever approves it, and whoever audits it
later.

**Related documents**

- [command-model.md](../reference/command-model.md) — the verbs producing these artefacts
- [0006-idempotency-as-acceptance-criterion.md](../adr/0006-idempotency-as-acceptance-criterion.md) — why a clean re-plan is the criterion
- [report.example.md](../examples/report.example.md) — what the artefacts look like

## 1. Four artefacts, four questions

| Artefact | Answers | Written |
| --- | --- | --- |
| Plan | What was about to happen? | Before any change. |
| Receipt | What actually happened? | After **every** completed operation. |
| Re-plan | Did it land, completely? | After the change. |
| Manual checklist | Does it work for a person? | By a person. |

Each answers a different question, and none substitutes for another. A successful
apply says the API accepted the requests; only the re-plan says the live state now
matches the declaration, and only the checklist says a human can use it.

### Who, and from which commit

The plan and the receipt each carry a **provenance** block: a `runId`, the identity
behind the access token, the operating-system user, the machine or build, and the
commit SHA of the declarations the run was made from.

That last field is the one the set was missing. The premise of this repository is that
configuration is versioned in Git, and until it was recorded there was no way to answer
*this PROD Variable Group looks like this because of which commit?* — reconstructing it
meant finding the build by date and reading its commit. The `runId` is what joins a log
line to a report to a receipt, so a receipt that has been detached from its build and
pasted into a ticket still names the change it came from.

Every field is best-effort and any may be absent. Nothing in the block may fail a run:
the evidence is worth less than the change it records, so an apply never stops because
it could not read a SHA. `commitOrigin` distinguishes *there is no commit* from *nobody
looked*.

One consequence worth stating: `runId` is new on every run, so two `plan` reports for
unchanged input are no longer byte-identical. `generatedAt` already had that property.
Idempotence is a claim about the **operations**, which is what the re-plan reads.

## 2. The plan is the approval artefact

A plan is a flat list of operations, each with a resource, a name, an action, a status
and a reason. It is reviewed the way a diff is reviewed, and for the same purpose: to
see the intent before the consequence.

Three properties make it usable as an approval record:

| Property | Why it matters |
| --- | --- |
| Complete, not only the delta | Operations already satisfied appear as `ok`. A reviewer sees the intended shape of the application, not just what changes today. |
| Every operation carries a reason | Written for the approver, not for a log parser. `pending` with no explanation is not reviewable. |
| Truncation is announced | When more operations exist than are listed, the summary says how many were omitted. A silent cap reads as full coverage. |

It is written to `artifacts/` as JSON and as Markdown, from the same sanitized object,
so the two cannot disagree.

## 3. The receipt is incremental, and that is the point

`Save-AdoAsCodeReceipt` is called after every completed operation, not once at the
end. The cost is a file write per operation. What it buys:

| Scenario | Without an incremental receipt | With one |
| --- | --- | --- |
| Token expires mid-apply | You know it failed. You do not know how far it got. | The receipt lists exactly which operations completed, and its status stays `in_progress`. |
| Agent recycled | Same. | Same. |
| Apply succeeds | No difference. | No difference. |

An interrupted run is therefore a **resume**, not a guess. The instruction in every
guide — *do not re-run apply blindly after a failure; read the receipt first* — only
works because the receipt is accurate at the moment of failure.

The receipt records what was done, never a value. A Service Connection receipt says
which credential *kind* was used; a Variable Group receipt says how many secrets were
re-posted. Both pass through redaction on the way to disk.

## 4. Idempotency is the acceptance criterion

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command plan -ApplicationKey APP_ALPHA
```

A change is done when this comes back with nothing `pending` and nothing `blocked`.
Not when the apply exits zero.

The distinction is not pedantic. An apply can succeed on every request and still leave
the platform different from the declaration — a step that was skipped, a resource that
was created with the wrong name, an operation the plan never modelled. The re-plan is
the only check that compares the two.

This is also why drift is defined as *"the write would produce a different result"*
rather than *"the declaration differs from live state"*. Under the second definition,
a Board carrying one column nobody declared reports drift forever, every apply rewrites
it, and no run is ever a no-op — which makes idempotency unusable as a criterion. See
[0006](../adr/0006-idempotency-as-acceptance-criterion.md).

## 5. The independent read-back

`inventory` reads live state and reports it without reference to the declaration. Use
it when a plan says something surprising: it answers *what is actually there?* rather
than *how does it compare?*, and the two questions fail differently.

## 6. The manual checklist stays manual

`-Command smoke` generates the checks a person has to perform:

1. The Team appears with its members.
2. The Board shows the expected columns, in order, including any that were preserved.
3. Create a Work Item **as a Team member, not as the automation identity**.
4. Assign it and move it across every column.
5. Add a comment and an attachment.
6. New Work Items carry the expected Area Path.
7. Re-plan and confirm it is clean.

Step 3 is the one that cannot be automated usefully. An automated check that creates a
throwaway Work Item proves the API works, which was never in doubt. What needs proving
is that a real person can open the Board and move a card with **their own**
permissions — and the automation identity cannot answer that on their behalf.

## 7. What each claim rests on

| Claim | Evidence |
| --- | --- |
| "The change was approved." | The plan, attached to the pull request or the change record. |
| "The change was applied." | The receipt, `status: completed`. |
| "The change is complete." | The re-plan, nothing pending. |
| "The change works." | The manual checklist, performed by a Team member. |
| "Nothing was destroyed." | The plan showed no delete, because no writer can perform one. |
| "No secret was exposed." | Redaction at the report writer, plus the sensitive data gate on every commit. |
