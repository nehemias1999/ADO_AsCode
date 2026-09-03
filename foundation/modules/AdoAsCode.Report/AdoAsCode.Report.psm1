<#
    AdoAsCode.Report - evidence writing, and the progress log that points at it.

    Three artefacts, each answering a different question.

    * A plan report answers "what was about to happen", and is the thing a
      reviewer approves. It is written before any change.
    * A receipt answers "what actually happened", and is written incrementally -
      after every completed operation, not once at the end. That distinction is
      the whole point: an apply that dies halfway through still leaves a record of
      exactly which operations completed, which is the only way to resume without
      guessing.
    * A Markdown summary answers "can a person read this without a JSON viewer",
      and is what gets attached to a change ticket.

    Everything written here passes through Remove-SensitiveValue first. A report
    is the artefact most likely to be pasted into a chat window, so redaction
    belongs at the writer, not at each call site.

    Write-AdoAsCodeLog is here too. A log line is not evidence - it is not kept and
    nothing is approved from it - but it carries the same run id as the plan and the
    receipt, which is what lets an operator holding one find the other.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Property names whose values are replaced before a report is written. Matching is
# on the name, not the value, so a credential is redacted even when it does not
# look like one.
#
# The pattern is built in two halves, because a single unanchored alternation is
# wrong in both directions at once.
#
# Long, unambiguous tokens match anywhere in the name. Case-insensitivity is what
# makes these cover camelCase too: 'sshkey' matches 'sshKey'.
$script:SensitiveNameFragment = @(
    'password', 'passwd', 'pwd', 'passphrase'
    'secret', 'credential', 'token', 'authorization'
    'apikey', 'api_key', 'accesskey', 'privatekey', 'private_key', 'sshkey', 'signingkey', 'keymaterial'
    'connectionstring', 'connstr', 'signature'
) -join '|'

# Short tokens that are also common substrings of innocent words. These match only
# as a whole word or a whole underscore/dash-delimited segment.
#
# 'pat' is the reason this split exists. Unanchored, it matched 'areaPaths',
# 'iterationPaths', 'reportPath', 'patch' and 'compatible' - so every
# team-provisioning inventory report silently replaced its Area Path and Iteration
# Path inventory, the very data the report exists to carry, with the redaction
# marker. Redaction that destroys evidence is not failing safe; it is failing
# quietly, which is worse.
$script:SensitiveNameSegment = @(
    'pat', 'key', 'sas', 'cert', 'auth', 'bearer'
) -join '|'

$script:SensitivePropertyPattern = "(?i)($($script:SensitiveNameFragment)|(?:^|[_-])(?:$($script:SensitiveNameSegment))(?:[_-]|$))"

function Remove-SensitiveValue {
    <#
    .SYNOPSIS
        Returns a copy of an object with sensitive property values replaced.

    .DESCRIPTION
        Walks objects, dictionaries and arrays. A property whose NAME looks like a
        credential is replaced with a fixed marker; everything else is copied. Name
        matching rather than value matching is deliberate: a weak password does not
        look like a secret, but its property name always does.

        Depth is capped so a cyclic or pathologically nested structure cannot hang
        the writer.

    .PARAMETER InputObject
        Object to sanitize.

    .PARAMETER Replacement
        Marker written in place of a sensitive value.

    .PARAMETER Depth
        Remaining recursion depth.

    .EXAMPLE
        Remove-SensitiveValue -InputObject $operation

    .OUTPUTS
        A sanitized copy. The input is not modified.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $InputObject,
        [string] $Replacement = '[redacted]',
        [ValidateRange(0, 32)] [int] $Depth = 12
    )

    if ($null -eq $InputObject) { return $null }
    if ($Depth -le 0) { return '[depth limit reached]' }

    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or
        $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal] -or
        $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            if ("$key" -match $script:SensitivePropertyPattern) {
                $copy["$key"] = $Replacement
                continue
            }
            $copy["$key"] = Remove-SensitiveValue -InputObject $InputObject[$key] -Replacement $Replacement -Depth ($Depth - 1)
        }
        return [pscustomobject]$copy
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @($InputObject | ForEach-Object {
            Remove-SensitiveValue -InputObject $_ -Replacement $Replacement -Depth ($Depth - 1)
        })
        # The leading comma is load-bearing. PowerShell enumerates a function's
        # output, so `return @($items)` hands a single-element array back to the
        # caller as the bare element - and a one-item list in an inventory then
        # serialised as a string instead of an array, silently changing the shape of
        # the evidence file. The comma wraps the array so enumeration yields it
        # whole.
        return , $items
    }

    $properties = @($InputObject.PSObject.Properties)
    if ($properties.Count -eq 0) { return $InputObject }

    $copy = [ordered]@{}
    foreach ($property in $properties) {
        if ($property.Name -match $script:SensitivePropertyPattern) {
            $copy[$property.Name] = $Replacement
            continue
        }
        $copy[$property.Name] = Remove-SensitiveValue -InputObject $property.Value -Replacement $Replacement -Depth ($Depth - 1)
    }
    return [pscustomobject]$copy
}

