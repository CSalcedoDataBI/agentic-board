<#
.SYNOPSIS
    /skills create and /skills improve (#739): the deterministic half of the skill pipeline - what to
    check before writing, where the skill belongs, and the gate it must pass before it is done.

.DESCRIPTION
    The pipeline chains tools that already exist; the agent does the writing, this script does the
    parts that must not depend on the agent's judgment.

      create:  toolkit -> overlap -> prior art -> scope -> author (skill-creator)
               -> pressure test (writing-skills) -> audit/improve loop (skills-audit, skill-improver)
               -> trigger eval -> done
      improve: toolkit -> audit -> improve loop (skill-improver) -> pressure test -> trigger eval -> done

    Modes:
      -Plan   (default) Read-only. Prints the stages with what this run found for each:
              * toolkit - are skill-creator, writing-skills and skill-improver installed
                (Get-SkillGaps -Profile quality). A missing one is named with /skills bootstrap.
              * overlap - installed skills whose name and description overlap the proposed one
                (shared content words, over Get-SkillInventory). A strong overlap means: improve that
                skill, do not create a near-duplicate.
              * prior art (create) - public repos for the topic (gh search repos), with stars,
                last push and license, so a good existing skill is installed instead of rewritten.
              * scope - where the skill belongs and why: this repo's .claude/skills when it is
                about this repo, ~/.claude/skills otherwise.
      -Verify Runs the static audit on the named skill and exits non-zero while a high or medium
              finding remains. It is the exit gate of the audit/improve loop.

.PARAMETER Mode
    create | improve.

.PARAMETER Name
    The skill name (kebab-case).

.PARAMETER Description
    create: the proposed description (the trigger text). improve: read from the skill.

.PARAMETER Topic
    create: search words for prior art. Default: the name with dashes as spaces.

.PARAMETER Scope
    auto (default) | personal | project.

.PARAMETER Verify
    Run the audit gate instead of planning.
#>
[CmdletBinding()]
param(
    [ValidateSet('create', 'improve')][string]$Mode = 'create',
    [string]$Name = "",
    [string]$Description = "",
    [string]$Topic = "",
    [ValidateSet('auto', 'personal', 'project')][string]$Scope = 'auto',
    [string]$Root = "",
    [switch]$Verify,
    [switch]$NoSearch,
    [double]$OverlapThreshold = 0.5,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ pure helpers

$script:StopWords = @('the', 'a', 'an', 'and', 'or', 'to', 'of', 'for', 'in', 'on', 'with', 'use', 'when', 'this',
    'that', 'it', 'is', 'are', 'be', 'by', 'from', 'as', 'at', 'any', 'user', 'asks', 'skill', 'skills', 'triggers',
    'de', 'la', 'el', 'en', 'y', 'o', 'que', 'para', 'con', 'los', 'las', 'un', 'una', 'del')

# The content words of a name + description. PURE.
function Get-SkillWords([string]$Text) {
    @(("$Text".ToLowerInvariant() -split '[^a-z0-9áéíóúñ]+') | Where-Object { $_.Length -ge 3 -and $script:StopWords -notcontains $_ } | Select-Object -Unique)
}

# Share of the SMALLER word set found in the other. Not Jaccard: an installed skill with a long
# description buried a real duplicate under its own length (humanizer scored 0.2 against
# "remove signs of AI writing from text" - measured).
function Get-WordOverlap([string[]]$A, [string[]]$B) {
    if (-not $A.Count -or -not $B.Count) { return 0.0 }
    $inter = @($A | Where-Object { $B -contains $_ }).Count
    [Math]::Round($inter / [Math]::Min($A.Count, $B.Count), 2)
}

# Installed skills that overlap the proposed one, strongest first. PURE.
#   $Installed - { name; scope; description; path }
function Get-SkillOverlap([string]$Name, [string]$Description, [object[]]$Installed, [double]$Threshold = 0.5) {
    $mine = Get-SkillWords "$($Name -replace '-', ' ') $Description"
    @(foreach ($s in $Installed) {
        if ($s.name -eq $Name) {
            [pscustomobject]@{ name = $s.name; scope = $s.scope; path = $s.path; score = 1.0; reason = 'same name' }
            continue
        }
        $score = Get-WordOverlap $mine (Get-SkillWords "$($s.name -replace '-', ' ') $($s.description)")
        if ($score -ge $Threshold) { [pscustomobject]@{ name = $s.name; scope = $s.scope; path = $s.path; score = $score; reason = 'shared wording' } }
    }) | Sort-Object score -Descending
}

# Where the skill belongs, and why. PURE.
#   $RepoName   - this repo's name ('' outside a repo)
#   $RepoPaths  - top-level folders/files of this repo; a description that names one is about the repo
function Get-SkillScopeAdvice([string]$Requested, [string]$Name, [string]$Description, [string]$RepoName, [string[]]$RepoPaths = @()) {
    $mk = { param($s, $why) [pscustomobject]@{ scope = $s; reason = $why } }
    if ($Requested -and $Requested -ne 'auto') { return (& $mk $Requested 'chosen by the user') }
    if (-not $RepoName) { return (& $mk 'personal' 'not inside a repository: a personal skill (~/.claude/skills)') }
    $text = "$Name $Description"
    if ($text -match "(?i)(?<![\w-])$([regex]::Escape($RepoName))(?![\w-])") { return (& $mk 'project' "it names this repo ($RepoName): it belongs in its .claude/skills") }
    foreach ($p in $RepoPaths) {
        if ($p.Length -ge 4 -and $text -match "(?i)(^|[\s``'/(])$([regex]::Escape($p))([\s``'/).,]|$)") {
            return (& $mk 'project' "it names '$p' in this repo: it belongs in its .claude/skills")
        }
    }
    (& $mk 'personal' 'nothing in it is specific to this repo: a personal skill (~/.claude/skills) works everywhere')
}

# The target folder for a scope. PURE.
function Get-SkillTargetDir([string]$Scope, [string]$Name, [string]$RepoRoot, [string]$ClaudeHome) {
    if ($Scope -eq 'project') { return (Join-Path $RepoRoot '.claude' 'skills' $Name) }
    Join-Path $ClaudeHome 'skills' $Name
}

# The audit gate: done only when no high or medium finding remains. PURE.
function Test-SkillAuditGate([object[]]$Findings) {
    $blocking = @($Findings | Where-Object { $_.severity -in @('high', 'med') })
    [pscustomobject]@{ Pass = ($blocking.Count -eq 0); Blocking = $blocking; Advisory = @($Findings | Where-Object { $_.severity -notin @('high', 'med') }) }
}

# The stages, each with the tool that runs it and when it is done. PURE.
function Get-SkillPipelineStages([string]$Mode, [string]$Name, [string]$Target) {
    $s = [System.Collections.Generic.List[object]]::new()
    $add = { param($n, $tool, $done) $s.Add([pscustomobject]@{ Stage = $n; Tool = $tool; Done = $done }) }
    & $add 'toolkit' 'Get-SkillGaps -Profile quality' 'skill-creator, writing-skills and skill-improver are installed'
    if ($Mode -eq 'create') {
        & $add 'overlap' 'Get-SkillInventory' 'no installed skill overlaps it strongly (else improve that one)'
        & $add 'prior-art' 'gh search repos' 'no public skill does the job (else install it with /skills bootstrap or Install-SkillFromRepo)'
        & $add 'scope' 'Get-SkillScopeAdvice' "the user agreed where it lives: $Target"
        & $add 'author' 'skill-creator' "SKILL.md written in $Target, third-person description with triggers"
        & $add 'pressure-test' 'writing-skills (RED/GREEN)' 'a baseline run WITHOUT the skill failed, and the same run WITH it passed'
    } else {
        & $add 'audit' "Invoke-SkillAudit -Name $Name" 'findings listed'
    }
    & $add 'improve-loop' "skill-improver, then Skill-Pipeline.ps1 -Verify -Name $Name" 'the audit gate passes: no high or medium finding'
    if ($Mode -eq 'improve') { & $add 'pressure-test' 'writing-skills (RED/GREEN)' 'the behavior the skill exists for still passes' }
    & $add 'trigger-eval' 'skills-audit runtime trigger-eval (3x enabled vs disabled)' 'it fires on its prompts and stays quiet on near-misses'
    $s.ToArray()
}

if ($env:ABIOS_SKILLPIPE_DOTSOURCE) { return }

# ------------------------------------------------------------- live (side-effecting)

. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
if (-not $Name) { throw 'Pass -Name <kebab-case skill name>.' }
if (-not $Root) { $Root = (git rev-parse --show-toplevel 2>$null) }
$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }

function Get-InventorySkills {
    $inv = pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-SkillInventory.ps1') -Json -Root $(if ($Root) { $Root } else { (Get-Location).Path }) 2>$null | Out-String
    try { @(($inv | ConvertFrom-Json).skills) } catch { @() }
}

# ----------------------------------------------------------------------- VERIFY
if ($Verify) {
    $auditArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-SkillAudit.ps1'), '-Json', '-Name', $Name)
    if ($Root) { $auditArgs += @('-Root', $Root) }
    $raw = pwsh @auditArgs 2>$null | Out-String
    $audit = try { $raw | ConvertFrom-Json } catch { $null }
    if (-not $audit) { throw "The audit returned nothing readable for '$Name'. Is the skill installed where the inventory looks?" }
    if (-not $audit.summary.skillsAudited) { throw "No skill named '$Name' was found to audit." }
    $gate = Test-SkillAuditGate @($audit.findings)
    if ($Json) { $gate | ConvertTo-Json -Depth 5 }
    else {
        Write-Host "Audit gate for '$Name': $(if ($gate.Pass) { 'PASS' } else { 'NOT YET' })" -ForegroundColor $(if ($gate.Pass) { 'Green' } else { 'Yellow' })
        foreach ($f in $gate.Blocking) { Write-Host "  [$($f.severity)] $($f.type): $($f.detail)" -ForegroundColor Yellow }
        foreach ($f in $gate.Advisory) { Write-Host "  [$($f.severity)] $($f.type): $($f.detail)" -ForegroundColor DarkGray }
    }
    if (-not $gate.Pass) { exit 1 }
    return
}

# ------------------------------------------------------------------------- PLAN
$installed = Get-InventorySkills
if ($Mode -eq 'improve' -and -not $Description) {
    $me = $installed | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $me) { throw "No installed skill named '$Name' to improve." }
    $Description = $me.description
}

