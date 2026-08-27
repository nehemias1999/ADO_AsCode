# The automation contract

**Purpose.** State the seven things every automation must provide, so a new one is
consistent with the existing ones without anyone having to read them.

**Scope.** Any module under `automations/`.

**Audience.** Anyone adding or reviewing an automation.

**Related documents**

- [architecture.md](architecture.md) — the layers a module sits in
- [command-model.md](command-model.md) — the verb and status vocabulary
- [testing-strategy.md](../process/testing-strategy.md) — how item 6 is satisfied

This is the most reusable artefact in the repository. It is not specific to Azure
DevOps: it applies to any tool that changes a system somebody depends on.

## 1. The seven items

| # | Requirement |
| --- | --- |
| 1 | A complete configuration **template**, versioned, plus the active file name it is renamed to. |
| 2 | The active file **excluded from version control** whenever it names people, applications or workstation values — created by *renaming* the template, never by copying its contents. |
| 3 | An isolated **JSON Schema**, validated at run time. Not documentation. |
| 4 | A single **entry point** `Invoke-<Module>.ps1` exposing at least `validate`, `plan` and `apply`. |
| 5 | A **guide** covering purpose, configuration, commands, permissions, output and **rollback**. |
| 6 | **Tests** using fixtures that contain no real data. |
| 7 | Its own **pipeline definition**, only if it runs from Azure DevOps. |

Items 1 to 6 are enforced by `tests/automations/Automations.Tests.ps1`. A contract
nothing checks is a wish.

## 2. Item by item

### 1 and 2 — Template, and the rename

The template is versioned and complete: somebody can read it and see the whole shape,
with placeholder values. The active file is produced by **renaming** it.

Renaming rather than copying is not a style preference. The active name is the one
`.gitignore` excludes; a copy invites a file with a *new* name, full of real values,
that Git happily tracks.

```text
applications.example.json   ->  applications.json      (excluded)
members.env.example         ->  members.env            (excluded)
scope.example.json          ->  scope.json             (excluded)
```

Configuration that is genuinely policy — `board-columns.json`, which names no
application and no person — stays versioned. The test is whether the file would still
make sense in somebody else's organization.

### 3 — A schema that runs

Every configuration file points at its schema with a relative `$schema` property, and
`Get-AdoAsCodeConfiguration` resolves it and validates before returning.

Shipping a schema and never running it is common and worthless: the schema documents an
intention while the loader accepts anything, and the two drift apart with nobody
noticing. Here `validate` actually validates, offline, so a malformed catalogue fails
in a second instead of halfway through an apply.

On PowerShell 5.1 there is no `Test-Json -Schema`, so a reduced validator runs —
covering type, required, properties, `additionalProperties`, items, enum, const and
local `$ref`. The result names the engine that ran, so a report never claims more
coverage than it had.

### 4 — One entry point

One file, one command surface, one `-Command` parameter with a closed value list.

| Must expose | Because |
| --- | --- |
| `validate` | Offline check. No network, no token. |
| `plan` | A dry run somebody can approve. |
| `apply` | The only verb that writes, behind `-ConfirmApply`. |

`inventory` and `smoke` are strongly recommended and present in all three modules.
Additional verbs are fine when they name a distinct operational intent — `reconcile`,
`rename` — and each carries its own confirmation.

What must **not** happen is a generic verb loaded with selectors that change what it
means. One command, one intent.

### 5 — A guide, including rollback

Purpose, configuration field by field, commands, the token scopes needed, where output
goes, and how to reverse what was done.

Rollback is the section people skip and the one that matters at two in the morning. It
is allowed to say *"not reversible, and here is why"* — an Area Path rename is exactly
that — but it is not allowed to be absent. The contract test checks the word is there;
a reviewer checks it means something.

### 6 — Tests with invented fixtures

Every fixture is invented. A test that borrows a real Team name, host name or
credential turns the suite into another place sensitive data leaks from, and test
files are the last place anyone thinks to look.

Name a test after the failure it prevents, not the function it calls.

### 7 — A pipeline, if it runs from Azure DevOps

`trigger: none`, a closed command list, `confirmApply` as a separate parameter,
secrets materialised at run time, artefacts published with `condition: always()`.

No parameter belonging to one automation may appear in another's definition.

## 3. Rules that cut across all seven

| Rule | Why |
| --- | --- |
| The declaration names a secret, never holds one. | It is what makes the whole configuration committable. |
| Nothing is deleted. | The blast radius of a delete is not in the declaration. |
| `apply` refuses a plan with any blocked operation. | Partial application of an approved plan produces a state nobody declared. |
| Every operation carries a reason written for the approver. | `pending` on its own is not reviewable. |
| A second run changes nothing. | Idempotency is the acceptance criterion, not an optimisation. |
| An interrupted run leaves a receipt. | The next run is a resume, not a guess. |

## 4. Adding one

1. Create `automations/<name>/` with `config/`, `schemas/` and `examples/`.
2. Write the template and its schema first. The shape of the declaration is the design.
3. Write the entry point. Reuse the foundation; add nothing domain-specific to it.
4. Register the module in `foundation/config/project-context.json` under `automations`.
5. Write the guide and link it from `docs/README.md`.
6. Add a row to the contract test.
7. Add a `CHANGELOG.md` entry.

Step 3 is where the pressure appears. If the shared layer seems to need a special case
for your module, the logic belongs in your module — see
[0004](../adr/0004-shared-foundation-without-domain-rules.md).
