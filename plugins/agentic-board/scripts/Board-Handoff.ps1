<#
.SYNOPSIS
    Write a verified session handoff (/board handoff save) so work can resume in a
    fresh session days later - even on another machine.

.DESCRIPTION
    The deterministic half of `/board handoff save`. The agent composes the curated,
    already-tagged narrative (next step / done / open threads / traps / key files);
    this script does the mechanical + verifiable parts:

      1. Autofills frontmatter from git + the active `.agentic-board/sessions.json`
         entry + `gh` (issue, repo, branch, pr, board, saved, host).
      2. Injects a "Verified git state" block gathered live this run (all [V]).
      3. Computes the verified ratio ([V] claims / total tagged claims).
      4. Assembles HANDOFF.md, writes it at the repo root, rotates the previous one to
         .handoffs/<yyyyMMddTHHmmssZ>-handoff.md, and keeps both gitignored.
      5. When the session is board-linked, upserts an `[abios-handoff]` comment on the
         linked issue (the durable, cross-machine source of truth). The local file is a
         fast mirror; the issue comment is what survives a clean checkout on machine B.

    See references/handoff.md for the full design (persistence model, [V]/[?] protocol).

    Dot-source guard: set $env:ABIOS_HANDOFF_DOTSOURCE=1 before dot-sourcing to load the
    pure helpers for Pester WITHOUT the token check or any gh/git side effect.

