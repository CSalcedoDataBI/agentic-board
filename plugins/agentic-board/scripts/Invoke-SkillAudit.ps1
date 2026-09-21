<#  Invoke-SkillAudit.ps1 — deterministic health audit over the skill inventory.

    Runs Get-SkillInventory and turns its lint / budget / overlap / misplaced signals
    into classified findings, each routed to its OWNING repo via Resolve-SkillOwner
    (so nothing is ever filed against the private project you are working in).

    This covers the STATIC signals. The runtime trigger-eval (run a realistic prompt
    with the skill enabled vs disabled via skillOverrides, 3x, score false +/-) is an
    agentic loop the SKILL.md drives — it cannot be a pure script. Findings from that
    loop use the same record shape and are appended by the agent.

    Read-only: emits findings; files nothing. The sanitized filing (references/filing.md)
    happens later, behind the human gate.

    EXAMPLES
      .\Invoke-SkillAudit.ps1 -Root . -Scope project
      .\Invoke-SkillAudit.ps1 -Name gh-account -Json
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [ValidateSet('all','plugin','personal','project')][string]$Scope = 'all',
    [string]$Name,
    [string]$CurrentRepo,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$engine   = Join-Path $here 'Get-SkillInventory.ps1'
$resolver = Join-Path $here 'Resolve-SkillOwner.ps1'

$inv = & $engine -Root $Root -Scope $Scope
$skills = $inv.skills
if ($Name) { $skills = $skills | Where-Object { $_.name -eq $Name -or $_.namespace -eq $Name } }

$findings = [System.Collections.Generic.List[object]]::new()

# Who owns a skill is resolved from its REAL plugin identity (the inventory reads the plugin's own
# manifest) and cached per distinct (scope, plugin, declared repo): the resolver may shell out.
# -PluginRepo is always passed (possibly empty) so the resolver runs in its fail-closed mode: a
# plugin that is not positively the tool's own is local-only, never filed.
$ownerCache = @{}
function Get-Owner {
    param($Skill)
    $k = "$($Skill.scope)|$($Skill.plugin)|$($Skill.pluginRepo)"
    if (-not $ownerCache.ContainsKey($k)) {
        $ownerCache[$k] = & $resolver -Scope $Skill.scope -Plugin $Skill.plugin -PluginRepo $Skill.pluginRepo -CurrentRepo $CurrentRepo
    }
    $ownerCache[$k]
}

# `Members` are the records one finding stands for (the copies folded into it); `copies` and `paths`
# say so on the finding itself (paths are LOCAL evidence: never paste them into a filed issue).
function Add-Finding {
    param($Skill, [string]$Severity, [string]$Type, [string]$Detail, $Members)
    $owner = Get-Owner $Skill
    $m = if ($Members) { @($Members) } else { @($Skill) }
    $findings.Add([pscustomobject]@{
        skill     = $Skill.namespace
        scope     = $Skill.scope
        severity  = $Severity
        type      = $Type
        detail    = $Detail
        ownerRepo = $owner.ownerRepo
        filing    = $owner.filing
        copies    = $m.Count
        paths     = @($m | ForEach-Object { $_.path })
    })
}

# Per-file lints (a defect of THIS file): each record keeps its own finding.
foreach ($s in $skills) {
    if (-not $s.hasName)                { Add-Finding $s 'high' 'missing-name'      'Frontmatter has no name field.' }
    if ($s.description -and $s.misplaced) { Add-Finding $s 'low' 'misplaced'        'SKILL.md lives outside .claude/skills — run skills-organize.' }
}