function Write-AdoAsCodeLog {
    <#
    .SYNOPSIS
        Writes one progress line, stamped with the time and the run it belongs to.

    .DESCRIPTION
        The information stream rather than the host, so a caller can capture or silence
        it. That much was already true - and was implemented three times, identically,
        once per entry point, two of which had lost the explanation when they were
        copied. It lives here because it emits what a run reports, alongside the plan
        and the receipt, and because the field that makes it useful comes from them.

        That field is the run id. A pipeline log interleaves several runs and the module
        name alone does not separate them; worse, an operator reading a log with a
        receipt in the other hand had nothing joining the two. The last eight characters
        of the run id appear on every line and in both artefacts.

        A timestamp, because an agent log supplies one and a workstation run does not,
        and reconstructing an incident from lines with no times is guesswork. UTC, to
        match `generatedAt`.

        Deliberately NOT here: the machine name. A log is the artefact least under
        anyone's control about where it ends up.

    .PARAMETER Module
        Name of the automation, so interleaved logs stay attributable.

    .PARAMETER Message
        Text to write.

    .PARAMETER RunId
        Correlation id from the provenance block. Absent before provenance is built -
        the offline validate path never builds one - and simply omitted then.

    .PARAMETER Level
        Severity tag. Progress by default.

    .EXAMPLE
        Write-AdoAsCodeLog -Module 'team-provisioning' -RunId $provenance.runId -Message 'Plan complete.'

    .OUTPUTS
        None. Writes to the information stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Module,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [string] $RunId,
        [ValidateSet('info', 'warn')] [string] $Level = 'info'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('HH:mm:ss')
    $prefix = $Module
    if (-not [string]::IsNullOrWhiteSpace($RunId) -and $RunId.Length -ge 8) {
        $prefix = "$Module $($RunId.Substring($RunId.Length - 8))"
    }
    $tag = if ($Level -eq 'warn') { ' WARN' } else { '' }

    Write-Information "$timestamp [$prefix]$tag $Message" -InformationAction Continue
}