.PARAMETER Save
    The action switch (this script currently implements save; resume is #140).

.PARAMETER NextStep
    The single concrete next step. Should be [V]/[?]-tagged by the caller.

.PARAMETER Done
    Bullet lines of what was accomplished this session (each [V]/[?]-tagged).

.PARAMETER OpenThreads
    Bullet lines of decisions/threads still open.

.PARAMETER Traps
    Bullet lines of failed approaches / traps to NOT repeat.

.PARAMETER KeyFiles
    Relevant file paths for the next session.

.PARAMETER Issue
    Linked issue number. Default: matched from sessions.json by branch, else parsed
    from an `issue-<n>-...` branch name.

.PARAMETER Repo
    owner/name. Default: derived from origin.

.PARAMETER ProjectNum
    Board number (cosmetic in the frontmatter). Default: resolved best-effort.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default GITHUB_TOKEN_PERSONAL.

.PARAMETER NoMemo
    Skip the machine-local Claude Code auto-memory pointer that -Save otherwise drops
    (active-handoff.md + a MEMORY.md index line) so a fresh session surfaces the handoff.

.PARAMETER NoKnowledge
    Skip the capture-in-handoff step that -Save otherwise runs: proposing knowledge
    references touched this session (URLs in the narrative, doc-like key files) as
    `/knowledge add` suggestions, deduped against knowledge/registry.json. The anti-rot
    hook for the knowledge registry (never auto-adds — the user confirms each).

.PARAMETER Local
    Accept a machine-local, gitignored HANDOFF.md ON PURPOSE when no issue is linked.
    Without it, a -Save that resolves no issue REFUSES rather than silently degrading to a
    local-only file (which is not portable and gets no MEMORY.md pointer). Use -Issue <n> to
    link it instead, which is portable across machines and surfaces in the next session.

.PARAMETER BodyFile
    Path to a JSON file whose fields populate NextStep / Done / OpenThreads / Traps /
    KeyFiles. Agents should write the handoff body to a temp file rather than passing
    prose inline: inline text with slash-commands (/board, /scan, etc.) or path-like
    strings trips the tool-layer path guard and aborts the whole command before the
    script runs (#419). Format:
        { "NextStep": "...", "Done": ["..."], "OpenThreads": ["..."],
          "Traps": ["..."], "KeyFiles": ["..."] }
    Any section missing from the file is left as its inline default.
    When supplied, the corresponding inline params are ignored.

.PARAMETER DryRun
    Print the handoff and the intended comment action without writing or posting.

.EXAMPLE
    .\Board-Handoff.ps1 -Save -NextStep "[V] Implement -Resume" -Done "[V] wrote save" -Traps "[V] docs/ is gitignored"
#>
[CmdletBinding()]
param(
    [switch]  $Save,
    [switch]  $Resume,
    [string]  $NextStep = "",
    [string[]]$Done = @(),
    [string[]]$OpenThreads = @(),
    [string[]]$Traps = @(),
    [string[]]$KeyFiles = @(),
    [int]     $Issue = 0,
    [string]  $Repo = "",
    [string]  $Owner = "",
    [int]     $ProjectNum = 0,
    [string]  $TokenVar = "GITHUB_TOKEN_PERSONAL",
    [switch]  $NoMemo,
    [switch]  $NoKnowledge,
    # Accept a machine-local, gitignored HANDOFF.md ON PURPOSE when no issue is linked (#304).
    # Without it, a -Save that resolves no issue REFUSES rather than degrading silently.
    [switch]  $Local,
    [switch]  $DryRun,
    [string]  $BodyFile = ""
)

# ==============================================================================
# Pure helpers (unit-testable; no gh/git/network, no side effects)
# ==============================================================================

# The comment marker that identifies OUR handoff comment on the issue, so save can
# find-and-edit it instead of piling up new comments.
$script:HandoffMarker = "<!-- abios-handoff -->"

# Parse the issue number out of a work branch name: issue-<n>-slug -> <n>.
function Get-HandoffBranchIssue([string]$branch) {
    if ($branch -match '^issue-(\d+)') { return [int]$Matches[1] }
    return 0
}

# Colon-free basic-format ISO-8601 UTC stamp for archive filenames (':' is invalid
# on Windows). Takes a DateTime so tests are deterministic.
function New-HandoffArchiveName([datetime]$when) {
    return ($when.ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-handoff.md")
}

# RFC3339 UTC (always Z) for the frontmatter `saved` field.
function Get-HandoffStamp([datetime]$when) {
    return $when.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Count [V] verified vs [?] unverified claim tags and return "N/M" (verified / total
# tagged). Only LINE-LEADING tags count (a claim line starts with the tag, optionally
# after a "- " bullet / indentation) - so a [V] or [?] appearing mid-line, e.g. inside
# a gathered commit message, is NOT miscounted as a claim. "0/0" when nothing is tagged.
function Get-HandoffVerifiedRatio([string[]]$lines) {
    $text = ($lines -join "`n")
    $v = ([regex]::Matches($text, '(?m)^\s*(?:-\s*)?\[V\]')).Count
    $q = ([regex]::Matches($text, '(?m)^\s*(?:-\s*)?\[\?\]')).Count
    return "$v/$($v + $q)"
}

# Serialize an ordered frontmatter hashtable to a YAML block (--- ... ---).
function ConvertTo-HandoffFrontmatter([System.Collections.Specialized.OrderedDictionary]$fields) {
    $lines = @("---")
    foreach ($k in $fields.Keys) {
        $val = $fields[$k]
        if ($null -eq $val -or "$val" -eq "") { $val = "null" }
        $lines += "${k}: $val"
    }
    $lines += "---"
    return ($lines -join "`n")
}

# Assemble the full HANDOFF.md markdown from the frontmatter + gathered git block +
# the caller's curated sections. Sections with no content are omitted.
function Format-HandoffMarkdown {
    param(
        [string]  $Frontmatter,
        [string]  $Heading,
        [string]  $GitBlock,
        [string]  $NextStep,
        [string[]]$Done,
        [string[]]$OpenThreads,
        [string[]]$Traps,
        [string[]]$KeyFiles
    )
    $out = @($Frontmatter, "", "# $Heading", "")
    if ($NextStep) { $out += @("## Next concrete step", $NextStep, "") }
    if ($GitBlock) { $out += @("## Verified git state", $GitBlock, "") }
    $sections = [ordered]@{
        "Done this session"            = $Done
        "Open threads / decisions pending" = $OpenThreads
        "Traps / failed approaches (do NOT repeat)" = $Traps
        "Key files"                    = $KeyFiles
    }
    foreach ($title in $sections.Keys) {
        $items = @($sections[$title] | Where-Object { $_ -and "$_".Trim() -ne "" })
        if ($items.Count) {
            $out += "## $title"
            $out += ($items | ForEach-Object { if ($_ -match '^\s*-') { $_ } else { "- $_" } })
            $out += ""
        }
    }
    return (($out -join "`n").TrimEnd() + "`n")
}

# Idempotently ensure the given patterns are present in a .gitignore body. Returns
# the (possibly unchanged) full body.
function Add-GitignoreEntries([string]$body, [string[]]$patterns) {
    $existing = @($body -split "`r?`n")
    $missing = @($patterns | Where-Object { $p = $_; -not ($existing | Where-Object { $_.Trim() -eq $p }) })
    if (-not $missing.Count) { return $body }
    $trimmed = $body.TrimEnd("`r", "`n")
    $block = ($missing -join "`n")
    if ($trimmed) { return "$trimmed`n$block`n" }
    return "$block`n"
}

# -- Resume-side pure helpers (parse a handoff back out) ------------------------

# Extract the HANDOFF.md content from an issue comment body: the text between the
# ```md opening fence and its closing ``` fence. Returns "" when there is no fence.
function Get-HandoffBodyFromComment([string]$commentBody) {
    $lines = @($commentBody -split "`r?`n")
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0) {
            if ($lines[$i].Trim() -eq '```md') { $start = $i + 1 }
        } elseif ($lines[$i].Trim() -eq '```') { $end = $i; break }
    }
    if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { return "" }
    return (($lines[$start..($end - 1)]) -join "`n")
}

# Read a single frontmatter field from a handoff markdown (the first `key: value`
# inside the leading --- ... --- block). Returns "" when absent.
function Get-HandoffFrontmatterField([string]$markdown, [string]$key) {
    $lines = @($markdown -split "`r?`n")
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return "" }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { break }
        if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*:\s*(.+?)\s*$") { return $Matches[1].Trim() }
    }
    return ""
}

# Return the bullet lines under a `## <title>` section (until the next `## ` or EOF).
# Used to carry unresolved traps forward into the resumed session.
function Get-HandoffSection([string]$markdown, [string]$title) {
    $lines = @($markdown -split "`r?`n")
    $out = @(); $inSection = $false
    foreach ($ln in $lines) {
        if ($ln -match '^\s*##\s+(.+?)\s*$') {
            $inSection = ($Matches[1].Trim() -eq $title.Trim())
            continue
        }
        if ($inSection -and $ln.Trim() -ne "") { $out += $ln }
    }
    return $out
}

# -- Capture-in-handoff helper (knowledge anti-rot) ----------------------------
# From the curated handoff material, propose knowledge references TOUCHED this
# session: http(s) URLs mentioned anywhere in the narrative, and key files that are
# doc-like (a .md or a folder) and exist on disk. Everything is deduped against the
# refs already in the registry ($KnownRefs). Pure + side-effect free: it only
# PROPOSES candidates (the skill asks the user which to add) — never invents or
# auto-adds, mirroring Invoke-KnowledgeHarvest and the "never invent references" rule.
# Local candidates come back as repo-relative forward-slash paths, matching what
# Add-KnowledgeRef stores, so a later add dedups cleanly.
function Get-HandoffKnowledgeCandidates {
    param(
        [string[]]$Narrative = @(),   # NextStep + Done + OpenThreads + Traps lines
        [string[]]$KeyFiles  = @(),
        [string]  $RepoRoot,
        [string[]]$KnownRefs = @()
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $KnownRefs) { [void]$seen.Add([string]$k) }
    $out = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($type, $ref)
        $ref = [string]$ref
        if ($ref -and $seen.Add($ref)) { $out.Add([pscustomobject]@{ type = $type; ref = $ref }) }
    }

    # URLs anywhere in the narrative (things fetched / referenced this session).
    $urlRx = [regex]'https?://[^\s)>\]]+'
    foreach ($ln in $Narrative) {
        foreach ($m in $urlRx.Matches([string]$ln)) {
            & $add 'url' ($m.Value.TrimEnd('.', ',', ';', ':', ')', ']'))
        }
    }

    # Doc-like key files that exist on disk -> repo-relative forward-slash refs.
    $rootFull = if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot)) { (Resolve-Path -LiteralPath $RepoRoot).Path } else { $RepoRoot }
    foreach ($kfRaw in $KeyFiles) {
        # Strip a leading bullet, surrounding backticks, and any trailing "(note)".
        $kf = ([string]$kfRaw).Trim() -replace '^\s*-\s*', '' -replace '\s*\(.*\)\s*$', ''
        $kf = $kf.Trim().Trim('`').Trim()
        if (-not $kf -or $kf -match '^https?://') { continue }
        $full = Join-Path $RepoRoot $kf
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $isFolder = Test-Path -LiteralPath $full -PathType Container
        if (-not $isFolder -and $kf -notmatch '\.md$') { continue }   # only docs/folders, not code
        $rel = [System.IO.Path]::GetRelativePath($rootFull, (Resolve-Path -LiteralPath $full).Path) -replace '\\', '/'
        & $add ($(if ($isFolder) { 'folder' } else { 'md' })) $rel
    }
    return @($out)
}

# -- Auto-memory pointer helpers (surface the handoff on the NEXT session) ------
# Claude Code auto-memory lives at ~/.claude/projects/<slug>/memory/, where <slug>
# is the session's working directory with every non-alphanumeric char replaced by
# '-'. Deriving the slug lets save drop a pointer that MEMORY.md auto-loads.
function Get-AutoMemorySlug([string]$path) {
    return ($path -replace '[^A-Za-z0-9]', '-')
}

# Upsert a single index line into a MEMORY.md body: drop any existing line
# containing $marker, then append $line. Idempotent, preserves other lines.
function Set-MemoryIndexLine([string]$body, [string]$marker, [string]$line) {
    $kept = @($body -split "`r?`n" | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    $joined = (($kept -join "`n").TrimEnd())
    return "$joined`n$line`n"
}

# Remove any index line containing $marker (used by resume to consume the pointer).
function Remove-MemoryIndexLine([string]$body, [string]$marker) {
    $kept = @($body -split "`r?`n" | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    return (($kept -join "`n").TrimEnd() + "`n")
}

# Read handoff body sections from a JSON file (see -BodyFile). Fields missing from the JSON are
# returned as defaults (empty string / empty array) so the caller can fall back to inline params.
# A file path that is set but does not exist throws rather than silently using empty sections.
# Pure (reads a file, but no gh/git/network): tested in Pester via a temp file. (#419)
function Read-HandoffBodyFile([string]$filePath) {
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Board-Handoff: -BodyFile '$filePath' does not exist."
    }
    $raw = Get-Content -LiteralPath $filePath -Raw
    $data = $raw | ConvertFrom-Json
    return [PSCustomObject]@{
        NextStep    = if ($null -ne $data.NextStep)    { [string]$data.NextStep }        else { "" }
        Done        = if ($null -ne $data.Done)        { [string[]]@($data.Done) }        else { @() }
        OpenThreads = if ($null -ne $data.OpenThreads) { [string[]]@($data.OpenThreads) } else { @() }
        Traps       = if ($null -ne $data.Traps)       { [string[]]@($data.Traps) }       else { @() }
        KeyFiles    = if ($null -ne $data.KeyFiles)    { [string[]]@($data.KeyFiles) }    else { @() }
    }
}

# Decide how a -Save resolves its durability target (#304). A handoff is only portable + memo-backed
# when an ISSUE carries it (the [abios-handoff] comment resume reads from any machine, plus the
# MEMORY.md pointer). With no issue, the old code silently wrote a gitignored local-only HANDOFF.md
# AND skipped the memo — a "saved OK" that was neither portable nor discoverable. This makes the
# decision explicit and testable:
#   'linked'  -> an issue is set: durable comment + memo.
#   'local'   -> no issue, but -Local was passed: a deliberate machine-local handoff.
#   'refuse'  -> no issue AND no -Local: do NOT write; the caller must link an issue or opt in.
# Pure.
function Get-HandoffSaveMode {
    param([int]$Issue, [switch]$Local)
    if ($Issue -gt 0) { return 'linked' }
    if ($Local)       { return 'local' }
    return 'refuse'
}

# ==============================================================================
# Main entry. Dot-source guard: the test harness sets ABIOS_HANDOFF_DOTSOURCE to
# load the helpers above without running any of the side-effecting code below.
# ==============================================================================
if ($env:ABIOS_HANDOFF_DOTSOURCE) { return }

$ErrorActionPreference = "Stop"

# Resolve file-backed body sections BEFORE any validation (#419: inline payloads with
# slash-commands or path-like strings trip the tool-layer path guard before the script runs).
if ($BodyFile) {
    $bd = Read-HandoffBodyFile $BodyFile
    if ($bd.NextStep -and -not $NextStep)    { $NextStep    = $bd.NextStep }
    if ($bd.Done.Count -gt 0)                { $Done        = $bd.Done }
    if ($bd.OpenThreads.Count -gt 0)         { $OpenThreads = $bd.OpenThreads }
    if ($bd.Traps.Count -gt 0)               { $Traps       = $bd.Traps }
    if ($bd.KeyFiles.Count -gt 0)            { $KeyFiles    = $bd.KeyFiles }
}

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
# gh must fail closed on the durable-comment upsert (#303/#316): a failed read of the existing
# comments would post a DUPLICATE, and a silent write failure would print "OK saved" for a handoff
# that never reached the issue. Resume/PR reads fail closed so a 401 does not fall back to a stale
# mirror unnoticed.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

if ($Save -and $Resume) { throw "Pass either -Save or -Resume, not both." }
if (-not ($Save -or $Resume)) { throw "Pass an action: -Save (snapshot) or -Resume (rehydrate)." }

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# -- Resolve repo / branch -----------------------------------------------------
if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "Could not derive the repo from origin - pass -Repo owner/name." }
if (-not $Owner) { $Owner = ($Repo -split "/")[0] }