# Description lints (a defect of the WORDING): reported once per variant, i.e. per distinct skill.
# The same skill is normally visible through several copies (repo tree, worktrees, installed cache,
# marketplaces clone); one wording defect is one finding, not one per copy. A variant is folded
# only among copies with the same OWNER (repo + filing), so a fold never changes where a finding is
# routed, and a copy whose description differs is its own variant with its own findings.
$groups = [ordered]@{}
foreach ($s in $skills) {
    $o = Get-Owner $s
    # The lint outcome is part of the key: the variant compares descriptions with whitespace collapsed,
    # so two copies can differ in length (over-budget) or wording-lint result while sharing a variant;
    # a fold must never hide a finding the other copy would have produced.
    $sig = @($s.budget.overCap, $s.lint.thirdPerson, $s.lint.hasTriggers, $s.lint.hasWhenNotToUse, [bool]$s.description) -join ','
    $gk = "$($s.variantId)|$($o.ownerRepo)|$($o.filing)|$sig"
    if (-not $groups.Contains($gk)) { $groups[$gk] = [System.Collections.Generic.List[object]]::new() }
    $groups[$gk].Add($s)
}
$foldedFindings = 0
foreach ($g in $groups.Values) {
    $members = @($g | Sort-Object @{ e = { $_.copyRank } }, @{ e = { $_.path } })
    $s = $members[0]
    $before = $findings.Count
    if (-not $s.description) {
        Add-Finding $s 'high' 'empty-description' 'Description is empty — the skill cannot be routed to.' $members
    } else {
        if ($s.budget.overCap)             { Add-Finding $s 'med' 'over-budget'  "Description is $($s.descChars) chars (> 1536 cap) — it gets truncated." $members }
        if (-not $s.lint.thirdPerson)      { Add-Finding $s 'med' 'first-person' 'Description is first-person ("I can…"); use third person.' $members }
        if (-not $s.lint.hasTriggers)      { Add-Finding $s 'med' 'no-triggers'  'No concrete trigger terms / "Use when…" clause.' $members }
        if (-not $s.lint.hasWhenNotToUse)  { Add-Finding $s 'low' 'no-when-not'  'No "when NOT to use → see X" clause (disambiguation).' $members }
    }
    $foldedFindings += ($findings.Count - $before) * ($members.Count - 1)
}

# Overlaps are pairwise; attribute to the first member (both get flagged in report text).
# The inventory has already folded the copies of one skill (same name + description) into one, so a
# skill is no longer reported against itself; `aCopies`/`bCopies` say how many were folded, and
# summary.copiesCollapsed carries the total so nothing is dropped silently. The member is found by
# PATH (two copies of a name can share a namespace), falling back to the namespace.
function Get-CopiesNote {
    param($Count, [string]$Label)
    if ($Count -gt 1) { " ($Label has $Count copies with the same description, reported once)" } else { '' }
}
foreach ($o in $inv.overlaps) {
    $s = $skills | Where-Object { $_.path -eq $o.aPath } | Select-Object -First 1
    # -Name may have kept only ANOTHER copy of the skill: any copy folded into the first side counts,
    # and for a divergent pair (one skill, two wordings) a copy on the second side does too.
    if (-not $s) { $s = $skills | Where-Object { @($o.aPaths) -contains $_.path } | Select-Object -First 1 }
    if (-not $s -and $o.kind -eq 'divergent-copy') { $s = $skills | Where-Object { @($o.bPaths) -contains $_.path } | Select-Object -First 1 }
    if (-not $s) { continue }
    $note = (Get-CopiesNote $o.aCopies "'$($o.a)'") + (Get-CopiesNote $o.bCopies "'$($o.b)'")
    if ($o.kind -eq 'divergent-copy') {
        # Scopes, never paths: a finding may be filed later and must not carry local paths.
        $otherPath = if (@($o.bPaths) -contains $s.path) { $o.aPath } else { $o.bPath }
        $bScope = ($inv.skills | Where-Object { $_.path -eq $otherPath } | Select-Object -First 1).scope
        Add-Finding $s 'med' 'divergent-copy' "Two copies of '$($s.name)' carry different descriptions ($($s.scope) vs $bScope copy, Jaccard $($o.jaccard)) — one is stale; re-sync them.$note"
    } else {
        $mem = @($skills | Where-Object { @($o.aPaths) -contains $_.path })
        Add-Finding $s 'med' 'near-duplicate' "Description overlaps '$($o.b)' (Jaccard $($o.jaccard)) — add a disambiguation clause or merge.$note" $mem
    }
}

$order  = @{ high=0; med=1; low=2 }
$sorted = $findings | Sort-Object @{e={$order[$_.severity]}}, skill

$result = [pscustomobject]@{
    summary = [pscustomobject]@{
        skillsAudited = @($skills).Count
        # Copies of one skill folded before the overlap pass (whole inventory, not filtered by -Name).
        copiesCollapsed = $inv.summary.collapsedCopies
        # Description-lint findings NOT emitted because the same skill (same name, description and
        # owner) was already reported through another copy: findings + this = the per-copy count.
        perCopyFindingsFolded = $foldedFindings
        findings      = $sorted.Count
        high          = @($sorted | Where-Object severity -eq 'high').Count
        med           = @($sorted | Where-Object severity -eq 'med').Count
        low           = @($sorted | Where-Object severity -eq 'low').Count
        toFile        = @($sorted | Where-Object filing -eq 'file').Count
        localOnly     = @($sorted | Where-Object filing -eq 'local').Count
    }
    findings = $sorted
}

if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }
