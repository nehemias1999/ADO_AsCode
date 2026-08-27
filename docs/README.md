# Documentation index

**Purpose.** Route a reader to the one document that answers their question.

**Scope.** Every document in this repository. An unindexed document is treated as
incomplete, and continuous integration enforces that.

**Audience.** Everyone. Start here.

## 1. Read by need

| I need to... | Start with | Then |
| --- | --- | --- |
| Understand what this repository is for | [problem-statement.md](overview/problem-statement.md) | [capabilities.md](overview/capabilities.md) |
| Know exactly what it can and cannot do | [capabilities.md](overview/capabilities.md) | [scope-and-limits.md](overview/scope-and-limits.md) |
| Look up a term | [glossary.md](overview/glossary.md) | |
| Run it for the first time | [getting-started.md](guides/getting-started.md) | [end-to-end-walkthrough.md](guides/end-to-end-walkthrough.md) |
| Provision a Team and its Board | [team-provisioning.md](guides/team-provisioning.md) | [command-model.md](reference/command-model.md) |
| Fill in Variable Groups | [variable-group-configuration.md](guides/variable-group-configuration.md) | [security-model.md](reference/security-model.md) |
| Create Service Connections | [service-connection-provisioning.md](guides/service-connection-provisioning.md) | [azure-devops-notes.md](reference/azure-devops-notes.md) |
| Work out why something failed | [troubleshooting.md](guides/troubleshooting.md) | [azure-devops-notes.md](reference/azure-devops-notes.md) |
| Decide whether to adopt this approach | [faq.md](guides/faq.md) | [architecture.md](reference/architecture.md) |
| Understand how the work was carried out | [delivery-approach.md](process/delivery-approach.md) | [verification-and-evidence.md](process/verification-and-evidence.md) |
| Contribute a change | [working-agreements.md](process/working-agreements.md) | [automation-contract.md](reference/automation-contract.md) |
| Add a new automation | [automation-contract.md](reference/automation-contract.md) | [architecture.md](reference/architecture.md) |
| Understand a plan | [command-model.md](reference/command-model.md) | |
| Look up a configuration field | [configuration-reference.md](reference/configuration-reference.md) | [conventions.md](reference/conventions.md) |
| Review the security posture | [security-model.md](reference/security-model.md) | [risk-register.md](process/risk-register.md) |
| Know why the code is shaped this way | [adr/0001-one-module-per-automation.md](adr/0001-one-module-per-automation.md) | [lessons-learned.md](process/lessons-learned.md) |
| See what the output looks like | [report.example.md](examples/report.example.md) | |

## 2. By folder

### overview — what this is and what it does

| Document | Answers |
| --- | --- |
| [problem-statement.md](overview/problem-statement.md) | What was wrong before, and what the solution had to satisfy. |
| [capabilities.md](overview/capabilities.md) | The functional catalogue: every capability, its module, its command, and whether it writes. |
| [scope-and-limits.md](overview/scope-and-limits.md) | What it does not do, and why each gap is a decision. |
| [glossary.md](overview/glossary.md) | The vocabulary, Azure DevOps and local. |

### guides — how to use it

| Document | Answers |
| --- | --- |
| [getting-started.md](guides/getting-started.md) | Prerequisites, the token and its minimum scopes, first run. |
| [end-to-end-walkthrough.md](guides/end-to-end-walkthrough.md) | One application from nothing to verified, with the output of each step. |
| [team-provisioning.md](guides/team-provisioning.md) | The Teams, paths and Boards module, field by field. |
| [variable-group-configuration.md](guides/variable-group-configuration.md) | The Variable Groups module, field by field. |
| [service-connection-provisioning.md](guides/service-connection-provisioning.md) | The Service Connections module, field by field. |
| [troubleshooting.md](guides/troubleshooting.md) | Symptom, cause, diagnosis, fix. |
| [faq.md](guides/faq.md) | Why PowerShell, why one application at a time, how to move it elsewhere. |

### process — how it was built and how it is run

| Document | Answers |
| --- | --- |
| [delivery-approach.md](process/delivery-approach.md) | The seven stages, with the exit criterion of each. |
| [working-agreements.md](process/working-agreements.md) | Branching, commits, review, definition of done. |
| [verification-and-evidence.md](process/verification-and-evidence.md) | How a change is shown to have worked. |
| [testing-strategy.md](process/testing-strategy.md) | What is tested, what is not, and why. |
| [risk-register.md](process/risk-register.md) | What could go wrong, and the control that stops it. |
| [lessons-learned.md](process/lessons-learned.md) | What transfers to the next platform of this kind. |

### reference — the contracts

| Document | Answers |
| --- | --- |
| [architecture.md](reference/architecture.md) | The layers and the dependency rules. |
| [automation-contract.md](reference/automation-contract.md) | The seven things a new automation must provide. |
| [command-model.md](reference/command-model.md) | Every verb, every status, and the apply gate. |
| [configuration-reference.md](reference/configuration-reference.md) | Every configuration file and field. |
| [conventions.md](reference/conventions.md) | Resource naming, repository naming, the sentinel. |
| [security-model.md](reference/security-model.md) | Where secrets live and what is never written. |
| [azure-devops-notes.md](reference/azure-devops-notes.md) | Portable API lessons, each with its symptom. |

### adr — the decisions

| Document | Decision |
| --- | --- |
| [0001-one-module-per-automation.md](adr/0001-one-module-per-automation.md) | One automation is one visible module. |
| [0002-plan-before-apply.md](adr/0002-plan-before-apply.md) | Nothing is written without a reviewed plan and an explicit confirmation. |
| [0003-configuration-declares-secret-names.md](adr/0003-configuration-declares-secret-names.md) | Configuration declares the name of a secret, never its value. |
| [0004-shared-foundation-without-domain-rules.md](adr/0004-shared-foundation-without-domain-rules.md) | The shared layer carries no domain rules. |
| [0005-never-delete-preserve-undeclared-state.md](adr/0005-never-delete-preserve-undeclared-state.md) | Nothing is deleted; undeclared state is preserved. |
| [0006-idempotency-as-acceptance-criterion.md](adr/0006-idempotency-as-acceptance-criterion.md) | A change is done when a second run does nothing. |

### examples — what the output looks like

| Document | Content |
| --- | --- |
| [report.example.md](examples/report.example.md) | A rendered plan report. The matching JSON and receipt sit beside it. |

## 3. Where knowledge lives

| Location | Holds | Never holds |
| --- | --- | --- |
| `docs/` | Permanent, indexed, versioned knowledge. | Anything about one execution. |
| `automations/*/README.md` | The short guide for one module, linking to its full guide here. | Contract details, which belong in `docs/guides/`. |
| `.local/` | Workstation values, drafts, deny lists. Excluded from version control. | Anything another person needs. |
| `artifacts/` | Reproducible output of one run. Excluded from version control. | A decision. A report is evidence, not a contract. |

## 4. Writing a new document

Copy [_template.md](_template.md), fill it in, and add a row to this index in the
same change. Continuous integration fails on a document that is not linked here, and
on a relative link that does not resolve.
