# API reference

**Purpose.** Name every function the foundation exports, so the shared layer can be
read without opening seven `.psm1` files.

**Scope.** The exported surface only. Private helpers are deliberately absent: they are
not a contract and may change without a changelog entry.

**Audience.** Anyone adding an automation, or wondering whether the behaviour they need
already exists.

Each synopsis is the one in the function's own comment-based help, so this page and
`Get-Help` cannot disagree. For parameters, examples and the reasoning, run:

```powershell
. .\foundation\Import-Foundation.ps1
Get-Help Get-AdoVariableGroupSecretSource -Full
```

A test asserts that every exported function appears below, so this page cannot fall
behind the modules it describes.

## Ado.Rest

Transport. Where a credential may be sent, how a request is built, and what is retried.

Depends on: none. Exports 11.

| Function | Synopsis |
| --- | --- |
| `Assert-AdoOrganizationUrl` | Validates an organization URL before a credential is aimed at it, and returns it normalized. |
| `Get-AdoAuthenticatedUser` | Returns the identity behind the Personal Access Token. |
| `Get-AdoContext` | Builds the connection context every other call in the repository takes. |
| `Get-AdoProject` | Retrieves the team project named by the context. |
| `Get-AdoRetryDecision` | Decides whether a failed request may be retried, and after how long. |
| `Get-RequiredEnvironmentVariable` | Reads a process environment variable and fails with a usable message when it is missing. |
| `Invoke-AdoRest` | Sends one request to the Azure DevOps REST API. |
| `Invoke-AdoRestPaged` | Retrieves every page of a continuation-token paged collection. |
| `New-AdoRequestParameter` | Builds the splat passed to Invoke-RestMethod for one Azure DevOps request. |
| `New-AdoUri` | Builds a fully qualified Azure DevOps URL with the api-version applied. |
| `Remove-SecretFromText` | Masks credential material in a string before it is logged or thrown. |

## Ado.Identity

Identities, Teams and security groups. Resolves a person or group to a descriptor, and never guesses when a lookup is ambiguous.

Depends on: Ado.Rest. Exports 11.

| Function | Synopsis |
| --- | --- |
| `Add-AdoTeamMember` | Adds a user to a Team. |
| `Get-AdoGraphDescriptor` | Translates a storage key (a user, team or project id) into a Graph descriptor. |
| `Get-AdoIdentity` | Resolves a user reference - typically a sign-in address - to an identity. |
| `Get-AdoSecurityGroup` | Lists the project-scoped security groups. |
| `Get-AdoTeam` | Lists the Teams of the project, or returns one Team by name. |
| `Get-AdoTeamMember` | Lists the members of a Team. |
| `New-AdoSecurityGroup` | Creates a project-scoped security group. |
| `New-AdoTeam` | Creates a Team. |
| `Rename-AdoSecurityGroup` | Renames a security group, preserving its descriptor and membership. |
| `Rename-AdoTeam` | Renames a Team. |
| `Set-AdoTeamAdministrator` | Promotes an existing Team member to Team administrator. |

## Ado.Work

Work configuration: classification nodes, Team settings, iterations and Board columns.

Depends on: Ado.Rest. Exports 18.

| Function | Synopsis |
| --- | --- |
| `Add-AdoTeamIteration` | Subscribes a Team to an existing project iteration. |
| `Get-AdoBoard` | Lists the Boards of a Team, or returns one Board by name. |
| `Get-AdoBoardColumn` | Reads the current columns of a Board, in order. |
| `Get-AdoBoardColumnRenameConflict` | Detects a Board that holds both the new and the old name of a renamed column. |
| `Get-AdoBoardColumnStatus` | Classifies the Board column state as a single plan operation. |
| `Get-AdoClassificationNode` | Reads one Area or Iteration Path node, or $null when it does not exist. |
| `Get-AdoTeamFieldValue` | Reads the Area Path values assigned to a Team. |
| `Get-AdoTeamIteration` | Lists the iterations subscribed by a Team. |
| `Get-AdoTeamSetting` | Reads the work settings of a Team: backlog iteration, visible backlogs, working days. |
| `Get-AdoWorkItemTypeState` | Lists the valid states of a Work Item type in the project's process. |
| `Initialize-AdoClassificationPath` | Creates every missing segment of an Area or Iteration Path and returns the leaf node. |
| `Initialize-AdoTeamWorkConfiguration` | Makes a newly created Team's Board usable. |
| `New-AdoBoardColumnPayload` | Builds the complete column collection to PUT, reusing existing ids and preserving undeclared columns. |
| `Rename-AdoAreaPath` | Renames an Area Path node. |
| `Set-AdoBoardColumn` | Writes the complete column collection of a Board. |
| `Sync-AdoBoardColumn` | Reconciles a Board's columns with the declared template. |
| `Test-AdoBoardColumnDrift` | Reports whether reconciling the Board would change anything. |
| `Test-AdoBoardColumnTemplate` | Validates a declared column template before anything is read from Azure DevOps. |

