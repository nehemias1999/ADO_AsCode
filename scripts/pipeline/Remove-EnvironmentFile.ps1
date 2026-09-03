<#
.SYNOPSIS
    Removes the environment file a pipeline run wrote, overwriting it first.

.DESCRIPTION
    The file holds ADO_PAT in clear text, and every connection credential the run needed.
    On a Microsoft-hosted agent the workspace is discarded afterwards, which is the
    assumption the writing step was built on. A self-hosted agent is the case this
    repository exists for, and there the workspace SURVIVES the run: the token sits in
    the checkout until some later build happens to overwrite it, readable by every other
    pipeline that uses the agent and by anyone with a session on the machine.

    The pipeline must call this with condition: always(). The run this matters most for
    is the one that threw - a failed apply leaves the file behind exactly like a
    successful one does.

    The content is overwritten before the file is unlinked. That is best effort, not a
    guarantee: a journaling or copy-on-write file system may keep the old blocks. It
    removes the trivially recoverable copy at no cost, which is the whole claim.

.PARAMETER Path
    The file to remove. Pass exactly what the writing step passed, so the two cannot
    disagree about which file is meant if a workingDirectory is ever introduced.

.EXAMPLE
    .\scripts\pipeline\Remove-EnvironmentFile.ps1 -Path .env.pipeline

.OUTPUTS
    None. Throws if the file is still present afterwards.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path = '.env.pipeline'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "No $Path to remove."
    return
}

if ($PSCmdlet.ShouldProcess($Path, 'Overwrite and delete the file holding the access token')) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $length = (Get-Item -LiteralPath $resolved).Length
    [System.IO.File]::WriteAllBytes($resolved, (New-Object byte[] $length))
    Remove-Item -LiteralPath $resolved -Force
    Write-Host "Removed $Path."

    # A cleanup step that failed quietly is indistinguishable from one that ran, and
    # what it failed to do is leave a token on disk.
    if (Test-Path -LiteralPath $Path) {
        throw "$Path is still present after cleanup."
    }
}