$branch = (git branch --show-current 2>$null)
if (-not $branch) { $branch = "(detached)" }

# -- Session registry lookup (shared state dir next to the main clone) ----------
function Get-AbiosSessionsPath {
    $dir = Get-AbiosStateDir -NoCreate
    if (-not $dir) { return $null }
    return (Join-Path $dir "sessions.json")
}
$session = $null
$sp = Get-AbiosSessionsPath
if ($sp -and (Test-Path $sp)) {
    try {
        $entries = @(Get-Content $sp -Raw | ConvertFrom-Json)
        $session = @($entries | Where-Object { $_.branch -eq $branch }) | Select-Object -First 1
    } catch { $session = $null }
}

# -- Resolve the linked issue --------------------------------------------------
if ($Issue -le 0 -and $session) { $Issue = [int]$session.issue }
if ($Issue -le 0)               { $Issue = Get-HandoffBranchIssue $branch }

# How this save will be carried: linked (issue), local (deliberate -Local), or refuse (#304).
$saveMode = Get-HandoffSaveMode -Issue $Issue -Local:$Local

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { throw "Not inside a git working tree." }
$handoffPath = Join-Path $repoRoot "HANDOFF.md"
$archiveDir  = Join-Path $repoRoot ".handoffs"

# -- Auto-memory pointer (best-effort, machine-local) --------------------------
# Resolve the Claude Code auto-memory dir for THIS project. Returns $null when it
# does not exist - we only ever augment an existing memory dir, never create CC
# internals. The pointer makes a plain NEW session (not just a resume) surface the
# handoff via MEMORY.md, without the user remembering the command.
function Get-ProjectMemoryDir {
    if (-not $HOME) { return $null }
    $slug = Get-AutoMemorySlug $repoRoot
    # Nested Join-Path (no embedded slashes) keeps the path separator-correct on Windows.
    $dir  = Join-Path (Join-Path (Join-Path (Join-Path $HOME ".claude") "projects") $slug) "memory"
    if (Test-Path $dir) { return $dir }
    return $null
}
$script:MemoMarker = "(active-handoff.md)"
function Write-HandoffMemoPointer {
    param([int]$IssueNum, [string]$RepoName, [string]$BranchName, [string]$Saved, [string]$Next)
    $dir = Get-ProjectMemoryDir
    if (-not $dir) { return $false }
    $nextClean = (($Next -replace '^\s*\[[V?]\]\s*', '').Trim()).TrimEnd('.')
    if ($nextClean.Length -gt 140) { $nextClean = $nextClean.Substring(0, 137) + "..." }
    $memo = @"
---
name: active-handoff
description: A /board handoff is saved for issue #$IssueNum ($RepoName) - resume with Board-Handoff.ps1 -Resume.
metadata:
  type: project
---
Saved $Saved on branch ``$BranchName``. Resume with ``Board-Handoff.ps1 -Resume`` (reads the [abios-handoff] comment on $RepoName#$IssueNum). Next step: $nextClean. See [[session-handoff-plan]].
"@
    # Best-effort: an IO/permissions failure in the local memory dir must NOT abort
    # the handoff save (which is the real work), so swallow and report not-written.
    try {
        Set-Content -Path (Join-Path $dir "active-handoff.md") -Value $memo -Encoding UTF8
        $indexPath = Join-Path $dir "MEMORY.md"
        $idxBody = if (Test-Path $indexPath) { Get-Content $indexPath -Raw } else { "# Memory index`n" }
        $line = "- [Active handoff]($($script:MemoMarker.Trim('()'))) - resume issue #$IssueNum with ``Board-Handoff.ps1 -Resume``."
        Set-Content -Path $indexPath -Value (Set-MemoryIndexLine $idxBody $script:MemoMarker $line) -Encoding UTF8 -NoNewline
        return $true
    } catch { return $false }
}
function Clear-HandoffMemoPointer {
    $dir = Get-ProjectMemoryDir
    if (-not $dir) { return $false }
    # Best-effort cleanup: a readonly/permission error must NOT fail -Resume.
    try {
        $memoFile = Join-Path $dir "active-handoff.md"
        if (Test-Path $memoFile) { Remove-Item -Force $memoFile }
        $indexPath = Join-Path $dir "MEMORY.md"
        if (Test-Path $indexPath) {
            $idxBody = Get-Content $indexPath -Raw
            if ($idxBody -match [regex]::Escape($script:MemoMarker)) {
                Set-Content -Path $indexPath -Value (Remove-MemoryIndexLine $idxBody $script:MemoMarker) -Encoding UTF8 -NoNewline
                return $true
            }
        }
    } catch { return $false }
    return $false
}

# ==============================================================================
# RESUME - read the latest handoff back, regenerate the local mirror, re-verify
# the [V] anchors, surface unresolved traps, and offer to continue.
# ==============================================================================
if ($Resume) {
    Write-Host "=== /board handoff resume  ($Repo)  branch $branch ===" -ForegroundColor Cyan
    Write-Host ""

    # Source of truth = the [abios-handoff] comment on the linked issue (cross-machine).
    $body = ""; $source = ""
    if ($Issue -gt 0) {
        try {
            $comments = Invoke-Gh -GhArgs @('api','--paginate',"repos/$Repo/issues/$Issue/comments?per_page=100") `
                                  -What "leer el handoff de $Repo#$Issue" -Json
            $marker = @($comments | Where-Object { $_.body -like "*$script:HandoffMarker*" }) | Select-Object -Last 1
            if ($marker) {
                $body = Get-HandoffBodyFromComment $marker.body
                if ($body) { $source = "issue comment on $Repo#$Issue" }
            }
        } catch {
            # Do NOT let a 401 silently fall back to a possibly-older local mirror as if the remote
            # had no handoff - say so, then fall back (#316).
            Write-Host "  WARN could not read $Repo#$Issue ($($_.Exception.Message)) - falling back to the local mirror, which may be older." -ForegroundColor DarkYellow
        }
    }
    # Fallback: the local mirror (offline / no linked issue).
    if (-not $body -and (Test-Path $handoffPath)) {
        $body = Get-Content $handoffPath -Raw
        $source = "local HANDOFF.md"
    }
    if (-not $body) {
        throw "No handoff found$(if ($Issue -gt 0) { " for $Repo#$Issue" }) - no [abios-handoff] comment and no local HANDOFF.md."
    }

    # Regenerate the local mirror when the source was the remote comment (machine B).
    if ($source -ne "local HANDOFF.md") {
        if ($DryRun) {
            Write-Host "DRY-RUN - would regenerate local HANDOFF.md from the $source." -ForegroundColor Yellow
        } else {
            Set-Content -Path $handoffPath -Value $body -Encoding UTF8 -NoNewline
            $gitignorePath = Join-Path $repoRoot ".gitignore"
            $giBody = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }
            $giNew  = Add-GitignoreEntries $giBody @("/HANDOFF.md", "/.handoffs/")
            if ($giNew -ne $giBody) { Set-Content -Path $gitignorePath -Value $giNew -Encoding UTF8 -NoNewline }
            Write-Host "  OK  Local HANDOFF.md regenerated from the $source" -ForegroundColor DarkGray
        }
    }

    Write-Host "  Source : $source" -ForegroundColor DarkCyan
    $savedAt = Get-HandoffFrontmatterField $body "saved"
    $verOf   = Get-HandoffFrontmatterField $body "verified"
    if ($savedAt) { Write-Host "  Saved  : $savedAt  (verified $verOf)" -ForegroundColor DarkCyan }
    Write-Host ""
    Write-Host $body
    Write-Host ""

    # Re-verify the [V] anchors (branch + PR) still hold; report drift.
    $drift = @()
    $hoBranch = Get-HandoffFrontmatterField $body "branch"
    if ($hoBranch -and $hoBranch -ne "null") {
        git rev-parse --verify --quiet "refs/heads/$hoBranch" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $drift += "branch '$hoBranch' no longer exists locally (deleted after merge, or needs a fetch)."
        } elseif ($branch -ne $hoBranch) {
            $drift += "you are on '$branch'; the handoff was saved on '$hoBranch' (git checkout $hoBranch to continue there)."
        }
    }
    $hoPr = Get-HandoffFrontmatterField $body "pr"
    if ($hoPr -and $hoPr -ne "null") {
        try {
            $prState = (gh pr view $hoPr --repo $Repo --json state 2>$null | ConvertFrom-Json).state
            if ($prState -and $prState -ne "OPEN") { $drift += "PR #$hoPr is now $prState (the work may already be merged/closed)." }
        } catch { }
    }
    if ($drift.Count) {
        Write-Host "  DRIFT since the handoff was saved:" -ForegroundColor Yellow
        $drift | ForEach-Object { Write-Host "    ! $_" -ForegroundColor Yellow }
        Write-Host ""
    }

    # Carry unresolved traps forward, front and center.
    $traps = Get-HandoffSection $body "Traps / failed approaches (do NOT repeat)"
    if ($traps.Count) {
        Write-Host "  CARRY FORWARD - traps to NOT repeat:" -ForegroundColor Magenta
        $traps | ForEach-Object { Write-Host "    $_" -ForegroundColor Magenta }
        Write-Host ""
    }

    # Consume the auto-memory pointer - it has served its purpose now that the
    # handoff is rehydrated (save re-creates it on the next snapshot).
    if (-not $DryRun) {
        if (Clear-HandoffMemoPointer) { Write-Host "  OK  Cleared the MEMORY.md handoff pointer (consumed)" -ForegroundColor DarkGray; Write-Host "" }
    }

    if ($Issue -gt 0) {
        Write-Host "Continue this work with:  /board work  then start #$Issue  (Board-Work.ps1 -Start $Issue)" -ForegroundColor Cyan
        if ($hoBranch -and $hoBranch -ne "null") {
            Write-Host "                          or resume its branch:  git checkout $hoBranch" -ForegroundColor Cyan
        }
    }
    return
}

# -- Resolve the open PR for this branch (repo-consistent form) -----------------
$pr = $null
try {
    # -Json throws on a real failure so a false-empty read does not write `pr: null` into the
    # handoff frontmatter when an open PR actually exists (a genuinely PR-less branch returns []).
    $prJson = Invoke-Gh -GhArgs @('pr','list','--repo',$Repo,'--head',$branch,'--state','open','--json','number') `
                        -What "buscar el PR abierto de $branch" -Json
    if ($prJson -and $prJson.Count) { $pr = [int]$prJson[0].number }
} catch {
    Write-Host "  WARN could not resolve the open PR for $branch ($($_.Exception.Message)) - the handoff will omit it." -ForegroundColor DarkYellow
}

# -- Resolve the board number (best-effort, cosmetic) --------------------------
if ($ProjectNum -le 0) {
    try {
        $resolved = & (Join-Path $PSScriptRoot "Resolve-Board.ps1") -Owner $Owner -Repo $Repo -CreateIfMissing:$false 2>$null
        if ($resolved) { $ProjectNum = [int]($resolved | Select-Object -Last 1) }
    } catch { $ProjectNum = 0 }
}

# -- Live-verified git state (every line here is genuinely [V]) -----------------
$gitStatus = @(git status --porcelain 2>$null)
$dirty     = if ($gitStatus.Count) { "$($gitStatus.Count) uncommitted change(s)" } else { "clean" }
$lastLog   = @(git log --oneline -5 2>$null)
$gitBlockLines = @(
    "[V] Branch: $branch"
    "[V] Working tree: $dirty"
    "[V] Linked issue: $(if ($Issue -gt 0) { "#$Issue" } else { 'none' }) | Open PR: $(if ($pr) { "#$pr" } else { 'none' })"
    "[V] Recent commits:"
) + @($lastLog | ForEach-Object { "    - $_" })
$gitBlock = ($gitBlockLines -join "`n")

# -- Assemble frontmatter ------------------------------------------------------
$now = Get-Date
$allTagged = @($NextStep) + $Done + $OpenThreads + $Traps + $gitBlockLines
$fm = [ordered]@{
    issue    = $(if ($Issue -gt 0) { $Issue } else { "null" })
    repo     = $Repo
    branch   = $branch
    pr       = $(if ($pr) { $pr } else { "null" })
    board    = $(if ($ProjectNum -gt 0) { $ProjectNum } else { "null" })
    saved    = Get-HandoffStamp $now
    host     = $env:COMPUTERNAME
    verified = Get-HandoffVerifiedRatio $allTagged
}
$frontmatter = ConvertTo-HandoffFrontmatter $fm

$heading = if ($Issue -gt 0) { "Handoff - #$Issue" } else { "Handoff - $branch" }
$markdown = Format-HandoffMarkdown -Frontmatter $frontmatter -Heading $heading -GitBlock $gitBlock `
    -NextStep $NextStep -Done $Done -OpenThreads $OpenThreads -Traps $Traps -KeyFiles $KeyFiles

# ($repoRoot / $handoffPath / $archiveDir were resolved above, shared with resume.)
Write-Host "=== /board handoff save  ($Repo)  branch $branch ===" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "DRY-RUN - would write $handoffPath (verified $($fm.verified)):" -ForegroundColor Yellow
    Write-Host ""
    Write-Host $markdown
    Write-Host ""
    if ($saveMode -eq 'linked') {
        Write-Host "DRY-RUN - would upsert the [abios-handoff] comment on $Repo#$Issue." -ForegroundColor Yellow
    } elseif ($saveMode -eq 'local') {
        Write-Host "DRY-RUN - -Local: would write a machine-local HANDOFF.md ONLY. Not portable (it is gitignored)" -ForegroundColor Yellow
        Write-Host "          and NO MEMORY.md pointer is written, so the next session will not surface it." -ForegroundColor Yellow
    } else {
        Write-Host "DRY-RUN - REFUSING: no linked issue (no -Issue, no active session, not on an issue-<n> branch)." -ForegroundColor Red
        Write-Host "          A real save would write NOTHING. Link it with -Issue <n> (portable [abios-handoff]" -ForegroundColor DarkYellow
        Write-Host "          comment + MEMORY.md pointer), or accept a machine-local gitignored HANDOFF.md on" -ForegroundColor DarkYellow
        Write-Host "          purpose with -Local (no portability, no memo)." -ForegroundColor DarkYellow
    }
    if (-not $NoKnowledge) {
        try {
            $knownRefs = @()
            $regPath = Join-Path (Join-Path $repoRoot 'knowledge') 'registry.json'
            if (Test-Path -LiteralPath $regPath) {
                $knownRefs = @((Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json).references | ForEach-Object { [string]$_.ref })
            }
            $cands = Get-HandoffKnowledgeCandidates -Narrative (@($NextStep) + $Done + $OpenThreads + $Traps) -KeyFiles $KeyFiles -RepoRoot $repoRoot -KnownRefs $knownRefs
            if ($cands.Count) {
                Write-Host "DRY-RUN - would propose $($cands.Count) knowledge reference(s) to capture:" -ForegroundColor Yellow
                foreach ($c in $cands) { Write-Host "    [$($c.type)] $($c.ref)" -ForegroundColor DarkCyan }
            }
        } catch { }
    }
    return
}

# -- Refuse a silent local-only degrade (#304) ---------------------------------
# No issue resolved AND no explicit -Local: do NOT write. The old code degraded here to a
# gitignored HANDOFF.md and skipped the memo, then said so only AFTER writing — a "saved OK"
# that was neither portable nor discoverable. Fail loud, before touching disk, with the choice.
if ($saveMode -eq 'refuse') {
    Write-Host "  REFUSING to save: no linked issue resolved (no -Issue, no active session, not on an issue-<n> branch)." -ForegroundColor Red
    Write-Host "  A handoff is only portable + auto-surfaced when an ISSUE carries it: the durable [abios-handoff]" -ForegroundColor DarkYellow
    Write-Host "  comment that -Resume reads from any machine, plus a MEMORY.md pointer so your NEXT session finds" -ForegroundColor DarkYellow
    Write-Host "  it on its own. A local HANDOFF.md is gitignored and has NEITHER. Choose one:" -ForegroundColor DarkYellow
    Write-Host "    - link it:            Board-Handoff.ps1 -Save -Issue <n> ...   (the next pending is shown by /board work)" -ForegroundColor Cyan
    Write-Host "    - local on purpose:   add -Local   (accepts the gitignored, non-portable, no-memo handoff)" -ForegroundColor Cyan
    exit 1
}

# -- Rotate the previous handoff into .handoffs/ -------------------------------
if (Test-Path $handoffPath) {
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Force $archiveDir | Out-Null }
    $archiveName = New-HandoffArchiveName $now
    Move-Item -Force $handoffPath (Join-Path $archiveDir $archiveName)
    Write-Host "  OK  Previous handoff archived -> .handoffs/$archiveName" -ForegroundColor DarkGray
}

# -- Write the new HANDOFF.md --------------------------------------------------
Set-Content -Path $handoffPath -Value $markdown -Encoding UTF8 -NoNewline
Write-Host "  OK  HANDOFF.md written (verified $($fm.verified))" -ForegroundColor Green

# -- Keep the mirror + archive gitignored --------------------------------------
$gitignorePath = Join-Path $repoRoot ".gitignore"
$giBody = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }
$giNew  = Add-GitignoreEntries $giBody @("/HANDOFF.md", "/.handoffs/")
if ($giNew -ne $giBody) {
    Set-Content -Path $gitignorePath -Value $giNew -Encoding UTF8 -NoNewline
    Write-Host "  OK  .gitignore updated (HANDOFF.md, .handoffs/)" -ForegroundColor DarkGray
}

# -- Upsert the durable [abios-handoff] comment on the linked issue -------------
if ($Issue -gt 0) {
    # Build via a here-string with a fence VARIABLE (no fragile backtick escaping),
    # and carry both the hidden HTML marker (for exact find) and the visible
    # [abios-handoff] tag (matches the spec / aids discovery).
    $fence = '```'
    $commentBody = @"
$script:HandoffMarker
**[abios-handoff]** session handoff - upserted by /board handoff save.

${fence}md
$markdown
${fence}
_Last saved $($fm.saved)._
"@
    # --paginate so the marker is found even on issues with >100 comments (else a
    # missed marker would post a DUPLICATE instead of editing the existing one).
    # Read the existing comments to find the marker. A FAILED read must NOT read as "no marker
    # found" - that posts a DUPLICATE instead of editing. On a read failure, skip the post entirely
    # (the local HANDOFF.md is already written) rather than risk the duplicate (#316).
    $existingId = $null
    $canUpsert  = $true
    try {
        $comments = Invoke-Gh -GhArgs @('api','--paginate',"repos/$Repo/issues/$Issue/comments?per_page=100") `
                              -What "leer los comentarios de $Repo#$Issue" -Json
        $existingId = (@($comments | Where-Object { $_.body -like "*$script:HandoffMarker*" }) | Select-Object -Last 1).id
    } catch {
        $canUpsert = $false
        Write-Host "  WARN could not read existing comments ($($_.Exception.Message)) - NOT posting to avoid a duplicate. Local HANDOFF.md is saved." -ForegroundColor DarkYellow
    }

    if ($canUpsert) {
        try {
            if ($existingId) {
                # -StdIn feeds the body over gh's `-F body=@-` stdin; plain Invoke-Gh throws on a
                # non-zero exit so the catch actually fires (a bare native failure never threw -> the
                # old code printed "OK updated" for a PATCH that silently failed) (#316).
                $null = Invoke-Gh -GhArgs @('api','--method','PATCH',"repos/$Repo/issues/comments/$existingId",'-F','body=@-') `
                                  -StdIn $commentBody -What "actualizar el comentario de handoff en $Repo#$Issue"
                Write-Host "  OK  Handoff comment updated on $Repo#$Issue (durable source of truth)" -ForegroundColor Green
            } else {
                $null = Invoke-Gh -GhArgs @('issue','comment',"$Issue",'--repo',$Repo,'--body-file','-') `
                                  -StdIn $commentBody -What "postear el comentario de handoff en $Repo#$Issue"
                Write-Host "  OK  Handoff comment posted on $Repo#$Issue (durable source of truth)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  WARN could not upsert the issue comment ($($_.Exception.Message)) - the local HANDOFF.md is still written." -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
    Write-Host "Resume later with:  Board-Handoff.ps1 -Resume  (reads $Repo#$Issue - even on another machine)" -ForegroundColor Cyan
} else {
    # Reached only under -Local now (a no-issue save without -Local is refused before any write).
    Write-Host ""
    Write-Host "  -Local: wrote a machine-local HANDOFF.md only. It is gitignored and NOT portable -" -ForegroundColor DarkYellow
    Write-Host "  to use it on another machine copy it out, or force-commit it with 'git add -f HANDOFF.md'." -ForegroundColor DarkYellow
    Write-Host "  No MEMORY.md pointer was written (that needs a linked issue), so your next session will NOT" -ForegroundColor DarkYellow
    Write-Host "  surface it on its own - link an issue with -Issue <n> if you want that." -ForegroundColor DarkYellow
}

# -- Auto-memory pointer: make the NEXT session surface this handoff -----------
# Best-effort + opt-out. Only augments an EXISTING Claude Code memory dir for this
# project; silently does nothing otherwise. Resume consumes it.
if (-not $NoMemo -and $Issue -gt 0) {
    if (Write-HandoffMemoPointer -IssueNum $Issue -RepoName $Repo -BranchName $branch -Saved $fm.saved -Next $NextStep) {
        Write-Host "  OK  MEMORY.md pointer written - your next session in this repo will surface it" -ForegroundColor DarkGray
    }
}

# -- Capture-in-handoff: propose knowledge references touched this session ------
# The anti-rot hook for knowledge-ops (M5): surface URLs + doc-like key files from
# this handoff that are NOT yet in knowledge/registry.json, as ready-to-run
# `/knowledge add` suggestions. It only PROPOSES — the skill asks which to keep and
# the user confirms each (never auto-adds; "never invent references"). Best-effort:
# a missing/unreadable registry must never fail the handoff save.
if (-not $NoKnowledge) {
    try {
        $knownRefs = @()
        $regPath = Join-Path (Join-Path $repoRoot 'knowledge') 'registry.json'
        if (Test-Path -LiteralPath $regPath) {
            $knownRefs = @((Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json).references | ForEach-Object { [string]$_.ref })
        }
        $narrative = @($NextStep) + $Done + $OpenThreads + $Traps
        $cands = Get-HandoffKnowledgeCandidates -Narrative $narrative -KeyFiles $KeyFiles -RepoRoot $repoRoot -KnownRefs $knownRefs
        if ($cands.Count) {
            Write-Host ""
            Write-Host "  Knowledge references touched this session (not yet in the registry):" -ForegroundColor Cyan
            foreach ($c in $cands) {
                Write-Host "    [$($c.type)] $($c.ref)" -ForegroundColor DarkCyan
            }
            Write-Host "  Add the ones worth keeping (pick a domain each):" -ForegroundColor DarkGray
            Write-Host "    /knowledge add <ref> <Domain> `"<one-line note>`"" -ForegroundColor DarkGray
        }
    } catch {
        # Silently skip — the handoff save is the real work and must not fail here.
    }
}
