# Azure DevOps API notes

**Purpose.** Record the API behaviours that shaped this code, each with the symptom it
produces, so the next person does not have to rediscover them the expensive way.

**Scope.** Behaviour that is portable to any project automating Azure DevOps. Nothing
here is specific to this repository.

**Audience.** Anyone automating Azure DevOps, here or elsewhere.

**Related documents**

- [security-model.md](security-model.md) — the guards built on notes 1 and 2
- [risk-register.md](../process/risk-register.md) — the risks these create
- [lessons-learned.md](../process/lessons-learned.md) — the general conclusions

Each note gives the **symptom** first, because that is what you will have when you go
looking.

## 1. A Variable Group `PUT` stores an omitted value as an empty string

**Symptom.** A pipeline that authenticated fine yesterday fails today. Nothing changed
in the pipeline. The Variable Group looks normal in the portal — the secret variable is
still there, still marked secret.

**Behaviour.** There is no per-variable route. Updating means `PUT`ting the whole
group. A variable whose `value` property is **omitted** is not left as it was: it is
stored as an empty string.

**Why it is easy to get wrong.** The intuitive model is that the server keeps what it
has for anything you do not mention. It does not, and the response is a `200` either
way.

**Rule.** To change one key in a group that holds secrets, re-post every secret with a
value you can prove you know. If you cannot resolve one, do not write at all.

## 2. A Service Connection `GET` never returns its credential

**Symptom.** Identical to note 1, from a different resource. Deployments stop
authenticating after a routine update.

**Behaviour.** The API returns metadata only. The only update route is a full-object
`PUT`, so a read-modify-write cycle sends `null` where the credential was — and reports
success.

**Why the portal is different.** The portal performs a partial update. It does not have
to round-trip the credential, so it does not destroy it.

**Rule.** Do not automate a Service Connection update or rename. Create if absent;
otherwise leave it alone. If a rename is genuinely required, do it in the portal.

## 3. Creating a Team does not produce a working Board

**Symptom.** `TF400509` when anyone opens the Board of a Team the API created.

**Behaviour.** A Team needs four things before its Board works, and creating the Team
does one of them:

| # | Thing | Set by |
| --- | --- | --- |
| 1 | The Team | `POST .../teams` |
| 2 | A backlog iteration | `PATCH .../work/teamsettings` — copied from an existing Team, since there is no sensible default |
| 3 | An Area Path node named after the Team | `POST .../classificationnodes/Areas` |
| 4 | A team field value pointing at it | `PATCH .../work/teamsettings/teamfieldvalues` |

**Rule.** Do all four in one operation, and treat "created a Team" as an incomplete
state until they are done.

## 4. Board columns are all-or-nothing

**Symptom.** A column somebody added disappears after an unrelated change, taking its
Work Items with it.

**Behaviour.** No per-column route. Writing means `PUT`ting the complete collection, so
anything absent from the payload is deleted.

Two structural constraints the API enforces, with an error message that names no
column:

- exactly one `incoming` column, and it must be first;
- exactly one `outgoing` column, and it must be last.

**Rule.** Read the live columns first and merge. Preserve anything you did not
declare, re-typing it to `inProgress` if needed, and insert it **before** the outgoing
column.

## 5. Reusing a column id renames it; a new id replaces it

**Symptom.** After a rename, the Board has both columns. The old one still holds every
Work Item.

**Behaviour.** A column is identified by its id. Sending the same id with a different
name renames it and the Work Items follow. Sending a new name with no id creates a
second column, and the first is preserved by rule 4 — permanently.

**Rule.** Match a declared column to an existing one before building the payload:
exact name, then declared previous names, then identical state mapping. Warn when the
third one fires; several columns usually share a mapping and it is a guess.

## 6. An agent exposes every Variable Group variable as an environment variable

**Symptom.** A stage runs that no YAML mentions. Nothing in any pipeline definition
refers to it, and the diff of the last change shows nothing relevant.

**Behaviour.** When a pipeline links a Variable Group, the agent exports every variable
in it into the process environment. A script that reads an environment variable
directly — as scripts do — is switched on by a key nobody connected to it.

