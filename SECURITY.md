# Security policy

## Purpose

State how this repository handles credentials, what it deliberately refuses to
do, and how to report a problem.

## Scope

The automations in this repository authenticate to the Azure DevOps REST API
with a Personal Access Token and write Teams, Boards, Variable Groups and
Service Connections. They never read or write application source code and
never run a deployment.

## Reporting a vulnerability

Open a GitHub issue for anything that is not itself sensitive. If a report
would disclose a working exploit or a live credential, use GitHub's private
vulnerability reporting instead of a public issue.

## What this repository guarantees

| Guarantee | How it is enforced |
| --- | --- |
| No secret value is ever committed | Configuration declares environment variable *names*; values are read at run time. `.gitignore` excludes `.env`, `.local/` and `artifacts/`. `scripts/Test-NoSensitiveData.ps1` fails the build on secret-shaped strings. |
| No resource is deleted | Every writer is additive. Board columns that are not declared are preserved, never removed. |
| Nothing is written without an explicit confirmation | `apply` requires `-ConfirmApply`; a rename additionally requires `-ConfirmRename`. Without them the command is a pure simulation. |
| A pre-existing credential is never overwritten by accident | The only value an automation will replace is the literal sentinel `PENDING_OWNER_CONFIGURATION`. Overwriting anything else needs `-ForceUpdate -ForceCredentialOverwrite`. |
| A partial failure leaves an audit trail | `apply` writes an incremental receipt after every completed operation, so an interrupted run still records exactly what changed. |
| Secrets never reach a log or a report | Reports pass through a redaction step; error messages strip the `Authorization` header. |

## Personal Access Token handling

- Treat the token as a password: never in a commit, a screenshot, a chat
  message, or a work item.
- Grant the minimum scopes listed in
  [docs/guides/getting-started.md](docs/guides/getting-started.md).
- Use the shortest expiry that covers the change window and replace it when it
  expires rather than extending it.
- A token grants no new permissions. The account behind it must already hold
  them in the project.

## Reporting scope exclusions

This repository is a reference implementation. It is not a supported product,
it ships no binaries, and it has no runtime dependency beyond Windows
PowerShell 5.1 or PowerShell 7.