## Ado.Library

Variable Groups and Service Connections - the two resources whose write shape can destroy a credential.

Depends on: Ado.Rest. Exports 12.

| Function | Synopsis |
| --- | --- |
| `Get-AdoConfigurationSentinel` | Returns the placeholder value that marks a setting as not yet configured. |
| `Get-AdoServiceEndpoint` | Lists Service Connections, or returns one by name. |
| `Get-AdoServiceEndpointStatus` | Classifies a declared Service Connection against what exists, as a plan operation. |
| `Get-AdoVariableGroup` | Lists Variable Groups, or returns one by name or id. |
| `Get-AdoVariableGroupSecretSource` | Resolves a known value for each secret variable of a group from the process environment. |
| `Get-AdoVariableGroupUpdate` | Decides which non-secret variables may be written, and which must not. |
| `New-AdoSshServiceEndpoint` | Creates an SSH/SFTP Service Connection. |
| `New-AdoSshServiceEndpointPayload` | Builds the request body for an SSH/SFTP Service Connection. |
| `New-AdoVariableGroup` | Creates a Variable Group whose declared keys start at the sentinel. |
| `New-AdoVariableGroupPayload` | Builds the complete variables payload for a Variable Group PUT, re-posting every secret with a known value. |
| `Rename-AdoVariableGroup` | Renames a Variable Group, preserving its variables and its secrets. |
| `Set-AdoVariableGroupValue` | Writes declared values to a Variable Group while preserving its secrets. |

## AdoAsCode.Configuration

Configuration loading, schema validation and path resolution. Knows nothing about Azure DevOps.

Depends on: none. Exports 5.

| Function | Synopsis |
| --- | --- |
| `Get-AdoAsCodeConfiguration` | Reads a JSON configuration file and validates it against its schema. |
| `Get-AdoAsCodeMemberList` | Reads a membership list from an environment variable. |
| `Import-AdoAsCodeEnvironment` | Loads KEY=VALUE pairs from one or more .env files into the process environment. |
| `Resolve-AdoAsCodePath` | Turns a repository-relative path into an absolute one. |
| `Test-AdoAsCodeConfiguration` | Validates a JSON document against a JSON Schema file. |

## AdoAsCode.Plan

The plan model: a closed vocabulary of statuses and actions, and the gate that refuses a blocked plan.

Depends on: none. Exports 9.

| Function | Synopsis |
| --- | --- |
| `Add-PlanOperation` | Appends an operation to a plan. |
| `Assert-PlanApplicable` | Throws unless the plan is safe to apply. |
| `Get-PlanActionName` | Returns the valid plan action values. |
| `Get-PlanStatusName` | Returns the valid plan status values. |
| `Get-PlanSummary` | Counts the operations of a plan by status. |
| `New-Plan` | Creates an empty plan for a target. |
| `New-PlanOperation` | Creates one plan operation. |
| `Test-PlanBlocked` | Returns true when any operation in the plan is blocked. |
| `Write-PlanSummary` | Writes a readable plan summary to the information stream. |

## AdoAsCode.Report

Evidence: the report, its Markdown sibling, the incremental receipt, and redaction at the writer.

Depends on: AdoAsCode.Plan. Exports 5.

| Function | Synopsis |
| --- | --- |
| `Format-AdoAsCodeReportMarkdown` | Renders a report object as Markdown. |
| `Get-AdoAsCodeReceiptPath` | Derives the receipt path that belongs to a report path. |
| `Remove-SensitiveValue` | Returns a copy of an object with sensitive property values replaced. |
| `Save-AdoAsCodeReceipt` | Writes or updates the receipt of an apply. |
| `Write-AdoAsCodeReport` | Writes a plan or result report as JSON, plus a Markdown sibling. |

## Related documents

- [architecture.md](architecture.md) - the layers these modules sit in, and the dependency rule between them.
- [automation-contract.md](automation-contract.md) - what a new automation must provide to use them.
- [command-model.md](command-model.md) - the verbs an entry point exposes on top of this surface.
