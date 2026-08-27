# Getting started

**Purpose.** Take a workstation from nothing to a validated configuration and a
successful read-only call against Azure DevOps.

**Scope.** Prerequisites, the token, the local files. Provisioning an application is
in [end-to-end-walkthrough.md](end-to-end-walkthrough.md).

**Audience.** Someone running this for the first time.

**Related documents**

- [end-to-end-walkthrough.md](end-to-end-walkthrough.md) — the next step
- [troubleshooting.md](troubleshooting.md) — when a step below does not do what it says
- [security-model.md](../reference/security-model.md) — why the token is handled this way

## 1. Prerequisites

| Requirement | Notes |
| --- | --- |
| Windows PowerShell 5.1 or PowerShell 7 | Nothing else. No modules to install, no SDK, no package manager. That constraint is deliberate: a tool that governs a platform has to run on a locked-down workstation and on a build agent without either being specially prepared. |
| Git | To clone and update the repository. |
| An account with access to the team project | The token grants no permission the account does not already hold. |
| Pester 5 and PSScriptAnalyzer | **Only** to run the test suite. Never needed to run an automation. |

On PowerShell 5.1, configuration is checked with a reduced schema validator; on
PowerShell 7 the full one runs. Both are enforced, and the result names the engine
that ran, so a report never claims more coverage than it had.

## 2. Create the Personal Access Token

**User settings > Personal access tokens > New Token.**

Grant the least that covers what you intend to run:

| Scope | Needed for | Module |
| --- | --- | --- |
| Work Items — Read & write | Classification nodes; reading Work Item type states | `team-provisioning` |
| Project and Team — Read, write & manage | Creating a Team, its work settings, its members | `team-provisioning` |
| Graph — Read | Resolving a sign-in address to an identity | `team-provisioning` |
| Identity — Read & manage | Promoting the token identity to Team administrator | `team-provisioning` |
| Variable Groups — Read, create & manage | Creating groups and writing values | `variable-group-configuration` |
| Service Connections — Read, query & manage | Creating endpoints | `service-connection-provisioning` |

Set the shortest expiry that covers your change window, and replace it when it
expires rather than extending it.

Treat it as a password: never in a commit, a screenshot, a chat message, or a work
item. It lives only in `.env`, which is excluded from version control.

## 3. Prepare the workstation

```powershell
git clone https://github.com/<owner>/<repository>.git
cd <repository>
.\scripts\bootstrap.ps1
```

`bootstrap.ps1` checks the prerequisites, creates `.local/` and `artifacts/`, and
creates `.env` from `.env.example`. It never overwrites an existing `.env`. Use
`-CheckOnly` to report without writing anything.

Then open `.env` and fill in three values:

```text
ADO_ORG_URL=https://dev.azure.com/<organization>
ADO_PROJECT=<team project>
ADO_PAT=<your token>
```

## 4. Create your local configuration

Each module ships a template. Create the active file by **renaming** the template, not
by copying its contents — the active names are the ones `.gitignore` excludes, so a
rename cannot accidentally produce a tracked file full of real values.

| Rename this | To this | Contains |
| --- | --- | --- |
| `automations/team-provisioning/config/applications.example.json` | `applications.json` | Your applications, their Teams and their paths |
| `automations/team-provisioning/config/members.env.example` | `members.env` | Sign-in addresses. Personal data; never committed. |
| `automations/variable-group-configuration/config/scope.example.json` | `scope.json` | Which groups exist and which keys they may hold |
| `automations/variable-group-configuration/config/variable-groups.example.csv` | `variable-groups.csv` | Non-secret values |
| `automations/service-connection-provisioning/config/service-connections.example.json` | `service-connections.json` | Which connections exist |

Until you rename them, every command falls back to the template, so `validate` works
on a fresh clone with nothing configured.

## 5. Validate — no credentials needed

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command validate
```

Expected:

```text
[team-provisioning] Configuration: ...\applications.example.json
[team-provisioning] Board columns : ...\board-columns.json
[team-provisioning] Valid. 2 application(s) declared, 8 Board column(s).
[team-provisioning] No network call was made and no credential was read.
```

That last line is a promise the test suite enforces: the offline validation test runs
with `ADO_PAT`, `ADO_ORG_URL` and `ADO_PROJECT` cleared from the environment.

Run it for the other two modules as well:

```powershell
.\automations\variable-group-configuration\Invoke-VariableGroupConfiguration.ps1 -Command validate
.\automations\service-connection-provisioning\Invoke-ServiceConnectionProvisioning.ps1 -Command validate
```

## 6. First call against Azure DevOps

`inventory` is read-only. It proves the URL, the project and the token work together
before any plan is computed.

```powershell
.\automations\team-provisioning\Invoke-TeamProvisioning.ps1 -Command inventory
```

```text
[team-provisioning] Connected to 'https://dev.azure.com/contoso' project 'Platform'.
Plan for 'APP_ALPHA,APP_BETA' (inventory): 2 operation(s) - ok 2, pending 0, ...
[team-provisioning] Report: ...\artifacts\reports\team-provisioning-inventory.json
```

If this fails, the message names which of the three inputs is wrong. See
[troubleshooting.md](troubleshooting.md).

## 7. Run the test suite (optional)

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
.\scripts\Invoke-Tests.ps1
```

Static analysis, the unit suite and the sensitive data gate, in one command — the same
one continuous integration runs.

## 8. Next

[end-to-end-walkthrough.md](end-to-end-walkthrough.md) provisions one application from
nothing to verified, showing the output of every step.
