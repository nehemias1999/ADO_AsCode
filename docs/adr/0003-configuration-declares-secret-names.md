# ADR 0003: Configuration declares the name of a secret, never its value

**Status.** Accepted, 2026-01.

## Context

Automating a platform requires credentials: a token, connection passwords, keys.

The obvious approaches all fail. Putting values in configuration makes the
configuration uncommittable, so it gets shared by other means and stops being
reviewable. Encrypting values in the repository moves the problem to key distribution
and puts ciphertext in every diff. Prompting interactively does not work on an agent.

## Decision

Configuration declares the **name** of the environment variable that carries a value.

```json
{ "hostEnv": "SFTP_APP_ALPHA_DEV_HOST", "passwordEnv": "SFTP_APP_ALPHA_DEV_PASSWORD" }
```

Values reach the process from `.env` on a workstation or from a secret variable group
on an agent. The code path is identical in both.

A secret with no value available is not invented. It is written as the sentinel
`PENDING_OWNER_CONFIGURATION` and completed by whoever holds it, and no later run
overwrites what they set.

## Consequences

**Good.** The entire declaration is committable, reviewable and shareable. There is one
code path for local and pipeline execution. A credential handover is a list of variable
names, which `validate` prints without needing any credential itself.

**Bad.** A layer of indirection: reading the configuration tells you where the host
comes from, not what it is. Accepted, and mitigated by deriving variable names from the
same pattern as the resource, so a mismatch is impossible rather than merely unlikely.

**Neutral.** Whoever runs a plan does not need the credentials — usually a feature,
occasionally meaning two people are involved where one would do.
