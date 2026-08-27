<#
.SYNOPSIS
    Makes the foundation modules importable and imports them.

.DESCRIPTION
    The foundation ships as real PowerShell modules with manifests, so they declare
    their dependencies through RequiredModules. That only resolves when the folder
    holding them is on PSModulePath, which is what this script arranges.

    Dot-source it from an automation entry point or a test:

        . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

    It is idempotent: repeated dot-sourcing neither duplicates the path entry nor
    reloads the modules, unless -Force is requested.

.PARAMETER Force
    Reimport the modules even when they are already loaded. Used while developing a
    module, where a stale copy in the session is the usual source of confusion.

.PARAMETER Name
    Import only the named modules instead of all of them.

.EXAMPLE
    . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

.EXAMPLE
    $Force = $true; . (Join-Path $repoRoot 'foundation/Import-Foundation.ps1')

    Reloads every foundation module in the current session.
#>

[CmdletBinding()]
param(
    [switch] $Force,
    [string[]] $Name = @(
        'Ado.Rest',
        'Ado.Identity',
        'Ado.Work',
        'Ado.Library',
        'AdoAsCode.Configuration',
        'AdoAsCode.Plan',
        'AdoAsCode.Report'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$foundationModuleRoot = Join-Path $PSScriptRoot 'modules'
if (-not (Test-Path -LiteralPath $foundationModuleRoot)) {
    throw "Foundation module folder not found: $foundationModuleRoot"
}

$foundationPathSeparator = [System.IO.Path]::PathSeparator
$foundationCurrentPaths = @($env:PSModulePath -split $foundationPathSeparator | Where-Object { $_ })
if ($foundationCurrentPaths -notcontains $foundationModuleRoot) {
    $env:PSModulePath = $foundationModuleRoot + $foundationPathSeparator + $env:PSModulePath
}

# Import in dependency order. Ado.Rest first, because the manifests of the domain
# modules require it, and RequiredModules resolution reports a confusing error when
# the dependency is not yet discoverable.
$foundationImportOrder = @(
    'Ado.Rest',
    'AdoAsCode.Configuration',
    'AdoAsCode.Plan',
    'AdoAsCode.Report',
    'Ado.Identity',
    'Ado.Work',
    'Ado.Library'
)

# Every variable in here is prefixed, because this script is DOT-SOURCED: it shares
# the caller's scope, so a loop variable named $moduleName would silently overwrite
# the caller's own $moduleName. That is not hypothetical - it is how the first
# automation entry point broke.
foreach ($foundationModuleName in $foundationImportOrder) {
    if ($Name -notcontains $foundationModuleName) { continue }
    if (-not $Force -and (Get-Module -Name $foundationModuleName)) { continue }
    Import-Module -Name $foundationModuleName -Force:$Force -ErrorAction Stop
}
Remove-Variable -Name foundationModuleName -ErrorAction SilentlyContinue