function Save-Utf8File {
    <#
    .SYNOPSIS
        Writes text as UTF-8 without a byte order mark.

    .DESCRIPTION
        Set-Content -Encoding UTF8 emits a BOM in Windows PowerShell 5.1, which is the
        floor this repository supports - so every report and receipt produced there
        began with three bytes that a strict JSON parser rejects. The two committed
        examples carry it, which is how it was found.

    .PARAMETER Path
        Destination path. Relative paths resolve against the PowerShell location, not
        the process working directory, which are not always the same.

    .PARAMETER Content
        The text to write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )

    $fullPath = $Path
    if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $fullPath))
    }
    [System.IO.File]::WriteAllText($fullPath, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ProvenanceValue {
    <#
    .SYNOPSIS
        Evaluates a probe and returns $null instead of throwing.

    .DESCRIPTION
        Structural rather than a convenience. Every field of a provenance block is
        best-effort by definition - a run from a downloaded artefact has no .git, a
        workstation has no build id, a locked-down host may refuse a query - and an
        apply that refused to run because it could not read a commit SHA would have
        traded the thing it was recording for the record of it.

        A try/catch rather than a null check, because under Set-StrictMode -Version
        Latest, which every file here sets, touching a missing property is itself a
        terminating error.

    .PARAMETER Probe
        Script block producing the value.

    .EXAMPLE
        Get-ProvenanceValue -Probe { $env:COMPUTERNAME }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Probe
    )

    try {
        $value = & $Probe
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $null }
        return $value
    }
    catch {
        Write-Verbose "Provenance probe failed: $($_.Exception.Message)"
        return $null
    }
}

function New-AdoAsCodeProvenance {
    <#
    .SYNOPSIS
        Builds the block recording who ran a command, from where, and at which commit.

    .DESCRIPTION
        A report said what would change and a receipt said what did. Neither said who,
        nor from which revision of the declarations - and for a product whose premise is
        that configuration is versioned in Git, that is the missing link: this PROD
        Variable Group looks like this because of commit X, applied by that person.
        Reconstructing it meant finding the build by date and reading its commit.

        Every field is best-effort and any of them may be $null. Nothing here may fail a
        run: the evidence is worth less than the change it records. `commitOrigin`
        distinguishes "there is no commit" from "we did not look".

        Build once per run and pass it to the writers. The receipt is rewritten after
        every completed operation, so building it inside the writer would shell out to
        git dozens of times in one apply.

        Deliberately NOT resolved here: the Azure DevOps identity behind the token.
        This module knows nothing about Azure DevOps (ADR 0004), so the entry point
        looks it up and passes the display name in.

    .PARAMETER Module
        Name of the automation.

    .PARAMETER Command
        The verb being run.

    .PARAMETER ActorDisplayName
        Display name of the identity behind the access token, resolved by the caller.
        Optional: a validate run has no credential at all.

    .PARAMETER RunId
        Override the generated correlation id. Injectable so a test, and the committed
        examples, can assert on a fixed value.

    .EXAMPLE
        New-AdoAsCodeProvenance -Module 'team-provisioning' -Command 'apply' -ActorDisplayName 'Dana Reyes'

    .OUTPUTS
        PSCustomObject with runId, module, command, actor, origin, source and tool.
    #>
    # Pure function: it reads the environment and computes a value, changing no system
    # state. The New- verb is what draws the rule; there is nothing here to confirm.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Module,
        [Parameter(Mandatory)] [string] $Command,
        [string] $ActorDisplayName,
        [string] $RunId
    )

    if (-not $RunId) {
        # Sortable, collision-free, and short enough that the last eight characters
        # work as a log prefix. Generated locally even on an agent: it identifies one
        # execution of the script, where a build id survives a rerun of a failed stage.
        $RunId = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'),
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    $isPipeline = [bool] (Get-ProvenanceValue -Probe {
            $env:TF_BUILD -eq 'True' -or $env:GITHUB_ACTIONS -eq 'true'
        })

    # A report is the artefact most likely to be pasted into a chat window, and it now
    # carries an operator's name and a host name. That is the point - "from where" is
    # half of provenance - but an environment with a stricter rule can drop the two
    # identifying fields and keep runId, commit and buildId, which are what make the
    # receipt useful.
    $omitOrigin = -not [string]::IsNullOrWhiteSpace(
        (Get-ProvenanceValue -Probe { $env:ADO_ASCODE_PROVENANCE_OMIT_ORIGIN }))

    $commit = Get-ProvenanceValue -Probe { $env:BUILD_SOURCEVERSION }
    $commitOrigin = 'environment'
    if (-not $commit) {
        $commit = Get-ProvenanceValue -Probe { $env:GITHUB_SHA }
    }
    if (-not $commit) {
        $commitOrigin = 'git'
        $commit = Get-ProvenanceValue -Probe {
            $repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
            # Guarded on .git existing. git walks upward, so without this an artefact
            # unpacked inside some other checkout would report that repository's commit
            # - confidently, and wrongly.
            if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))) { return $null }
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
            $sha = & git -C $repositoryRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            "$sha".Trim()
        }
    }
    if (-not $commit) { $commitOrigin = 'unavailable' }

    $origin = [ordered]@{
        kind    = if ($isPipeline) { 'pipeline' } else { 'workstation' }
        machine = if ($omitOrigin) { $null } else {
            Get-ProvenanceValue -Probe {
                if ($env:AGENT_MACHINENAME) { $env:AGENT_MACHINENAME } else { [Environment]::MachineName }
            }
        }
    }
    if ($isPipeline) {
        $origin.pipeline = [ordered]@{
            buildId        = Get-ProvenanceValue -Probe { $env:BUILD_BUILDID }
            definitionName = Get-ProvenanceValue -Probe { $env:BUILD_DEFINITIONNAME }
            requestedFor   = Get-ProvenanceValue -Probe { $env:BUILD_REQUESTEDFOR }
        }
    }

    [pscustomobject]@{
        runId   = $RunId
        module  = $Module
        command = $Command
        actor   = [pscustomobject]([ordered]@{
                adoDisplayName = if ([string]::IsNullOrWhiteSpace($ActorDisplayName)) { $null } else { $ActorDisplayName }
                osUser         = if ($omitOrigin) { $null } else { Get-ProvenanceValue -Probe { [Environment]::UserName } }
            })
        origin  = [pscustomobject]$origin
        source  = [pscustomobject]([ordered]@{
                commit       = $commit
                commitOrigin = $commitOrigin
                branch       = Get-ProvenanceValue -Probe {
                    if ($env:BUILD_SOURCEBRANCH) { $env:BUILD_SOURCEBRANCH } else { $env:GITHUB_REF }
                }
            })
        tool    = [pscustomobject]([ordered]@{
                powerShellVersion = "$($PSVersionTable.PSVersion)"
                powerShellEdition = Get-ProvenanceValue -Probe { "$($PSVersionTable.PSEdition)" }
            })
    }
}