$gaps = try { pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-SkillGaps.ps1') -Profile quality -Json 2>$null | Out-String | ConvertFrom-Json } catch { $null }
$toolkit = [pscustomobject]@{
    installed = @($gaps.installed.name); missing = @($gaps.gaps.name)
    ok = ($gaps -and -not @($gaps.gaps).Count)
}

$overlap = if ($Mode -eq 'create') { @(Get-SkillOverlap -Name $Name -Description $Description -Installed $installed -Threshold $OverlapThreshold | Select-Object -First 5) } else { @() }

$priorArt = @()
if ($Mode -eq 'create' -and -not $NoSearch) {
    $q = if ($Topic) { $Topic } else { ($Name -replace '-', ' ') }
    try {
        # gh search ANDs every word: try the specific query, then the topic alone.
        foreach ($query in @("$q claude skill", "$q skill", $q)) {
            $priorArt = @(Invoke-Gh -GhArgs @('search', 'repos', $query, '--sort', 'stars', '--limit', '8', '--json', 'fullName,stargazersCount,pushedAt,description,license') -What 'search prior art' -Json | Where-Object { $_ })
            if ($priorArt.Count) { break }
        }
    } catch { $priorArt = @([pscustomobject]@{ fullName = ''; description = "search failed: $($_.Exception.Message)" }) }
}

$repoName = if ($Root) { Split-Path $Root -Leaf } else { '' }
$repoPaths = if ($Root) { @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' } | ForEach-Object Name) } else { @() }
$scopeAdvice = if ($Mode -eq 'improve') {
    $me = $installed | Where-Object name -eq $Name | Select-Object -First 1
    [pscustomobject]@{ scope = $me.scope; reason = "it already lives there ($($me.path))" }
} else { Get-SkillScopeAdvice -Requested $Scope -Name $Name -Description $Description -RepoName $repoName -RepoPaths $repoPaths }
$target = if ($Mode -eq 'improve') { Split-Path ($installed | Where-Object name -eq $Name | Select-Object -First 1).path -Parent }
          else { Get-SkillTargetDir -Scope $scopeAdvice.scope -Name $Name -RepoRoot $Root -ClaudeHome $claudeHome }

$result = [pscustomobject]@{
    mode = $Mode; name = $Name; description = $Description
    toolkit = $toolkit; overlap = $overlap; priorArt = $priorArt
    scope = $scopeAdvice; target = $target
    stages = @(Get-SkillPipelineStages -Mode $Mode -Name $Name -Target $target)
}
if ($Json) { $result | ConvertTo-Json -Depth 6; return }

Write-Host ""
Write-Host "/skills $Mode $Name" -ForegroundColor Cyan
Write-Host "  toolkit:   $(if ($toolkit.ok) { 'ready' } else { "missing $($toolkit.missing -join ', ') - run /skills bootstrap quality" })"
if ($Mode -eq 'create') {
    if ($overlap.Count) {
        Write-Host "  overlap:   $($overlap.Count) installed skill(s) look similar - consider /skills improve instead:" -ForegroundColor Yellow
        foreach ($o in $overlap) { Write-Host "             $($o.name) ($($o.scope), $($o.score), $($o.reason))" }
    } else { Write-Host "  overlap:   none" }
    if ($priorArt.Count) {
        Write-Host "  prior art: $($priorArt.Count) public repo(s):"
        foreach ($p in $priorArt) { Write-Host "             $($p.fullName)  stars $($p.stargazersCount)  pushed $(if ($p.pushedAt -is [datetime]) { $p.pushedAt.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) } else { "$($p.pushedAt)" })  license $($p.license.key)" }
    } elseif (-not $NoSearch) { Write-Host "  prior art: none found" }
}
Write-Host "  scope:     $($scopeAdvice.scope) - $($scopeAdvice.reason)"
Write-Host "  target:    $target"
Write-Host ""
Write-Host "Stages:" -ForegroundColor Cyan
$i = 0
foreach ($st in $result.stages) { $i++; Write-Host ("  {0}. {1,-13} {2}" -f $i, $st.Stage, $st.Tool); Write-Host "     done when: $($st.Done)" -ForegroundColor DarkGray }