**Why it is hard to see.** The key is not in the pipeline, not in the template, and not
in any diff. It is in a Variable Group somebody edited in the portal.

**Rule.** Declare which keys may exist per environment, and assert that the forbidden
ones are **absent**. Not writing a key is not the same as checking it is not there.

## 7. Area Path lookup is case insensitive; the rename is not idempotent

**Symptom.** A rename that only changes capitalisation appears to have already been
applied, so it is skipped — and never happens.

**Behaviour.** Looking up `Platform\App_Alpha_Team` succeeds against a node actually
named `Platform\APP_ALPHA_Team`.

**Rule.** Compare classification nodes **by id**, not by name.

Related, and more serious: renaming an Area Path rewrites `System.AreaPath` on every
Work Item below it. Queries, dashboards and saved charts filtering on the old path stop
matching, and renaming back does not undo it — the revision history keeps both entries.
Treat it as irreversible.

## 8. A Team administrator has no public REST route

**Symptom.** The Team is created, everything looks right, and nobody can administer it —
including the identity that created it.

**Behaviour.** Creating a Team does not make the caller its administrator. There is no
documented endpoint; the portal uses an internal one,
`_api/_identity/AddTeamAdmins`, at a pinned api-version. The subject must already be a
member.

**Rule.** Add the member, then promote. Isolate the internal call in one function with
a comment saying it is internal, so the day it changes there is one place to fix.

## 9. Graph groups page with a continuation token

**Symptom.** An organization with many groups quietly returns the first page. Nothing
errors; the answer is just incomplete.

**Behaviour.** The Graph groups collection pages with an `X-MS-ContinuationToken`
**response header**, not a `skip`/`top` pair — and `Invoke-RestMethod` discards
response headers.

**Rule.** Use `Invoke-WebRequest` and deserialize the body yourself when reading a
header-paged collection.

## 10. The Graph group `PATCH` requires JSON Patch

**Symptom.** `400 Bad Request` with a message that does not mention content types.

**Behaviour.** Renaming a Graph group requires `application/json-patch+json` (RFC 6902).
Every other `PATCH` in the API takes a plain JSON document.

**Rule.** Send `[{ "op": "replace", "path": "/displayName", "value": "..." }]` with that
content type.

## 11. The useful part of an error is in the response body

**Symptom.** `The remote server returned an error: (400) Bad Request.` and nothing else.

**Behaviour.** The service puts a real explanation in a `message` property of the
response body. PowerShell 7 exposes it as `ErrorDetails.Message`; Windows PowerShell
5.1 requires draining the response stream.

**Rule.** Read the body on failure and surface `message`. It is the difference between
a bug report and a guess.

## 12. Retry only what is transient

**Symptom.** A failed operation applied twice.

**Behaviour.** `429` is throttling, with a `Retry-After` worth honouring. `5xx` is the
service shedding load. A `400`, `403`, `404` or `409` is a **real answer** — retrying
one only multiplies whatever went wrong.

**Rule.** Retry `429` and `5xx` with backoff. Nothing else.

## 13. Newly created resources are not immediately queryable

**Symptom.** A Board queried moments after its Team was created returns an error rather
than an empty list.

**Behaviour.** Propagation delay, typically a few seconds.

**Rule.** Retry the read a small number of times with a short pause. Do not sleep
unconditionally, and do not treat the first failure as fatal.

## 14. Two traps outside this repository's scope, recorded because they cost time

| Trap | Symptom | Rule |
| --- | --- | --- |
| A nested pipeline template path resolves relative to the **including file**, not the repository root | A template that works in one place fails in another with a path error | Reason about template paths from the including file. |
| An unset `$(MACRO)` is left as **literal text**, not emptied | A script receives the string `$(SOMETHING)` and treats it as a path or a flag | Never assume an unset macro becomes empty. Default it explicitly. |

## 15. Validate a pipeline without running it

Compile with the preview API — `POST /_apis/pipelines/{id}/preview` with
`previewRun: true` — to get the fully resolved YAML without executing anything. It is
the cheapest way to prove a template change compiles across many pipelines.