function Write-AdoAsCodeReport {
    <#
    .SYNOPSIS
        Writes a plan or result report as JSON, plus a Markdown sibling.

    .DESCRIPTION
        The JSON file is the machine-readable record; the Markdown file next to it
        is what a person reads or attaches to a ticket. Both are written from the
        same sanitized object, so they cannot disagree.

        The parent directory is created if needed. Reports belong under `artifacts/`,
        which is excluded from version control: they describe one run of one
        environment and are not part of the declared state.

    .PARAMETER Plan
        Plan object from New-Plan.

    .PARAMETER Path
        Destination path for the JSON report. The Markdown file replaces the
        extension with .md.

    .PARAMETER Module
        Name of the automation that produced the report.

    .PARAMETER Detail
        Optional extra object to embed, for example the inventory counts observed.

    .PARAMETER Provenance
        Block from New-AdoAsCodeProvenance, recording who ran the command and at which
        commit. Optional so the writer stays usable without one; a test asserts that no
        entry point omits it, because a report with no actor is the gap it was added to
        close.

    .EXAMPLE
        Write-AdoAsCodeReport -Plan $plan -Path 'artifacts/reports/team-provisioning-APP_ALPHA.json' -Module 'team-provisioning'

    .OUTPUTS
        PSCustomObject with JsonPath and MarkdownPath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Module,
        [object] $Detail,
        [object] $Provenance
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $summary = Get-PlanSummary -Plan $Plan
    $report = [ordered]@{
        module      = $Module
        command     = $Plan.command
        target      = $Plan.target
        generatedAt = $Plan.generatedAt
    }
    if ($null -ne $Provenance) {
        $report.provenance = $Provenance
    }
    $report.summary = $summary
    $report.operations = @($Plan.operations)
    if ($PSBoundParameters.ContainsKey('Detail') -and $null -ne $Detail) {
        $report.detail = $Detail
    }

    $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]$report)
    Save-Utf8File -Path $Path -Content ($sanitized | ConvertTo-Json -Depth 12)

    $markdownPath = [System.IO.Path]::ChangeExtension($Path, '.md')
    Save-Utf8File -Path $markdownPath -Content (Format-AdoAsCodeReportMarkdown -Report $sanitized)

    Write-Verbose "Wrote report '$Path' and summary '$markdownPath'."
    return [pscustomobject]@{ JsonPath = $Path; MarkdownPath = $markdownPath }
}

