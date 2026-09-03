<#
.SYNOPSIS
    Writes the environment file a pipeline run hands to an automation.

.DESCRIPTION
    Azure Pipelines does not expose a secret variable to a script unless the step maps
    it, and the automations read their configuration from a .env file. This bridges the
    two: it validates the queue-time parameters, then writes the file the automation
    reads locally, so a pipeline run and a workstation run take the same input.

    Secret values are read from this process's environment, never accepted as arguments.
    A command line is visible to every other process on the agent, so passing a token as
    a parameter would publish it to exactly the audience a secret variable exists to
    keep it from.

    The file this writes holds ADO_PAT in clear text. Remove-EnvironmentFile.ps1 is its
    other half and the pipeline must call it with condition: always().

.PARAMETER Path
    Where to write the file. Relative paths resolve against the current directory, which
    on an agent is the sources directory.

.PARAMETER OrganizationUrl
    Organization URL from the queue-time parameter, unvalidated.

.PARAMETER Project
    Team project name from the queue-time parameter, unvalidated.

.PARAMETER SecretName
    Names of secret variables to carry into the file. Each is read from the environment;
    one with no value is omitted, not written empty. That distinction matters: an empty
    secret in a Variable Group PUT blanks the live credential, so the automation must see
    the name as unresolved and report the group blocked instead.

.EXAMPLE
    .\scripts\pipeline\Write-EnvironmentFile.ps1 -Path .env.pipeline `
        -OrganizationUrl $env:PARAM_ORGANIZATION_URL -Project $env:PARAM_PROJECT

.EXAMPLE
    .\scripts\pipeline\Write-EnvironmentFile.ps1 -Path .env.pipeline `
        -OrganizationUrl $env:PARAM_ORGANIZATION_URL -Project $env:PARAM_PROJECT `
        -SecretName 'APP_SERVER_PASSWORD_DEV', 'APP_SERVER_PASSWORD_PROD'

.OUTPUTS
    None. Writes the file and reports how many variables it holds, never their values.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path = '.env.pipeline',

    [Parameter(Mandatory)] [AllowEmptyString()] [string] $OrganizationUrl,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $Project,

    [string[]] $SecretName = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PipelineParameters.ps1')

$validatedUrl = Assert-ParameterValue -Name 'organizationUrl' -Value $OrganizationUrl -Required `
    -Pattern '^https://[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._~%-]+$'
$validatedProject = Assert-ParameterValue -Name 'project' -Value $Project -Required `
    -Pattern '^[A-Za-z0-9][A-Za-z0-9 ._-]*$'

$lines = @(
    "ADO_ORG_URL=$validatedUrl",
    "ADO_PROJECT=$validatedProject",
    "ADO_PAT=$([Environment]::GetEnvironmentVariable('ADO_PAT', 'Process'))"
)

foreach ($name in $SecretName) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($value) { $lines += "$name=$value" }
}

if ($PSCmdlet.ShouldProcess($Path, "Write $($lines.Count) variable(s), including the access token")) {
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Host "Wrote $Path with $($lines.Count) variable(s). Values are not echoed."
}
