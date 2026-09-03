# Testing strategy

**Purpose.** State what is tested, what is not, and why each choice was made.

**Scope.** The automated suite and the static checks. Verification of a platform
change is in [verification-and-evidence.md](verification-and-evidence.md).

**Audience.** Contributors, and anyone judging how much the green build is worth.

**Related documents**

- [working-agreements.md](working-agreements.md) — when tests are required
- [risk-register.md](risk-register.md) — the risks these tests control

## 1. What the suite is for

Infrastructure scripts attract a particular excuse: *"it can only really be tested
against the live system."* That is true of the requests, and false of everything
worth testing. The decisions — which column matches which, whether a value may be
overwritten, whether a plan may be applied — are pure functions over data.

So the design point came first: the dangerous logic was written as pure functions
**so that it could be tested offline**, and the API calls are a thin layer around it.
The test suite is a consequence of that shape, not a bolt-on.

## 2. What is covered

| Layer | Covered by | Count |
| --- | --- | --- |
| Board column reconciliation | `tests/foundation/Ado.Work.BoardColumns.Tests.ps1` | 18 |
| Variable Group and connection write safety | `tests/foundation/Ado.Library.VariableGroups.Tests.ps1` | 31 |
| Plan model, configuration loading, evidence writing, API reference drift | `tests/foundation/AdoAsCode.Core.Tests.ps1` | 30 |
| Where a credential may be sent, and the retry policy | `tests/foundation/Ado.Rest.Tests.ps1` | 37 |
| The protections carried by every outbound request | `tests/foundation/Ado.Rest.RequestParameters.Tests.ps1` | 6 |
| The automation contract, the shipped examples, and the pipeline definitions | `tests/automations/Automations.Tests.ps1` | 29 |
| Provenance, the progress log, and provenance at every evidence write | `tests/foundation/AdoAsCode.Provenance.Tests.ps1` | 16 |

Total: **167**.

Every test in the first two files corresponds to a specific way a naive implementation
destroys something:

| Test | The failure it prevents |
| --- | --- |
| Reuses the existing column id | Work Items left behind on a duplicate column. |
| Preserves an undeclared column | A column somebody added disappearing on the next apply. |
| Keeps the outgoing column last | The entire column write rejected, with a message that names no column. |
| Blocks when both names exist | A permanent duplicate, because the reconciler never deletes. |
| Re-posts every secret | A credential blanked by a write that omitted it. |
| Blocks when a secret has no source | The same, from a different direction. |
| Refuses a nearly-equal forced value | An overwrite that should have gone to a human. |
| Refuses to apply a blocked plan | Half of an approved change being applied. |

## 3. What is not covered, and why

| Not covered | Why | What covers it instead |
| --- | --- | --- |
| Live API calls | A test needing an organization, a token and a project is a test nobody runs. | `-Command validate` and `inventory`, run by a person. |
| The HTTP layer | Testing it would mean testing a mock of Azure DevOps, which drifts from the real one and proves only that the mock matches the test. | Errors surface the service's own message, so a real failure is legible. |
| The portal | Out of scope. | The manual checklist. |
| The retry *loop* | Driving it would mean injecting failures through a mock of the transport. The **decision** it makes was extracted instead. | `Get-AdoRetryDecision`, a pure function over (method, status, `Retry-After`, attempt), with ten tests in `Ado.Rest.Tests.ps1`. |

## 4. Static checks

| Check | Catches |
| --- | --- |
| Parse check | A syntax error, before every other check reports something confusing instead. |
| PSScriptAnalyzer | Unused parameters, empty catch blocks, missing `ShouldProcess`, 5.1 incompatibilities. |
| Sensitive data gate | Credential-shaped strings, private addresses, internal host names, workstation paths, plus a local deny list. |

Any finding fails the gate, `Warning` included. That matters more than it sounds: the
four things the table above credits PSScriptAnalyzer with catching are all severity
`Warning`, so while only `Error` failed, the gate reported them and enforced none of
them. A missing analyzer is a failure too, rather than a silent skip — otherwise the
strictest half of the gate passes by doing nothing, and "it passed" stops meaning the
same thing on a workstation as in CI. `-Skip Analyzer` is the explicit opt-out.

Six rules are excluded, each with the reason recorded in
`PSScriptAnalyzerSettings.psd1`. Excluding a rule silently is how a settings file
becomes folklore; excluding one with a measurement next to it is a decision somebody
can disagree with.

## 5. Fixtures contain no real data

Every fixture is invented — `APP_ALPHA`, `col-todo`, `contoso.local`. A test that
borrows a real Team name, host name or credential turns the suite into another place
sensitive data leaks from, and test files are the last place anyone thinks to look.

The rule is enforced against itself: a fixture password is assigned from a variable
rather than written as a literal, because a credential-shaped literal in a test file
is exactly what the repository's own gate is meant to catch — and the gate should not
need an exemption for the suite that proves redaction works.

## 6. One runner

```powershell
.\scripts\Invoke-Tests.ps1
```

Parse check, static analysis, unit suite, sensitive data gate. Continuous integration
runs the identical command on `windows-latest`.

This is deliberate, and it is a lesson from the codebase this one derives from. That
repository had four test scripts and no runner. Running them meant knowing they
existed and invoking each by hand. By the time anyone looked, several assertions had
been false for weeks — asserting a version number that had since been bumped, and a
behaviour that had since been deliberately reversed. The suite was not failing; it was
not running.

A suite nobody can run in one step is a suite nobody runs. So there is one command, it
is in `CONTRIBUTING.md`, and CI executes exactly it.

## 7. Test-time dependencies only

Pester 5 and PSScriptAnalyzer are needed to run the tests. They are never needed to
run an automation, which depends on nothing beyond PowerShell itself. That separation
is what lets the automations run on a locked-down workstation where installing a
module needs an approval.

## 8. Where to add a test

| Change | Test |
| --- | --- |
| A new rule in a pure function | A case in the matching `tests/foundation/` file, named after the failure it prevents. |
| A new automation | A row in `tests/automations/Automations.Tests.ps1`, which checks the contract. |
| A new configuration file | A case asserting the shipped example satisfies its schema. |
| A new API call | Usually none. Keep the decision in a pure function and test that. |

Name a test after the failure it prevents, not after the function it calls. `reuses
the existing id of every matched column` survives a refactor; `New-AdoBoardColumnPayload
returns correctly` does not, and says less.
