# pipelines

**Purpose.** Run the automations from Azure DevOps, on an agent, with the same
guarantees they give on a workstation.

**Scope.** One YAML per automation. No shared YAML, no parameters belonging to one
automation appearing in another's definition.

**Audience.** Whoever sets up or reviews the pipeline definitions.

**Related documents**

- [Command model](../docs/reference/command-model.md) — what each verb may write
- [Security model](../docs/reference/security-model.md) — how secrets reach a run
- [Working agreements](../docs/process/working-agreements.md) — who may run what

## 1. The shared pattern

Every file here follows the same five rules. They are worth stating once rather than
being re-derived per file.

| Rule | Why |
| --- | --- |
| `trigger: none` and `pr: none` | A pipeline that governs the project must not run because somebody pushed a commit. It runs when a person asks for it, having read a plan. |
| The command is a parameter with a closed value list | A typo cannot become an unexpected verb, and the drop-down doubles as documentation. |
| `apply` also requires a `confirmApply` parameter | The confirmation exists both here and in the script. The pipeline form is where the mistake is easiest to make. |
| Secrets are written into `.env.pipeline` at run time | The script reads its environment the same way everywhere, so it has no idea whether it is on an agent or a laptop — and there is one code path to reason about instead of two. |
| `publish` with `condition: always()` | The evidence of a *failed* apply is the point. The receipt records exactly which operations completed before it stopped. |

Organization and project are pipeline **parameters**, not literals, so the same
definition can be pointed at another organization without editing the file.

## 2. Setting one up

1. Create a variable group named `ado-as-code` in **Pipelines > Library**, holding
   `ADO_PAT` and any membership variables, all marked secret.
2. For `service-connection-provisioning`, create a second group,
   `ado-as-code-connections`, for the `SFTP_*` credential variables. It is separate so
   the people who may run a plan are not automatically the people who hold the
   credentials.
3. Create a pipeline from the YAML file. Do not enable CI or PR triggers.
4. Restrict who may run it, and require an approval on any pipeline that can apply to
   production.
5. Run `validate`, then `plan`, before anyone runs `apply`.

## 3. What is deliberately absent

- **A schedule.** Nothing in this repository benefits from running unattended. A plan
  needs a reader.
- **A force-overwrite parameter on `service-connection-provisioning`.** Replacing a
  credential that cannot be read back is not a checkbox on a form. Whoever needs it
  runs the command from a workstation, having decided that is the right thing to do.
- **A pipeline that applies to every application at once.** One application per
  execution is what keeps a plan readable and a failure attributable.
