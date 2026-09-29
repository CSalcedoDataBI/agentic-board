<#
.SYNOPSIS
    /scan in one command (#738, #731): find the untracked work in the CURRENT repo, propose a
    prioritized and ordered plan grouped into PR batches, and - on one confirmation - turn it into a
    standardized board, labelled issues, a filled board and a plan epic.

.DESCRIPTION
    Two phases, and only the second writes anything to GitHub.

    PLAN (default). Read-only on GitHub; writes one local file, <state>/scan-plan.json.
      1. Scan tracked files (git grep, so .gitignore is honoured):
           * code debt markers  TODO / FIXME / HACK / XXX / BUG, only in the TAG: / TAG( form;
           * unchecked `- [ ]` checklist items in Markdown;
           * bullets under a "pending / next steps / to do / por hacer" heading;
           * plan and spec documents (docs/**/plans, specs/, .claude/plans), and any Markdown file
             with 12+ open items, each as ONE plan item: its own checklist tracks its steps.
         Skill, agent and template folders are skipped: their checklists are content, not work.
         A title found in several files is one item that lists every place.
      2. Normalize every finding to a preset type label (bug, feature, chore, docs, refactor,
         spike) - the labels Board-Fill reads, not ad-hoc `type:*` ones (#731).
      3. Drop what is already tracked: an open issue with the same title, or one that cites the
         plan document's path. Items already created by an earlier apply keep their issue number.
      4. Propose a Priority for each item WITH the reason, a dependency list (an item that says
         "blocked by #12" / "depends on #12" waits on it), an order, and PR batches (items of the
         same area, unblocked, at most -MaxBatch per PR).

    APPLY (-Apply). Reads the plan file and, for the chosen -Rows (default: all):
      1. Resolve-Board.ps1: reuse the repo's board, or create one with the canonical field preset
         (Priority, Size, Task Type, Area, Estimate, Target; Status with In Review and Blocked).
         -BareBoard creates it without the preset.
      2. Apply-LabelPreset.ps1: the label taxonomy (including blocked, plan, spike).
      3. One issue per item, labelled `scan` + its type label (+ `blocked` when it waits on another
         issue), added to the board with its Priority, Status = Blocked when blocked, and Task Type
         = Spike for spikes.
      4. A plan epic listing everything in order with the PR batches; each item becomes a native
         sub-issue of the epic.
      5. Board-Fill.ps1 -Auto fills whatever is still empty (Status, Size, Type, assignee).
      The plan file records every issue created, so running apply again never duplicates one.

.PARAMETER Apply
    Execute the plan in the plan file. Without it the script only plans.

.PARAMETER Rows
    Apply only these row numbers (as printed by the plan). Default: every row.

.PARAMETER DryRun
    With -Apply: print the steps and write nothing.

.PARAMETER BareBoard
    With -Apply: if a board has to be created, create it without the field preset.

.PARAMETER NoFill
    With -Apply: skip the final Board-Fill -Auto.

.PARAMETER MaxBatch
    Most items per proposed PR batch (default 4).

.PARAMETER Json
    Emit the plan (or the apply result) as JSON.
#>
[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$Repo = "",
    [string]$Owner = "",
    [switch]$Apply,
    [int[]]$Rows = @(),
    [switch]$DryRun,
    [switch]$BareBoard,
    [switch]$NoFill,
    [ValidateSet('en', 'es')][string]$Lang = 'en',
    [ValidateRange(1, 20)][int]$MaxBatch = 4,
    [string]$PlanFile = "",
    [switch]$Json,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ pure helpers

$script:MarkerRegex   = '\b(?<tag>TODO|FIXME|HACK|XXX|BUG)\b(?:\s*\((?<scope>[^)]*)\))?(?:\s+[A-Z0-9][\w-]*)?\s*:\s*(?<text>.*)$'
$script:ChecklistRe   = '^\s*[-*]\s+\[ \]\s+(?<text>.+)$'
$script:PendingHeadRe = '(?i)^\s*#{1,6}\s*(pending|pendiente|pendientes|next steps|to ?do|por hacer|open questions|follow[- ]ups?)\b'
$script:DependsRe     = '(?i)\b(blocked by|depends on|after|requires|needs|waits? (?:on|for))\s+#(?<n>\d+)'
$script:TypeOrder     = @{ bug = 0; feature = 1; chore = 2; refactor = 3; spike = 4; docs = 5 }

# A title a human would write: marker/checkbox syntax and trailing comment closers stripped, one
# line, at most 80 characters. PURE.
function Get-ScanTitle([string]$Text) {
    $t = "$Text" -replace '\s*(\*/|-->|#>)\s*$', '' -replace '[`*_]{1,2}', '' -replace '\s+', ' '
    $t = $t.Trim().TrimEnd('.', ':', ';', ',')
    if (-not $t) { return '' }
    $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1)
    if ($t.Length -gt 80) { $t = $t.Substring(0, 77).TrimEnd() + '...' }
    $t
}

# The preset type label for a finding. PURE.
#   Kind: marker | checklist | pending | plan      Tag: the debt marker for Kind=marker
function Get-ScanType([string]$Kind, [string]$Tag, [string]$Text, [string]$Path) {
    $x = "$Text"
    # English and Spanish wording: the findings are in the repo's language, not the tool's.
    if ($x -match '(?i)\b(investigate|research|spike|evaluate|explore|prototype|figure out|decide|poc|investigar|evaluar|explorar|revisar si|buscar|decidir|averiguar)\b') { return 'spike' }
    if ($Kind -eq 'plan') { return 'feature' }
    if ($Kind -eq 'marker') {
        switch ($Tag) {
            'FIXME' { return 'bug' }
            'BUG'   { return 'bug' }
            'HACK'  { return 'refactor' }
            'XXX'   { return 'refactor' }
        }
    }
    if ($x -match '(?i)\b(fix|broken|bug|crash|regression|arreglar|corregir|roto|rota)\b') { return 'bug' }
    if ($x -match '(?i)\b(document|docs?|readme|changelog|guide|tutorial|documentar|anotar|volcar)\b') { return 'docs' }
    if ($x -match '(?i)\b(refactor|clean ?up|simplify|rename|extract|dedupe|refactorizar|limpiar|simplificar|renombrar|endurecer)\b') { return 'refactor' }
    if ($x -match '(?i)\b(add|implement|support|create|build|new|enable|allow|expose|agregar|añadir|crear|implementar|soportar|habilitar|migrar)\b') { return 'feature' }
    'chore'
}

# The proposed Priority and the reason for it, in words a reviewer can disagree with. PURE.
function Get-ScanPriority([string]$Type, [string]$Kind, [string]$Tag, [string]$Text) {
    $mk = { param($p, $why) [pscustomobject]@{ Priority = $p; Reason = $why } }
    if ("$Text" -match '(?i)\b(security|vulnerab\w*|secret|credential|data loss|leak\w*|corrupt\w*|crash\w*|outage|prod(uction)? down)\b') {
        return (& $mk 'P0' "mentions '$($Matches[1])': a risk to data, security or uptime")
    }
    if ("$Text" -match '(?i)\b(overdue|expired|deadline|past due|vencido|vencida|caduca\w*|retir\w+|antes de)\b') {
        return (& $mk 'P1' "mentions '$($Matches[1])': it has a date")
    }
    if ($Type -eq 'bug') { return (& $mk 'P1' "a known defect ($(if ($Tag) { $Tag } else { 'bug wording' })) that already affects the code") }
    if ($Kind -eq 'plan') { return (& $mk 'P1' 'a written plan is committed intent, and it orders the rest') }
    if ($Type -eq 'docs') { return (& $mk 'P3' 'documentation only: no behavior depends on it') }
    if ($Type -eq 'refactor') { return (& $mk 'P3' 'a shortcut in working code: worth doing, not urgent') }
    if ($Type -eq 'spike') { return (& $mk 'P2' 'an open question: answering it unblocks decisions') }
    (& $mk 'P2' "planned $Type work with no sign of urgency")
}

# Issue numbers an item says it waits on. PURE.
function Get-ScanDependencies([string]$Text) {
    @([regex]::Matches("$Text", $script:DependsRe) | ForEach-Object { [int]$_.Groups['n'].Value } | Select-Object -Unique)
}

# The area an item belongs to: its first two folders ('(root)' for a top-level file). PURE.
function Get-ScanArea([string]$Path) {
    $parts = @(("$Path" -replace '\\', '/').Split('/') | Where-Object { $_ })
    if ($parts.Count -le 1) { return '(root)' }
    ($parts[0..([Math]::Min(2, $parts.Count - 1) - 1)] -join '/')
}

# One finding -> one plan item. PURE.
function New-ScanItem {
    param([string]$Kind, [string]$Path, [int]$Line, [string]$Text, [string]$Tag = '', [string]$Evidence = '')
    $title = Get-ScanTitle $Text
    if (-not $title) { return $null }
    $type = Get-ScanType -Kind $Kind -Tag $Tag -Text $Text -Path $Path
    $prio = Get-ScanPriority -Type $type -Kind $Kind -Tag $Tag -Text $Text
    [pscustomobject]@{
        Row = 0; Kind = $Kind; Title = $title; Type = $type; Tag = $Tag
        Source = if ($Line -gt 0) { "${Path}:$Line" } else { $Path }; Path = ($Path -replace '\\', '/'); Line = $Line
        Area = Get-ScanArea $Path; Evidence = if ($Evidence) { $Evidence.Trim() } else { "$Text".Trim() }
        Priority = $prio.Priority; PriorityReason = $prio.Reason
        DependsOn = @(Get-ScanDependencies $Text); AlsoIn = @()
        Issue = 0; Tracked = ''
    }
}

# Findings from `git grep -n` output lines ("path:line:text"). PURE.
function ConvertFrom-MarkerGrep([string[]]$Lines) {
    foreach ($l in $Lines) {
        if ($l -notmatch '^(?<p>[^:]+):(?<n>\d+):(?<t>.*)$') { continue }
        $p = $Matches.p; $n = [int]$Matches.n; $t = $Matches.t
        $m = [regex]::Match($t, $script:MarkerRegex)
        if (-not $m.Success) { continue }
        $tag = $m.Groups['tag'].Value
        # The tag must be a comment marker, not a word inside a string or identifier.
        $before = $t.Substring(0, $m.Index)
        if ($before -match '[A-Za-z0-9_]$') { continue }
        $text = $m.Groups['text'].Value
        if (-not $text.Trim()) { continue }
        New-ScanItem -Kind 'marker' -Path $p -Line $n -Tag $tag -Text $text -Evidence $t
    }
}

# Checklist items and pending-section bullets from one Markdown file. PURE.
# A plan/spec document (-IsPlan), or any file with -PlanThreshold or more open items, is ONE item: a
# plan epic. Its own checklist already tracks its steps, and exploding it into one issue per step
# buried the real findings under hundreds of "Step 3: run the test" rows (measured on a real repo:
# 536 rows, most of them steps of five copies of one plan).
function ConvertFrom-MarkdownScan([string]$Path, [string[]]$Content, [switch]$IsPlan, [int]$PlanThreshold = 12) {
    $out = [System.Collections.Generic.List[object]]::new()
    $inPending = $false; $inFence = $false
    for ($i = 0; $i -lt $Content.Count; $i++) {
        $l = $Content[$i]
        if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($l -match '^\s*#{1,6}\s') { $inPending = $l -match $script:PendingHeadRe; continue }
        $item = $null
        if ($l -match $script:ChecklistRe) {
            $item = New-ScanItem -Kind 'checklist' -Path $Path -Line ($i + 1) -Text $Matches.text -Evidence $l
        } elseif ($inPending -and $l -match '^\s*[-*]\s+(?!\[[xX]\])(?<text>.+)$') {
            $item = New-ScanItem -Kind 'pending' -Path $Path -Line ($i + 1) -Text $Matches.text -Evidence $l
        }
        if ($item) { $out.Add($item) }
    }
    if ($IsPlan -or $out.Count -ge $PlanThreshold) {
        $h = $Content | Where-Object { $_ -match '^\s*#\s+(.+)$' } | Select-Object -First 1
        $name = if ($h -and $h -match '^\s*#\s+(.+)$') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
        $what = if ($IsPlan) { 'Plan document' } else { 'Checklist document' }
        $plan = New-ScanItem -Kind 'plan' -Path $Path -Line 0 -Text "Plan: $name" -Evidence "$what $Path - $($out.Count) open item(s); its own checklist tracks the steps"
        if ($plan) { return $plan }
        return
    }
    $out.ToArray()
}

function Get-NormalizedTitle([string]$t) { ("$t".ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() }

# Mark items that an open issue already tracks. PURE.
#   $OpenIssues - { number; title; body }
function Set-ScanTracked([object[]]$Items, [object[]]$OpenIssues) {
    $byTitle = @{}
    foreach ($i in $OpenIssues) { $k = Get-NormalizedTitle $i.title; if ($k -and -not $byTitle.ContainsKey($k)) { $byTitle[$k] = $i.number } }
    foreach ($it in $Items) {
        if ($it.Issue) { continue }
        $k = Get-NormalizedTitle $it.Title
        if ($byTitle.ContainsKey($k)) { $it.Tracked = "#$($byTitle[$k]) has the same title"; continue }
        if ($it.Kind -eq 'plan') {
            $hit = $OpenIssues | Where-Object { "$($_.body)`n$($_.title)" -like "*$($it.Path)*" } | Select-Object -First 1
            if ($hit) { $it.Tracked = "#$($hit.number) cites $($it.Path)" }
        }
    }
    $Items
}

# One item per title. A title found again (the same file twice, or a document copied into several
# folders) folds into the first one, which lists the other places in AlsoIn. PURE.
function Select-UniqueScanItem([object[]]$Items) {
    $seen = [ordered]@{}
    foreach ($it in $Items) {
        $k = Get-NormalizedTitle $it.Title
        if ($seen.Contains($k)) {
            $first = $seen[$k]
            if ($it.Source -ne $first.Source -and $first.AlsoIn -notcontains $it.Source) { $first.AlsoIn = @($first.AlsoIn) + $it.Source }
            continue
        }
        $seen[$k] = $it
    }
    @($seen.Values)
}

# Order: unblocked before blocked, then Priority, then plan documents before their children, then
# type, then source. Rows are numbered in that order. PURE.
function Set-ScanOrder([object[]]$Items) {
    $sorted = @($Items | Sort-Object `
        @{ Expression = { if (@($_.DependsOn).Count) { 1 } else { 0 } } }, `
        @{ Expression = { $_.Priority } }, `
        @{ Expression = { if ($_.Kind -eq 'plan') { 0 } else { 1 } } }, `
        @{ Expression = { $script:TypeOrder[$_.Type] } }, `
        @{ Expression = { $_.Path } }, @{ Expression = { $_.Line } })
    $n = 0
    foreach ($it in $sorted) { $n++; $it.Row = $n }
    $sorted
}

# PR batches: unblocked items of one area share a PR, at most $Max each; an item that waits on an
# issue gets a batch of its own, named after what it waits on; plan documents are epics, not PRs.
# Batches are ordered by their most urgent item. PURE.
function Get-ScanBatches([object[]]$Items, [int]$Max = 4) {
    $batches = [System.Collections.Generic.List[object]]::new()
    $work = @($Items | Where-Object { $_.Kind -ne 'plan' -and -not $_.Tracked })
    foreach ($g in ($work | Where-Object { -not @($_.DependsOn).Count } | Group-Object Area)) {
        $rows = @($g.Group | Sort-Object Row)
        for ($i = 0; $i -lt $rows.Count; $i += $Max) {
            $chunk = @($rows[$i..([Math]::Min($i + $Max, $rows.Count) - 1)])
            $batches.Add([pscustomobject]@{ Area = $g.Name; Rows = @($chunk.Row); Waits = @()
                Best = ($chunk.Priority | Sort-Object | Select-Object -First 1); First = $chunk[0].Row })
        }
    }
    foreach ($it in ($work | Where-Object { @($_.DependsOn).Count })) {
        $batches.Add([pscustomobject]@{ Area = $it.Area; Rows = @($it.Row); Waits = @($it.DependsOn)
            Best = $it.Priority; First = $it.Row })
    }
    $ordered = @($batches | Sort-Object @{ Expression = { if ($_.Waits.Count) { 1 } else { 0 } } }, Best, First)
    $n = 0
    foreach ($b in $ordered) {
        $n++
        $b | Add-Member -NotePropertyName Batch -NotePropertyValue $n -Force
        $w = if ($b.Waits.Count) { " - waits on $(($b.Waits | ForEach-Object { "#$_" }) -join ', ')" } else { '' }
        $b | Add-Member -NotePropertyName Title -NotePropertyValue "PR $n - $($b.Area): $($b.Rows.Count) item(s)$w" -Force
    }
    $ordered
}

# The issue body for one item. PURE.
function New-ScanIssueBody($Item) {
    $deps = if (@($Item.DependsOn).Count) { "`n**Blocked by:** $((@($Item.DependsOn) | ForEach-Object { "#$_" }) -join ', ')`n" } else { '' }
    $tick = [char]96
    $also = if (@($Item.AlsoIn).Count) { "`n**Also in:** " + ((@($Item.AlsoIn) | ForEach-Object { "$tick$_$tick" }) -join ', ') } else { '' }
    @"
**Source:** ``$($Item.Source)``$also

``````
$($Item.Evidence)
``````

**Proposed priority:** $($Item.Priority) - $($Item.PriorityReason)
$deps
Harvested by ``/scan``.
"@
}

# The plan epic body: every item in order, then the PR batches. PURE.
#   $Items must carry .Issue for the items that exist on GitHub.
function New-ScanEpicBody([object[]]$Items, [object[]]$Batches) {
    $ref = { param($it) if ($it.Issue) { "#$($it.Issue)" } else { "row $($it.Row)" } }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Work found by `/scan`, in the proposed order. Priority reasons are in each issue.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Order')
    foreach ($it in ($Items | Sort-Object Row)) {
        $w = if (@($it.DependsOn).Count) { " - blocked by $((@($it.DependsOn) | ForEach-Object { "#$_" }) -join ', ')" } else { '' }
        [void]$sb.AppendLine("- [ ] $(& $ref $it) $($it.Title) ($($it.Priority), $($it.Type))$w")
    }
    if (@($Batches).Count) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## Proposed PRs')
        foreach ($b in $Batches) {
            $refs = @($b.Rows | ForEach-Object { $r = $_; $it = $Items | Where-Object Row -eq $r | Select-Object -First 1; if ($it) { & $ref $it } }) -join ', '
            [void]$sb.AppendLine("$($b.Batch). **$($b.Area)**: $refs$(if ($b.Waits.Count) { " - waits on $(($b.Waits | ForEach-Object { "#$_" }) -join ', ')" })")
        }
    }
    $sb.ToString().TrimEnd()
}

# What apply would do for the chosen rows, in order. PURE - the live code only executes it.
function Get-ScanApplySteps([object[]]$Items, [int[]]$Rows = @(), [switch]$BareBoard, [switch]$NoFill) {
    $chosen = @($Items | Where-Object { -not $_.Tracked -and (-not $Rows.Count -or $Rows -contains $_.Row) })
    $new = @($chosen | Where-Object { -not $_.Issue })
    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add("board: reuse this repo's board, or create one $(if ($BareBoard) { 'WITHOUT' } else { 'with' }) the standard fields")
    $steps.Add('labels: apply the label taxonomy (bug, feature, chore, docs, refactor, spike, blocked, plan) and `scan`')
    foreach ($it in $new) {
        $labels = @('scan', $it.Type) + $(if (@($it.DependsOn).Count) { 'blocked' }) + $(if ($it.Kind -eq 'plan') { 'plan' })
        $extra = if (@($it.DependsOn).Count) { ', Status Blocked' } else { '' }
        $steps.Add("issue: row $($it.Row) '$($it.Title)' [$(($labels | Where-Object { $_ }) -join ', ')] -> board, Priority $($it.Priority)$extra")
    }
    if ($chosen.Count) { $steps.Add("epic: one plan epic with $($chosen.Count) item(s) as sub-issues and the PR batches") }
    if (-not $NoFill) { $steps.Add('fill: Board-Fill -Auto fills what is still empty (Status, Size, Type, assignee)') }
    [pscustomobject]@{ Chosen = $chosen; New = $new; Steps = $steps.ToArray() }
}

# Execute the steps Get-ScanApplySteps lists. Every GitHub call goes through Invoke-Gh and every
# suite script through Invoke-SuiteScript, so the whole sequence is testable with both mocked.
#   $Save - called with the plan after every issue is created: a rerun never duplicates one.
function Invoke-ScanApply {
    param($Plan, $Steps, [string]$Repo, [string]$Owner, [string]$Lang = 'en', [switch]$BareBoard, [switch]$NoFill,
        [string]$TokenVar = 'GITHUB_TOKEN_PERSONAL', [scriptblock]$Save = { param($p) })
    $plan = $Plan
    $result = [ordered]@{ repo = $Repo; board = 0; created = @(); epic = 0; failed = @() }

    # 1. board
    $rbArgs = @{ Owner = $Owner; Repo = $Repo; Lang = $Lang }
    if ($BareBoard) { $rbArgs.SkipPreset = $true }
    $boardNum = [int]("$(Invoke-SuiteScript 'Resolve-Board.ps1' $rbArgs | Select-Object -Last 1)".Trim())
    $result.board = $boardNum
    $plan.board = $boardNum
    Write-Host "Board #$boardNum" -ForegroundColor Green

    # 2. labels
    Invoke-SuiteScript 'Apply-LabelPreset.ps1' @{ Repo = $Repo; TokenVar = $TokenVar } | Out-Null
    Invoke-Gh -GhArgs @('label', 'create', 'scan', '--repo', $Repo, '--color', 'BFD4F2', '--description', 'Harvested by /scan', '--force') -What 'create the scan label' | Out-Null

    # Board fields, read once.
    $project = Invoke-Gh -GhArgs @('project', 'view', "$boardNum", '--owner', $Owner, '--format', 'json') -What "read board #$boardNum" -Json
    $fields = @((Invoke-Gh -GhArgs @('project', 'field-list', "$boardNum", '--owner', $Owner, '--format', 'json', '--limit', '50') -What "read the fields of board #$boardNum" -Json).fields)
    function Get-OptionId([string[]]$FieldNames, [string]$Option) {
        $f = $fields | Where-Object { $FieldNames -contains $_.name } | Select-Object -First 1
        if (-not $f) { return $null }
        $o = @($f.options) | Where-Object { $_.name -eq $Option } | Select-Object -First 1
        if ($o) { [pscustomobject]@{ Field = $f.id; Option = $o.id } }
    }
    function Set-ItemOption([string]$ItemId, $Pair) {
        if (-not $Pair) { return }
        Invoke-Gh -GhArgs @('project', 'item-edit', '--id', $ItemId, '--project-id', $project.id, '--field-id', $Pair.Field, '--single-select-option-id', $Pair.Option) -What 'set a board field' -Retries 3 | Out-Null
    }
    function Add-ToBoard([string]$Url) {
        (Invoke-Gh -GhArgs @('project', 'item-add', "$boardNum", '--owner', $Owner, '--url', $Url, '--format', 'json') -What 'add the issue to the board' -Json).id
    }
    function Get-IssueRestId([int]$n) { "$(Invoke-Gh -GhArgs @('api', "repos/$Repo/issues/$n", '--jq', '.id') -What "read issue #$n")".Trim() }
    function Add-SubIssue([int]$Parent, [int]$Child) {
        Invoke-Gh -GhArgs @('api', '-X', 'POST', "repos/$Repo/issues/$Parent/sub_issues", '-F', "sub_issue_id=$(Get-IssueRestId $Child)") -What "attach #$Child to #$Parent" | Out-Null
    }

    # 3. issues
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "abios-scan-$PID.md"
    try {
        foreach ($it in ($Steps.New | Sort-Object Row)) {
            try {
                $labels = @('scan', $it.Type) + $(if (@($it.DependsOn).Count) { 'blocked' }) + $(if ($it.Kind -eq 'plan') { 'plan' }) | Where-Object { $_ }
                Set-Content -LiteralPath $tmp -Value (New-ScanIssueBody $it) -Encoding utf8
                $url = "$(Invoke-Gh -GhArgs @('issue', 'create', '--repo', $Repo, '--title', $it.Title, '--body-file', $tmp, '--label', ($labels -join ',')) -What "create row $($it.Row)")".Trim()
                $it.Issue = [int]($url -replace '^.*/', '')
                $itemId = Add-ToBoard $url
                Set-ItemOption $itemId (Get-OptionId @('Priority', 'Prioridad') $it.Priority)
                if (@($it.DependsOn).Count) { Set-ItemOption $itemId (Get-OptionId @('Status', 'Estado') 'Blocked') }
                if ($it.Type -eq 'spike') { Set-ItemOption $itemId (Get-OptionId @('Task Type', 'Type', 'Tipo') 'Spike') }
                $result.created += $it.Issue
                Write-Host "  #$($it.Issue) $($it.Title)" -ForegroundColor Green
            } catch {
                $result.failed += "row $($it.Row): $($_.Exception.Message)"
                Write-Host "  row $($it.Row) FAILED: $($_.Exception.Message)" -ForegroundColor Red
            } finally {
                & $Save $plan   # record every issue as soon as it exists: a rerun never duplicates it
            }
        }

        # 4. plan epic + sub-issues
        $chosen = @($Steps.Chosen | Where-Object { $_.Issue })
        if ($chosen.Count) {
            if (-not $plan.epic) {
                $title = "plan: work found by /scan ($((Get-Date).ToString('yyyy-MM-dd')))"
                Set-Content -LiteralPath $tmp -Value (New-ScanEpicBody -Items $chosen -Batches @($Plan.batches)) -Encoding utf8
                $url = "$(Invoke-Gh -GhArgs @('issue', 'create', '--repo', $Repo, '--title', $title, '--body-file', $tmp, '--label', 'plan') -What 'create the plan epic')".Trim()
                $plan.epic = [int]($url -replace '^.*/', '')
                $epicItem = Add-ToBoard $url
                Set-ItemOption $epicItem (Get-OptionId @('Priority', 'Prioridad') ($chosen.Priority | Sort-Object | Select-Object -First 1))
                & $Save $plan
            } else {
                Set-Content -LiteralPath $tmp -Value (New-ScanEpicBody -Items @($Plan.items | Where-Object { $_.Issue }) -Batches @($Plan.batches)) -Encoding utf8
                Invoke-Gh -GhArgs @('issue', 'edit', "$($plan.epic)", '--repo', $Repo, '--body-file', $tmp) -What 'update the plan epic' | Out-Null
            }
            $result.epic = [int]$plan.epic
            foreach ($it in ($Steps.New | Where-Object { $_.Issue })) {
                try { Add-SubIssue -Parent ([int]$plan.epic) -Child $it.Issue }
                catch { $result.failed += "sub-issue #$($it.Issue): $($_.Exception.Message)" }
            }
            Write-Host "Plan epic #$($plan.epic)" -ForegroundColor Green
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # 5. fill
    if (-not $NoFill) {
        Invoke-SuiteScript 'Board-Fill.ps1' @{ Owner = $Owner; Repo = $Repo; ProjectNum = $boardNum; Auto = $true; TokenVar = $TokenVar }
    }

    [pscustomobject]$result
}

# One seam for the suite scripts this verb chains (board, labels, fill).
function Invoke-SuiteScript([string]$Name, [hashtable]$Arguments) {
    & (Join-Path $PSScriptRoot $Name) @Arguments
}

if ($env:ABIOS_SCAN_DOTSOURCE) { return }

# ------------------------------------------------------------- live (side-effecting)

. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

if (-not $Root) { $Root = (git rev-parse --show-toplevel 2>$null) }
if (-not $Root) { throw 'Not inside a git repository: /scan works on the current repo.' }
$Root = (Resolve-Path $Root).Path
if (-not $env:GH_TOKEN) {
    $t = [Environment]::GetEnvironmentVariable($TokenVar, 'User')
    if ($t) { $env:GH_TOKEN = $t }
}
if (-not $Repo) {
    try { $Repo = "$(Invoke-Gh -GhArgs @('repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner') -What 'read the current repo')".Trim() } catch { $Repo = '' }
}
if (-not $Owner -and $Repo) { $Owner = $Repo.Split('/')[0] }
if (-not $PlanFile) {
    $state = Get-AbiosStateDir -Root $Root
    $PlanFile = Join-Path $state 'scan-plan.json'
}

function Invoke-Scan {
    $exclude = @(':(exclude,glob)**/node_modules/**', ':(exclude,glob)**/dist/**', ':(exclude,glob)**/build/**',
        ':(exclude,glob)**/vendor/**', ':(exclude,glob)**/skills/**', ':(exclude,glob)**/agents/**',
        ':(exclude,glob)**/.specify/**', ':(exclude,glob)**/.github/ISSUE_TEMPLATE/**',
        ':(exclude,glob)**/PULL_REQUEST_TEMPLATE*',
        ':(exclude,glob)**/templates/**', ':(exclude,glob)**/.agentic-board/**', ':(exclude,glob)**/CHANGELOG.md',
        ':(exclude,glob)**/*.min.js', ':(exclude,glob)**/package-lock.json')
    $items = [System.Collections.Generic.List[object]]::new()
    $grep = @(git -C $Root grep -n -I -E -e 'TODO|FIXME|HACK|XXX|BUG' -- . @exclude 2>$null)
    foreach ($i in @(ConvertFrom-MarkerGrep $grep)) { if ($i) { $items.Add($i) } }

    $planGlobs = @(':(glob)docs/**/plans/**/*.md', ':(glob)specs/**/*.md', ':(glob).claude/plans/**/*.md')
    $plans = @(git -C $Root ls-files -- @planGlobs 2>$null)
    $mdFiles = @(git -C $Root ls-files -- '*.md' @exclude 2>$null)
    foreach ($f in $mdFiles) {
        $full = Join-Path $Root $f
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $content = @(Get-Content -LiteralPath $full -Encoding utf8)
        foreach ($i in @(ConvertFrom-MarkdownScan -Path $f -Content $content -IsPlan:($plans -contains $f))) { if ($i) { $items.Add($i) } }
    }
    @(Select-UniqueScanItem $items.ToArray())
}

function Get-OpenIssues {
    if (-not $Repo) { return $null }
    try {
        @(Invoke-Gh -GhArgs @('issue', 'list', '--repo', $Repo, '--state', 'open', '--limit', '1000', '--json', 'number,title,body') -What 'list open issues' -Json)
    } catch { $null }
}

function Write-ScanPlan($Plan) {
    $dir = Split-Path $PlanFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PlanFile -Encoding utf8
}

function Show-ScanPlan($Plan) {
    $items = @($Plan.items)
    $open = @($items | Where-Object { -not $_.Tracked })
    Write-Host ""
    Write-Host "/scan - $($Plan.repo) - $($open.Count) untracked item(s), $(@($items).Count - $open.Count) already tracked" -ForegroundColor Cyan
    if (-not $Plan.dedupeChecked) { Write-Host "  Could not read the open issues: duplicates were NOT checked." -ForegroundColor Yellow }
    Write-Host ""
    foreach ($it in $open) {
        $flag = if ($it.Issue) { " (created: #$($it.Issue))" } elseif (@($it.DependsOn).Count) { " (blocked by $((@($it.DependsOn) | ForEach-Object { "#$_" }) -join ', '))" } else { '' }
        Write-Host ("  {0,3}. [{1}] {2,-8} {3}{4}" -f $it.Row, $it.Priority, $it.Type, $it.Title, $flag)
        Write-Host ("       {0} - {1}" -f $it.Source, $it.PriorityReason) -ForegroundColor DarkGray
    }
    if (@($Plan.batches).Count) {
        Write-Host ""
        Write-Host "Proposed PRs:" -ForegroundColor Cyan
        foreach ($b in $Plan.batches) { Write-Host "  $($b.Title): rows $($b.Rows -join ', ')" }
    }
    $tracked = @($items | Where-Object { $_.Tracked })
    if ($tracked.Count) {
        Write-Host ""
        Write-Host "Already tracked (skipped):" -ForegroundColor DarkGray
        foreach ($it in $tracked) { Write-Host "  - $($it.Title): $($it.Tracked)" -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-Host "Plan saved: $PlanFile"
    Write-Host "Apply all: Scan-Project.ps1 -Apply   |   some rows: -Apply -Rows 1,3,5   |   rehearse: -Apply -DryRun"
}

# ------------------------------------------------------------------------ PLAN
if (-not $Apply) {
    $previous = $null
    if (Test-Path -LiteralPath $PlanFile) { try { $previous = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json } catch { $previous = $null } }
    $items = @(Invoke-Scan)
    # An item created by an earlier apply keeps its issue number, so it is never created twice.
    if ($previous) {
        foreach ($it in $items) {
            $p = @($previous.items) | Where-Object { $_.Issue -and $_.Path -eq $it.Path -and (Get-NormalizedTitle $_.Title) -eq (Get-NormalizedTitle $it.Title) } | Select-Object -First 1
            if ($p) { $it.Issue = [int]$p.Issue }
        }
    }
    $open = Get-OpenIssues
    if ($null -ne $open) { $items = @(Set-ScanTracked -Items $items -OpenIssues $open) }
    $items = @(Set-ScanOrder $items)
    $batches = @(Get-ScanBatches -Items $items -Max $MaxBatch)
    $plan = [pscustomobject]@{
        repo = $Repo; root = $Root; createdAt = (Get-Date).ToUniversalTime().ToString('o')
        dedupeChecked = ($null -ne $open); items = $items; batches = $batches; board = 0; epic = 0
    }
    if ($previous -and $previous.board) { $plan.board = $previous.board }
    if ($previous -and $previous.epic) { $plan.epic = $previous.epic }
    Write-ScanPlan $plan
    if ($Json) { $plan | ConvertTo-Json -Depth 8; return }
    Show-ScanPlan $plan
    return
}

# ----------------------------------------------------------------------- APPLY
if (-not (Test-Path -LiteralPath $PlanFile)) { throw "No plan at $PlanFile. Run Scan-Project.ps1 first (it plans and writes nothing to GitHub)." }
if (-not $Repo) { throw 'Could not resolve the current repo (owner/name). Pass -Repo.' }
$plan = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json
if ($plan.repo -and $plan.repo -ne $Repo) { throw "The plan is for $($plan.repo), not $Repo. Run the plan again here." }
$items = @($plan.items)
$batches = @($plan.batches)
$steps = Get-ScanApplySteps -Items $items -Rows $Rows -BareBoard:$BareBoard -NoFill:$NoFill

if ($DryRun) {
    Write-Host "/scan apply - rehearsal, nothing is written ($Repo):" -ForegroundColor Cyan
    foreach ($s in $steps.Steps) { Write-Host "  - $s" }
    return
}
if (-not $steps.Chosen.Count) { Write-Host 'Nothing to apply: every chosen row is already tracked.'; return }

$result = Invoke-ScanApply -Plan $plan -Steps $steps -Repo $Repo -Owner $Owner -Lang $Lang -BareBoard:$BareBoard `
    -NoFill:$NoFill -TokenVar $TokenVar -Save { param($p) Write-ScanPlan $p }
$boardNum = $result.board
if ($Json) { [pscustomobject]$result | ConvertTo-Json -Depth 4; return }
Write-Host ""
Write-Host "Created $(@($result.created).Count) issue(s) on board #$boardNum; plan epic #$($result.epic)." -ForegroundColor Cyan
if (@($result.failed).Count) {
    Write-Host "Failed ($(@($result.failed).Count)):" -ForegroundColor Yellow
    foreach ($f in $result.failed) { Write-Host "  - $f" -ForegroundColor Yellow }
}
