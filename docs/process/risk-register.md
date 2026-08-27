# Risk register

**Purpose.** Name what could go wrong, and point at the control that stops it.

**Scope.** Risks arising from automating Azure DevOps configuration. Every control
names the code or the test that implements it, so a claim here can be checked.

**Audience.** Reviewers, and anyone changing a control.

**Related documents**

- [security-model.md](../reference/security-model.md) — the credential controls in detail
- [testing-strategy.md](testing-strategy.md) — what proves the controls work
- [azure-devops-notes.md](../reference/azure-devops-notes.md) — the API behaviour behind several risks

## 1. How to read this

**Impact** is what happens if it occurs. **Likelihood** is before the control.
**Residual** is what remains after it.

A risk with a residual of *low* is not solved; it is controlled. Several residuals are
*medium* on purpose, and those are the ones worth re-reading.

## 2. Destructive change

| # | Risk | Impact | Likelihood | Control | Residual |
| --- | --- | --- | --- | --- | --- |
| 1 | A Board column is deleted, taking its Work Items | High — visible, unrecoverable work loss | High without a control: writing a Board means replacing the whole collection | `New-AdoBoardColumnPayload` preserves every undeclared column; `preserveUndeclaredColumns` must be `true` and the validator refuses otherwise. Covered by four tests. | Low |
| 2 | A renamed column becomes a duplicate, leaving its Work Items behind | Medium — confusing, needs manual repair | Medium — the fallback matcher guesses | `previousNames` matching runs before the state-mapping fallback and reuses the existing id; the fallback warns when it fires. | Low |
| 3 | The outgoing column stops being last, so the whole write is rejected | Low — nothing is written | Medium when a column is preserved | Preserved columns are re-typed and inserted before the outgoing column. Covered by a test. | Low |
| 4 | An Area Path rename rewrites `System.AreaPath` across every Work Item | High — queries and dashboards stop matching, and it is not reversible | Low — only a `rename` command reaches it | Two switches (`-ConfirmApply -ConfirmRename`); the plan marks it `warning` with the consequence stated in full. | **Medium** — it is genuinely irreversible; the control only ensures it is deliberate |
| 5 | Any resource is deleted | High | None | No delete path exists in any writer. | Low |

## 3. Credentials

| # | Risk | Impact | Likelihood | Control | Residual |
| --- | --- | --- | --- | --- | --- |
| 6 | A Variable Group secret is blanked by a write that omits it | High — a pipeline fails to authenticate, cause invisible | **High** without a control: an omitted `value` is stored as an empty string | `New-AdoVariableGroupPayload` re-posts every secret with a resolved value, and blocks if any is unresolved, empty, or would change the secret count. Four tests. | Low |
| 7 | A Service Connection credential is replaced with null by a round-trip | High — same, and `GET` never returned the old value to record | High without a control | Existing connections are `protected`; overwriting needs both force switches. | Low |
| 8 | A pre-existing configured value is overwritten by an automation | Medium — silently undoes somebody's decision | High without a control | Only the sentinel is ever overwritten. Covered by a test. | Low |
| 9 | A credential is committed | **Critical** — compromised the moment it is pushed | Medium — templates and reports are the usual routes | Configuration declares variable *names*; `.gitignore` excludes `.env`, `.local/`, `artifacts/`; redaction at the report writer; the sensitive data gate on every commit; a test asserting no `.env` template carries a credential value. | Low |
| 10 | A credential is exposed in an error message or a log | Medium | Medium | `Remove-SecretFromText` masks authorization headers and credential-shaped assignments in every error this repository raises. | Low |
| 11 | A membership list is committed | Medium — personal data in a public history | Medium | Membership is read from an environment variable at run time; the active members file is excluded. | Low |
| 12 | A token has more scope than it needs | Medium — widens the blast radius of any mistake | High — it is easier to grant everything | Minimum scopes documented per module; a token grants no permission its account lacks. | **Medium** — documented, not enforced; nothing here can check what scopes a token holds |

## 4. Correctness and process

| # | Risk | Impact | Likelihood | Control | Residual |
| --- | --- | --- | --- | --- | --- |
| 13 | A key that must not exist in an environment switches on behaviour silently | Medium to high — it appears in no pipeline definition and in no diff | Medium — the agent exposes every group variable as a process environment variable | `forbiddenKeysByEnvironment`, checked in the CSV validator and reported as blocked when present live. | Low |
| 14 | Half of an approved plan is applied | Medium — an undeclared intermediate state | Medium | `apply` refuses to run while any operation is blocked; `Assert-PlanApplicable`, covered by a test. | Low |
| 15 | An apply is interrupted and nobody knows how far it got | Medium — the next run is a guess | Medium | The receipt is written after every completed operation and stays `in_progress`. | Low |
| 16 | An apply runs against a stale plan | Medium | Medium — plans get read, then left | `apply` recomputes the plan immediately before writing, from live state. | Low |
| 17 | A configuration change breaks a plan without anyone noticing | Medium | Medium | Schemas are validated on every `validate`; the definition of done requires the plan diff to be explained. | **Medium** — the second half is a review discipline, not a check |
| 18 | The test suite rots and nobody notices | Medium — false confidence | **High**, from direct experience: the previous codebase had four test scripts, no runner, and several assertions false for weeks | One runner, `scripts/Invoke-Tests.ps1`, executed identically by CI on every push. | Low |
| 19 | Documentation drifts from behaviour | Medium — worse than no documentation | High | Definition of done requires the guide, the index and the changelog; CI fails on an unindexed document or a broken relative link. | **Medium** — accuracy of prose cannot be checked mechanically |
| 20 | Two people apply simultaneously | Low to medium — last write wins | Low | None. Documented rather than solved: run one at a time; the receipts record who changed what. | **Medium** — accepted |

## 5. The residual risks worth re-reading

Five entries above are *medium* after their control, and each is a conscious trade
rather than an oversight.

| # | Why it stays medium |
| --- | --- |
| 4 | An Area Path rename is genuinely irreversible. The control makes it deliberate; nothing can make it undoable. |
| 12 | Nothing here can inspect the scopes of the token it was handed. |
| 17 | "Explain the plan difference" is a review discipline. A tool could diff two plans, and does not yet. |
| 19 | Structure is checked mechanically; accuracy is not. |
| 20 | Locking would mean holding state, which this design avoids for stronger reasons. |