function Format-AdoAsCodeReportMarkdown {
    <#
    .SYNOPSIS
        Renders a report object as Markdown.

    .DESCRIPTION
        Pure function, so the rendering is covered by tests without touching the
        file system - see tests/foundation/PureFunctions.Tests.ps1. That sentence stood
        here for a while before it was true, which is the sharper failure of the two: a
        documented claim of coverage is what stops anyone checking.

        Operations are grouped by status, with the ones needing attention first, because
        that is the order a reviewer reads in. A pipe in a reason is escaped, since a
        reason is free text written for a person and a bare pipe silently splits the
        table row - mangling exactly the field the reviewer needs.

    .PARAMETER Report
        Sanitized report object.

    .EXAMPLE
        Format-AdoAsCodeReportMarkdown -Report $report

    .OUTPUTS
        The Markdown document as a single string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Report
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $($Report.module): $($Report.command) - $($Report.target)")
    $lines.Add('')
    $lines.Add("Generated at $($Report.generatedAt) (UTC).")
    $lines.Add('')

    # Guarded, and it has to be. Under Set-StrictMode -Version Latest, reading a missing
    # property throws, and a report built without provenance is a shape this function
    # still has to render - the parameter is optional and the tests build one.
    if ($Report.PSObject.Properties.Name -contains 'provenance' -and $null -ne $Report.provenance) {
        $p = $Report.provenance
        $lines.Add('## Provenance')
        $lines.Add('')
        $lines.Add('| Field | Value |')
        $lines.Add('| --- | --- |')
        # Flattened to four rows on purpose: someone reading the Markdown summary wants
        # to know who and from where, not to navigate a nested object. 'not recorded'
        # rather than a blank, so a missing value reads as "we looked and could not
        # tell" instead of as a rendering fault.
        $notRecorded = 'not recorded'
        $lines.Add("| Run | $($p.runId) |")

        $actor = "$($p.actor.adoDisplayName)"
        if ([string]::IsNullOrWhiteSpace($actor)) { $actor = $notRecorded }
        $osUser = "$($p.actor.osUser)"
        if (-not [string]::IsNullOrWhiteSpace($osUser)) { $actor = "$actor (as $osUser)" }
        $lines.Add("| Actor | $actor |")

        $origin = "$($p.origin.kind)"
        if (-not [string]::IsNullOrWhiteSpace("$($p.origin.machine)")) { $origin = "$origin on $($p.origin.machine)" }
        if ($p.origin.PSObject.Properties.Name -contains 'pipeline' -and $null -ne $p.origin.pipeline) {
            $origin = "$origin, build $($p.origin.pipeline.buildId), queued by $($p.origin.pipeline.requestedFor)"
        }
        $lines.Add("| Origin | $origin |")

        $commit = "$($p.source.commit)"
        if ([string]::IsNullOrWhiteSpace($commit)) { $commit = $notRecorded }
        if (-not [string]::IsNullOrWhiteSpace("$($p.source.branch)")) { $commit = "$commit ($($p.source.branch))" }
        $lines.Add("| Commit | $commit |")
        $lines.Add('')
    }

    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add('| Status | Count |')
    $lines.Add('| --- | --- |')
    foreach ($property in $Report.summary.PSObject.Properties) {
        $lines.Add("| $($property.Name) | $($property.Value) |")
    }
    $lines.Add('')
    $lines.Add('## Operations')
    $lines.Add('')

    $operations = @($Report.operations)
    if ($operations.Count -eq 0) {
        $lines.Add('No operations were produced.')
    }
    else {
        foreach ($status in @('blocked', 'warning', 'pending', 'protected', 'ok')) {
            $items = @($operations | Where-Object { $_.status -eq $status })
            if ($items.Count -eq 0) { continue }

            $lines.Add("### $status ($($items.Count))")
            $lines.Add('')
            $lines.Add('| Resource | Name | Action | Reason |')
            $lines.Add('| --- | --- | --- | --- |')
            foreach ($item in $items) {
                $reason = "$($item.reason)" -replace '\|', '\|'
                $lines.Add("| $($item.resource) | $($item.name) | $($item.action) | $reason |")
            }
            $lines.Add('')
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Save-AdoAsCodeReceipt {
    <#
    .SYNOPSIS
        Writes or updates the receipt of an apply.

    .DESCRIPTION
        Called after every completed operation, not once at the end. The file is
        rewritten each time, which is cheap and means the record on disk is never
        behind what has actually been done.

        `status` moves from in_progress to completed or failed. A receipt left at
        in_progress is itself the signal that the run was interrupted, and its
        completedOperations list is what the operator resumes from.

    .PARAMETER Path
        Receipt path. Conventionally the report path with a .receipt.json extension.

    .PARAMETER Target
        What was being applied.

    .PARAMETER Status
        'in_progress', 'completed' or 'failed'.

    .PARAMETER CompletedOperations
        Operations finished so far.

    .PARAMETER Message
        Optional note, typically the failure reason.

    .PARAMETER Provenance
        Block from New-AdoAsCodeProvenance. The same object the report carries, so its
        runId joins the two - and a receipt detached from its build still names the
        commit it came from.

    .EXAMPLE
        Save-AdoAsCodeReceipt -Path $receiptPath -Target 'APP_ALPHA' -Status in_progress -CompletedOperations $done
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [ValidateSet('in_progress', 'completed', 'failed')] [string] $Status,
        [AllowEmptyCollection()] [object[]] $CompletedOperations = @(),
        [string] $Message = '',
        [object] $Provenance
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    # Ordered, not a plain hashtable literal. The field order of a receipt used to be
    # incidental, and this is a file people read.
    $receipt = [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Provenance) {
        $receipt.provenance = $Provenance
    }
    $receipt.target = $Target
    $receipt.status = $Status
    $receipt.message = $Message
    $receipt.completedOperations = @($CompletedOperations)

    $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]$receipt)
    Save-Utf8File -Path $Path -Content ($sanitized | ConvertTo-Json -Depth 12)
}

function Get-AdoAsCodeReceiptPath {
    <#
    .SYNOPSIS
        Derives the receipt path that belongs to a report path.

    .DESCRIPTION
        One convention in one place, so a report and its receipt always sit side by
        side and can be found without being told where to look.

    .PARAMETER ReportPath
        Path of the JSON report.

    .EXAMPLE
        Get-AdoAsCodeReceiptPath -ReportPath 'artifacts/plans/apply-APP_ALPHA.json'

        Returns 'artifacts/plans/apply-APP_ALPHA.receipt.json'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ReportPath
    )

    return [System.IO.Path]::ChangeExtension($ReportPath, 'receipt.json')
}

Export-ModuleMember -Function @(
    'Remove-SensitiveValue',
    'New-AdoAsCodeProvenance',
    'Write-AdoAsCodeLog',
    'Write-AdoAsCodeReport',
    'Format-AdoAsCodeReportMarkdown',
    'Save-AdoAsCodeReceipt',
    'Get-AdoAsCodeReceiptPath'
)
