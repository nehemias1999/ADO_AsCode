<#
.SYNOPSIS
    Runs the full quality gate: static analysis, unit tests, and the sensitive data
    scan.

.DESCRIPTION
    One command, three checks, in increasing order of cost. Having a single entry
    point is not cosmetic: the previous generation of this codebase had test scripts
    with no runner, and by the time anyone looked, several assertions had been false
    for weeks. A suite nobody can run in one step is a suite nobody runs.

    The same command is what CI executes, so "it passed locally" and "it passed in CI"
    mean the same thing.

.PARAMETER Skip
    Checks to skip: Analyzer, Pester, Secrets.

.PARAMETER Path
    Restrict the Pester run to one path.

.EXAMPLE
    .\scripts\Invoke-Tests.ps1

    Runs everything.

.EXAMPLE
    .\scripts\Invoke-Tests.ps1 -Skip Analyzer -Path tests/foundation

    Runs only the foundation tests and the secret scan.
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyzer', 'Pester', 'Secrets')]
    [string[]] $Skip = @(),

    [string] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Write-TestLog {
    <#
    .SYNOPSIS
        Writes a prefixed progress line.

    .PARAMETER Message
        Text to write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)

    Write-Information "[tests] $Message" -InformationAction Continue
}

# --- 1. Parse check --------------------------------------------------------
# Cheapest possible check, and it catches the class of mistake that makes every
# other check report something confusing instead of the real problem.

Write-TestLog 'Parsing every script...'
# Filtering on the extension after enumeration, not with -Include: -Include is
# silently ignored when -Path carries no wildcard, which made this check try to
# parse every JSON and Markdown file in the repository.
$scriptFiles = @(
    Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
        Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|artifacts|\.local)[\\/]' }
)
foreach ($file in $scriptFiles) {
    $parseErrors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $file.FullName), [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $failures.Add("$($file.Name): $($parseErrors.Count) parse error(s) - first at line $($parseErrors[0].Token.StartLine)")
    }
}
Write-TestLog "Parsed $($scriptFiles.Count) script(s)."

# --- 2. Static analysis ----------------------------------------------------

if ($Skip -notcontains 'Analyzer') {
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -Force
        Write-TestLog 'Running PSScriptAnalyzer...'

        $settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

        # A rule that throws surfaces as a non-terminating error, and this script runs
        # under $ErrorActionPreference = 'Stop' - so an unhandled one aborted the whole
        # gate before Pester ran, with a NullReferenceException as the only diagnostic.
        # Captured instead, and counted as a failure: a rule that crashed did not
        # analyse its file, and a check that silently analysed nothing is worse than
        # one that says so.
        $analyzerError = $null
        $findings = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings $settingsPath `
                -ErrorVariable analyzerError -ErrorAction SilentlyContinue |
            Where-Object { $_.ScriptPath -notmatch '[\\/](\.git|artifacts|\.local)[\\/]' })

        $errors = @($findings | Where-Object { $_.Severity -eq 'Error' })
        $warnings = @($findings | Where-Object { $_.Severity -eq 'Warning' })

        # Every finding, not the first 40. The count that has to hold is zero, so a cap
        # only hides the rest of the work and buys a second round trip to CI. The bound
        # stays as a runaway guard for the day a rule misfires across the repository.
        foreach ($finding in ($findings | Sort-Object Severity, ScriptName, Line | Select-Object -First 200)) {
            Write-TestLog ("  {0,-8} {1}:{2} {3}" -f $finding.Severity, $finding.ScriptName, $finding.Line, $finding.RuleName)
        }
        if ($findings.Count -gt 200) {
            Write-TestLog "  ... $($findings.Count - 200) more finding(s) not listed."
        }

        # The tally is never capped: it is what shows whether one rule accounts for
        # everything, which is the difference between a real regression and a rule to
        # reconsider.
        foreach ($group in ($findings | Group-Object RuleName | Sort-Object Count -Descending)) {
            Write-TestLog ("  {0,4}  {1}" -f $group.Count, $group.Name)
        }

        Write-TestLog "PSScriptAnalyzer: $($errors.Count) error(s), $($warnings.Count) warning(s)."

        # Warnings fail. Almost every rule this repository actually relies on is
        # severity Warning - PSUseShouldProcessForStateChangingFunctions,
        # PSAvoidUsingEmptyCatchBlock, PSUseDeclaredVarsMoreThanAssignments,
        # PSUseCompatibleSyntax, PSAvoidUsingCmdletAliases - so a gate that failed only
        # on Error enforced almost none of them, while testing-strategy.md claimed it
        # caught exactly those. The repository is at zero findings under these settings,
        # so this costs no backlog: what it defends is the next one.
        if ($findings.Count -gt 0) {
            $failures.Add("PSScriptAnalyzer reported $($errors.Count) error(s) and $($warnings.Count) warning(s).")
        }
        if ($analyzerError.Count -gt 0) {
            foreach ($problem in $analyzerError) { Write-TestLog "  RULE ERROR $problem" }
            $failures.Add("$($analyzerError.Count) PSScriptAnalyzer rule(s) failed to run, so their files were not analysed.")
        }
    }
    else {
        # Not a skip. A missing analyzer used to make the strictest half of the gate
        # pass by doing nothing, and the point of one runner is that "it passed" means
        # the same thing on a workstation as in CI. Opting out is still possible; it is
        # just explicit now.
        $failures.Add('PSScriptAnalyzer is not installed, so static analysis did not run. Install-Module PSScriptAnalyzer -Scope CurrentUser, or re-run with -Skip Analyzer.')
    }
}

# --- 3. Unit tests ---------------------------------------------------------

if ($Skip -notcontains 'Pester') {
    $pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1

    if ($pester -and $pester.Version.Major -ge 5) {
        Import-Module Pester -MinimumVersion 5.0 -Force
        Write-TestLog "Running Pester $($pester.Version)..."

        $testPath = if ($Path) { $Path } else { Join-Path $repoRoot 'tests' }
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $testPath
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Detailed'
        $configuration.Should.ErrorAction = 'Continue'

        $result = Invoke-Pester -Configuration $configuration
        Write-TestLog "Pester: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped."
        if ($result.FailedCount -gt 0) {
            $failures.Add("$($result.FailedCount) test(s) failed.")
        }
    }
    else {
        $found = if ($pester) { "$($pester.Version)" } else { 'none' }
        # Windows ships Pester 3.4, whose syntax is incompatible with these tests.
        # Say so plainly rather than letting it fail with confusing parse errors.
        $failures.Add("Pester 5 is required but not available (found: $found). Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force")
    }
}

# --- 4. Sensitive data gate ------------------------------------------------

if ($Skip -notcontains 'Secrets') {
    Write-TestLog 'Running the sensitive data gate...'
    & (Join-Path $PSScriptRoot 'Test-NoSensitiveData.ps1')
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('The sensitive data gate reported findings.')
    }
}

# --- Result ----------------------------------------------------------------

if ($failures.Count -gt 0) {
    $detail = ($failures | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    Write-Warning "Quality gate failed:$([Environment]::NewLine)$detail"
    exit 1
}

Write-TestLog 'All checks passed.'
exit 0
