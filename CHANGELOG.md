# Changelog

All notable changes to this repository are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A version is meaningful here because the configuration schemas are a contract: a
breaking change to a schema is a major version, whatever the code did.

## [Unreleased]

### Security

- **`service-connection-provisioning`** — an SSH private key is no longer copied into the
  Service Connection's `data` bag. `data` is returned in clear text by
  `GET _apis/serviceendpoint/endpoints` to every identity with read access to the project,
  so a key written there was readable by anyone who could read the endpoint, and appeared
  in any inventory built from an endpoint read. The key is now sent only as
  `authorization.parameters.privateKey`, which GET never returns. Connections created
  before this change should have their keys rotated, because the old key was exposed for
  as long as the connection has existed.

### Added

- **Foundation** — `New-AdoSshServiceEndpointPayload`, the Service Connection request body
  as a pure function. Split out of `New-AdoSshServiceEndpoint` so credential placement can
  be asserted without a round trip; seven tests cover it, one of which renders the whole
  payload with `authorization` removed and fails if a credential appears anywhere in the
  remainder.

`plan` output is unchanged for unchanged input: the change affects only the request body
sent by `apply`.

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
