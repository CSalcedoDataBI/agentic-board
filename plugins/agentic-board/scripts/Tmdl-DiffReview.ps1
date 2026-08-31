<#
.SYNOPSIS
    TMDL diff review (M2.2): detect breaking semantic-model schema changes.

.DESCRIPTION
    PBIP repos store the semantic model as TMDL (*.tmdl) text files. When a PR
    edits those files, a reviewer cannot easily tell a cosmetic change (renamed
    display folder) from a BREAKING one (dropped column, changed data type,
    deleted measure) that breaks downstream reports, DAX, and refreshes.

    This script parses the *.tmdl before/after a change, classifies every schema
    change by severity, and prints a report:

      BREAKING - table/column/measure/hierarchy/relationship/role deleted;
                 column dataType or sourceColumn changed; column/measure renamed
      WARNING  - measure/partition expression changed; summarizeBy changed;
                 object hidden; relationship crossFilteringBehavior changed
      INFO     - any addition; formatString/displayFolder/description/lineageTag

    Two input modes share one parse+compare core:

      PR mode    (-Repo owner/name -PR <n>): reads the PR's changed *.tmdl via the
                 GitHub API, fetching base and head content by ref. No clone needed.
      Local mode (-Base <ref> -Head <ref>): diffs *.tmdl with git in the cwd.

    Warn-only by default (a breaking change is often intentional - dropping a
    deprecated column). Exit 0 unless -FailOnBreaking is set (M3.3 uses that to
    hard-block a merge).

    The comparison is PER FILE: only changed *.tmdl are compared. A cross-file
    effect (a relationship referencing a column dropped in another, unchanged
    file) is caught only if both files changed. This is an accepted v1 limit.

.PARAMETER Repo
    owner/name (PR mode). Derived from origin if omitted.

.PARAMETER PR
    Pull request number (PR mode).

.PARAMETER Base
    Base git ref (local mode), e.g. main or a SHA.

.PARAMETER Head
    Head git ref (local mode). Default: HEAD.

.PARAMETER FailOnBreaking
    Exit 1 when any BREAKING change is found. Default: warn only (exit 0).

.PARAMETER Json
    Emit the findings object as JSON to stdout instead of the colored report.

.PARAMETER TokenVar
    Windows USER env var holding the PAT (PR mode). Default GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Tmdl-DiffReview.ps1 -Repo CSalcedoDataBI/pbip-repo -PR 42
    .\Tmdl-DiffReview.ps1 -Base main -Head HEAD
    .\Tmdl-DiffReview.ps1 -Base main -Head HEAD -FailOnBreaking
#>
[CmdletBinding()]
param(
    [string]$Repo = "",
    [int]   $PR = 0,
    [string]$Base = "",
    [string]$Head = "HEAD",
    [switch]$FailOnBreaking,
    [switch]$Json,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# gh must fail closed on the diff reads (#303/#316): an empty read of the changed files or the
# base/head SHAs would make this report "no breaking changes" over a diff it never actually read -
# a false all-clear on a semantic-model review. (An added file legitimately 404s at base; that
# single case is special-cased below, not swallowed wholesale.)
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# ==============================================================================
# Helpers
# ==============================================================================

function Strip-Quotes([string]$s) {
    if ($null -eq $s) { return $s }
    $s = $s.Trim()
    if ($s -match "^'(.*)'$") { return $Matches[1] }
    return $s
}

function Norm-Expr([string]$s) {
    if ($null -eq $s) { return "" }
    return (($s -replace '`', '' -replace '\s+', ' ').Trim())
}

function Prop-Val($rec, [string]$k) {
    if ($rec.Props.ContainsKey($k)) { return [string]$rec.Props[$k] }
    return ""
}

# Parse one .tmdl file's content into a flat map: id -> record. A record is
# @{ Kind; Name; Parent; Props=@{}; Expr; Id }. Indentation-based; line-oriented.
function Parse-Tmdl {
    param([string]$Content)

    $model = @{}
    if ([string]::IsNullOrWhiteSpace($Content)) { return $model }

    $lines = $Content -split "`r?`n"
    $stack = New-Object System.Collections.Generic.List[object]

    foreach ($raw in $lines) {
        if ($raw -match '^\s*$')   { continue }   # blank
        if ($raw -match '^\s*//')  { continue }   # comment
        if ($raw -match '^\s*```') { continue }   # multiline expr fences

        $indent = ($raw.Length - $raw.TrimStart().Length)
        $trim   = $raw.Trim()

        # Close every frame that is a sibling or deeper than this line.
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }

        # Nearest enclosing table (parent for columns/measures/etc).
        $parentTable = $null
        foreach ($f in $stack) { if ($f.Kind -eq 'table') { $parentTable = $f.Name } }
        $top = if ($stack.Count -gt 0) { $stack[$stack.Count - 1] } else { $null }

        # --- object declaration ---------------------------------------------
        if ($trim -match '^(table|column|measure|hierarchy|partition|relationship|role)\s+(.+)$') {
            $kw   = $Matches[1]
            $rest = $Matches[2].Trim()
            $expr = $null
            $name = $rest
            if ($kw -eq 'measure' -or $kw -eq 'partition') {
                if ($rest -match '^(.+?)\s*=\s*(.*)$') {
                    $name = $Matches[1].Trim()
                    $expr = $Matches[2].Trim()
                    if ($expr -eq '') { $expr = $null }
                }
            }
            $name = Strip-Quotes $name
            switch ($kw) {
                'table'        { $id = "table|$name";                  $pt = $null }
                'column'       { $id = "column|$parentTable|$name";    $pt = $parentTable }
                'measure'      { $id = "measure|$parentTable|$name";   $pt = $parentTable }
                'hierarchy'    { $id = "hierarchy|$parentTable|$name"; $pt = $parentTable }
                'partition'    { $id = "partition|$parentTable|$name"; $pt = $parentTable }
                'relationship' { $id = "relationship|$name";           $pt = $null }
                'role'         { $id = "role|$name";                   $pt = $null }
            }
            $rec = @{ Kind = $kw; Name = $name; Parent = $pt; Props = @{}; Expr = $expr; Id = $id }
            $model[$id] = $rec
            $stack.Add([pscustomobject]@{ Indent = $indent; Kind = $kw; Name = $name; Rec = $rec })
            continue
        }

        # --- property: key: value -------------------------------------------
        if ($trim -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            if ($top -and $top.Rec) { $top.Rec.Props[$Matches[1]] = $Matches[2].Trim() }
            continue
        }

        # --- bare boolean flag (isHidden / isKey on its own line) -----------
        if ($trim -match '^(isHidden|isKey)\s*$') {
            if ($top -and $top.Rec) { $top.Rec.Props[$Matches[1]] = 'true' }
            continue
        }

        # --- expression continuation for measure / partition ----------------
        if ($top -and $top.Rec -and ($top.Kind -eq 'measure' -or $top.Kind -eq 'partition')) {
            if ($null -eq $top.Rec.Expr) { $top.Rec.Expr = '' }
            $top.Rec.Expr = ($top.Rec.Expr + ' ' + $trim).Trim()
            continue
        }
    }
    return $model
}

# Relationships are declared with a GUID/name that differs across refs even when
# the relationship is logically the same. Re-key them by fromColumn->toColumn so
# an unchanged relationship is not reported as delete+add.
function Rekey-Relationships($model) {
    $out = @{}
    foreach ($id in $model.Keys) {
        $rec = $model[$id]
        if ($rec.Kind -eq 'relationship') {
            $from = Prop-Val $rec 'fromColumn'
            $to   = Prop-Val $rec 'toColumn'
            if ($from -and $to) {
                $newId = "relationship|$from->$to"
                $rec.Id = $newId
                $rec.Name = "$from -> $to"
                $out[$newId] = $rec
                continue
            }
        }
        $out[$id] = $rec
    }
    return $out
}

# Compare two parsed models; return an array of finding objects.
function Compare-Models {
    param($BaseModel, $HeadModel)

    $BaseModel = Rekey-Relationships $BaseModel
    $HeadModel = Rekey-Relationships $HeadModel

    $findings = @()
    $baseKeys = @($BaseModel.Keys)
    $headKeys = @($HeadModel.Keys)

    $deleted = New-Object System.Collections.Generic.List[string]
    foreach ($k in $baseKeys) { if (-not $HeadModel.ContainsKey($k)) { $deleted.Add($k) } }
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($k in $headKeys) { if (-not $BaseModel.ContainsKey($k)) { $added.Add($k) } }
    $common = @($baseKeys | Where-Object { $HeadModel.ContainsKey($_) })

    # --- rename detection (column / measure) among delete+add in same parent --
    $usedAdded = @{}
    $matchedDeleted = @{}
    foreach ($d in @($deleted)) {
        $br = $BaseModel[$d]
        if ($br.Kind -ne 'column' -and $br.Kind -ne 'measure') { continue }
        foreach ($a in @($added)) {
            if ($usedAdded.ContainsKey($a)) { continue }
            $ar = $HeadModel[$a]
            if ($ar.Kind -ne $br.Kind -or $ar.Parent -ne $br.Parent) { continue }
            $isMatch = $false
            if ($br.Kind -eq 'column') {
                $sig1 = (Prop-Val $br 'dataType') + '|' + (Prop-Val $br 'sourceColumn')
                $sig2 = (Prop-Val $ar 'dataType') + '|' + (Prop-Val $ar 'sourceColumn')
                if ($sig1 -ne '|' -and $sig1 -eq $sig2) { $isMatch = $true }
            } else {
                $e1 = Norm-Expr $br.Expr
                $e2 = Norm-Expr $ar.Expr
                if ($e1 -ne '' -and $e1 -eq $e2) { $isMatch = $true }
            }
            if ($isMatch) {
                $usedAdded[$a] = $true
                $matchedDeleted[$d] = $true
                $findings += [pscustomobject]@{
                    Severity = 'BREAKING'; Kind = $br.Kind; Parent = $br.Parent
                    Name = $br.Name; Detail = "renamed to '$($ar.Name)' (references by name break)"
                }
                break
            }
        }
    }

    # --- remaining deletions ------------------------------------------------
    foreach ($d in @($deleted)) {
        if ($matchedDeleted.ContainsKey($d)) { continue }
        $br = $BaseModel[$d]
        $sev = if ($br.Kind -eq 'partition') { 'WARNING' } else { 'BREAKING' }
        $findings += [pscustomobject]@{
            Severity = $sev; Kind = $br.Kind; Parent = $br.Parent
            Name = $br.Name; Detail = "deleted"
        }
    }

    # --- remaining additions ------------------------------------------------
    foreach ($a in @($added)) {
        if ($usedAdded.ContainsKey($a)) { continue }
        $ar = $HeadModel[$a]
        $findings += [pscustomobject]@{
            Severity = 'INFO'; Kind = $ar.Kind; Parent = $ar.Parent
            Name = $ar.Name; Detail = "added"
        }
    }

    # --- modifications on common objects ------------------------------------
    foreach ($k in $common) {
        $b = $BaseModel[$k]; $h = $HeadModel[$k]

        if ($b.Kind -eq 'column') {
            $bd = Prop-Val $b 'dataType'; $hd = Prop-Val $h 'dataType'
            if ($bd -ne $hd) { $findings += [pscustomobject]@{ Severity='BREAKING'; Kind='column'; Parent=$b.Parent; Name=$b.Name; Detail="dataType $bd -> $hd" } }
            $bs = Prop-Val $b 'sourceColumn'; $hs = Prop-Val $h 'sourceColumn'
            if ($bs -ne $hs) { $findings += [pscustomobject]@{ Severity='BREAKING'; Kind='column'; Parent=$b.Parent; Name=$b.Name; Detail="sourceColumn $bs -> $hs" } }
            $bsum = Prop-Val $b 'summarizeBy'; $hsum = Prop-Val $h 'summarizeBy'
            if ($bsum -ne $hsum) { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='column'; Parent=$b.Parent; Name=$b.Name; Detail="summarizeBy $bsum -> $hsum" } }
            if ((Prop-Val $b 'isHidden') -ne 'true' -and (Prop-Val $h 'isHidden') -eq 'true') { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='column'; Parent=$b.Parent; Name=$b.Name; Detail="now hidden" } }
            $bf = Prop-Val $b 'formatString'; $hf = Prop-Val $h 'formatString'
            if ($bf -ne $hf) { $findings += [pscustomobject]@{ Severity='INFO'; Kind='column'; Parent=$b.Parent; Name=$b.Name; Detail="formatString changed" } }
        }
        elseif ($b.Kind -eq 'measure') {
            $be = Norm-Expr $b.Expr; $he = Norm-Expr $h.Expr
            if ($be -ne $he) { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='measure'; Parent=$b.Parent; Name=$b.Name; Detail="expression changed" } }
            if ((Prop-Val $b 'isHidden') -ne 'true' -and (Prop-Val $h 'isHidden') -eq 'true') { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='measure'; Parent=$b.Parent; Name=$b.Name; Detail="now hidden" } }
            $bf = Prop-Val $b 'formatString'; $hf = Prop-Val $h 'formatString'
            if ($bf -ne $hf) { $findings += [pscustomobject]@{ Severity='INFO'; Kind='measure'; Parent=$b.Parent; Name=$b.Name; Detail="formatString changed" } }
            $bdf = Prop-Val $b 'displayFolder'; $hdf = Prop-Val $h 'displayFolder'
            if ($bdf -ne $hdf) { $findings += [pscustomobject]@{ Severity='INFO'; Kind='measure'; Parent=$b.Parent; Name=$b.Name; Detail="displayFolder changed" } }
        }
        elseif ($b.Kind -eq 'partition') {
            $be = Norm-Expr $b.Expr; $he = Norm-Expr $h.Expr
            if ($be -ne $he) { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='partition'; Parent=$b.Parent; Name=$b.Name; Detail="source expression changed" } }
        }
        elseif ($b.Kind -eq 'relationship') {
            $bc = Prop-Val $b 'crossFilteringBehavior'; $hc = Prop-Val $h 'crossFilteringBehavior'
            if ($bc -ne $hc) { $findings += [pscustomobject]@{ Severity='WARNING'; Kind='relationship'; Parent=$b.Parent; Name=$b.Name; Detail="crossFilteringBehavior $bc -> $hc" } }
        }
    }

    return $findings
}

# ==============================================================================
# Content fetchers
# ==============================================================================

function Get-ChangedTmdlFiles-PR {
    param([string]$Repo, [int]$PR)
    # plain: --jq emits filtered text. A PR with no .tmdl legitimately returns empty at exit 0; a
    # READ FAILURE must throw instead of an empty list read as "nothing changed" (#316).
    $files = Invoke-Gh -GhArgs @('api',"repos/$Repo/pulls/$PR/files",'--paginate','--jq','.[] | select(.filename | endswith(".tmdl")) | .filename') `
                       -What "leer los archivos del PR #$PR"
    return @($files | Where-Object { $_ })
}

function Get-Content-AtRef-API {
    param([string]$Repo, [string]$Ref, [string]$Path)
    $escaped = ($Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    # A file that is ADDED in the PR does not exist at the base ref: gh returns 404, and that empty
    # is legitimate ("" base content = everything reads as added). But a 401/5xx must NOT be swallowed
    # as "" - that would silently compare against empty and miss real breaking changes. So: 404 -> "",
    # any other failure -> throw (#316).
    try {
        $b64 = Invoke-Gh -GhArgs @('api',"repos/$Repo/contents/$escaped`?ref=$Ref",'--jq','.content') `
                         -What "leer $Path @ $Ref"
    } catch {
        if ($_.Exception.Message -match '404|Not Found') { return "" }
        throw
    }
    if (-not $b64) { return "" }
    try {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($b64 -replace '\s', '')))
    } catch { return "" }
}

function Get-Content-AtRef-Git {
    param([string]$Ref, [string]$Path)
    $c = git show "${Ref}:${Path}" 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($c -join "`n")
}

# ==============================================================================
# Main
# ==============================================================================

$mode = ""
if ($PR -gt 0) { $mode = "pr" }
elseif ($Base) { $mode = "local" }
else {
    Write-Error "Usa modo PR (-Repo owner/name -PR <n>) o modo local (-Base <ref> [-Head <ref>])."
    exit 2
}

# Resolve repo + token for PR mode.
if ($mode -eq "pr") {
    if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
    if (-not $env:GH_TOKEN) { Write-Error "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)."; exit 2 }
    if (-not $Repo) {
        $originUrl = git remote get-url origin 2>$null
        $Repo = Get-RepoFromOriginUrl $originUrl
    }
    if (-not $Repo) { Write-Error "No pude derivar el repo del origin - pasa -Repo owner/name."; exit 2 }
}

# Gather (path, baseContent, headContent) per changed .tmdl file.
$pairs = @()
if ($mode -eq "pr") {
    # plain: an empty base/head sha would make every file read as fully added/deleted - a false
    # review over an unread diff. A read failure must throw (#316).
    $baseSha = Invoke-Gh -GhArgs @('api',"repos/$Repo/pulls/$PR",'--jq','.base.sha') -What "leer base.sha del PR #$PR"
    $headSha = Invoke-Gh -GhArgs @('api',"repos/$Repo/pulls/$PR",'--jq','.head.sha') -What "leer head.sha del PR #$PR"
    $changed = Get-ChangedTmdlFiles-PR -Repo $Repo -PR $PR
    foreach ($p in $changed) {
        $pairs += [pscustomobject]@{
            Path = $p
            Base = Get-Content-AtRef-API -Repo $Repo -Ref $baseSha -Path $p
            Head = Get-Content-AtRef-API -Repo $Repo -Ref $headSha -Path $p
        }
    }
} else {
    $changed = git diff --name-only $Base $Head -- '*.tmdl' 2>$null
    foreach ($p in @($changed | Where-Object { $_ })) {
        $pairs += [pscustomobject]@{
            Path = $p
            Base = Get-Content-AtRef-Git -Ref $Base -Path $p
            Head = Get-Content-AtRef-Git -Ref $Head -Path $p
        }
    }
}

# Parse + compare each file, accumulate findings.
$allFindings = @()
foreach ($pair in $pairs) {
    $baseModel = Parse-Tmdl -Content $pair.Base
    $headModel = Parse-Tmdl -Content $pair.Head
    $f = Compare-Models -BaseModel $baseModel -HeadModel $headModel
    foreach ($item in $f) {
        $allFindings += [pscustomobject]@{
            File = $pair.Path; Severity = $item.Severity; Kind = $item.Kind
            Parent = $item.Parent; Name = $item.Name; Detail = $item.Detail
        }
    }
}

$rank = @{ 'BREAKING' = 0; 'WARNING' = 1; 'INFO' = 2 }
$allFindings = @($allFindings | Sort-Object @{ Expression = { $rank[$_.Severity] } }, Kind, Name)

$nBreaking = @($allFindings | Where-Object { $_.Severity -eq 'BREAKING' }).Count
$nWarning  = @($allFindings | Where-Object { $_.Severity -eq 'WARNING' }).Count
$nInfo     = @($allFindings | Where-Object { $_.Severity -eq 'INFO' }).Count

# --- JSON output (machine consumers / the gate) ------------------------------
if ($Json) {
    [pscustomobject]@{
        summary  = [pscustomobject]@{ breaking = $nBreaking; warning = $nWarning; info = $nInfo; files = $pairs.Count }
        findings = $allFindings
    } | ConvertTo-Json -Depth 6
    if ($FailOnBreaking -and $nBreaking -gt 0) { exit 1 }
    exit 0
}

# --- Colored report ----------------------------------------------------------
Write-Host "=== TMDL diff review ===" -ForegroundColor Cyan
if ($mode -eq "pr") { Write-Host "  $Repo  PR #$PR" -ForegroundColor DarkGray }
else { Write-Host "  local  $Base..$Head" -ForegroundColor DarkGray }
Write-Host ""

if ($pairs.Count -eq 0) {
    Write-Host "  No cambiaron archivos .tmdl - nada que revisar." -ForegroundColor DarkGray
    exit 0
}

Write-Host ("  Archivos .tmdl cambiados: {0}" -f $pairs.Count) -ForegroundColor DarkGray
Write-Host ""

if ($allFindings.Count -eq 0) {
    Write-Host "  Sin cambios de esquema detectados." -ForegroundColor Green
} else {
    foreach ($f in $allFindings) {
        $color = switch ($f.Severity) { 'BREAKING' { 'Red' } 'WARNING' { 'DarkYellow' } default { 'DarkGray' } }
        $obj = if ($f.Parent) { "$($f.Kind) $($f.Parent).$($f.Name)" } else { "$($f.Kind) $($f.Name)" }
        Write-Host ("  [{0,-8}] {1} - {2}" -f $f.Severity, $obj, $f.Detail) -ForegroundColor $color
        Write-Host ("             ({0})" -f $f.File) -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host ("----- RESUMEN: {0} breaking, {1} warning, {2} info -----" -f $nBreaking, $nWarning, $nInfo) -ForegroundColor Cyan

if ($nBreaking -gt 0) {
    Write-Host ""
    Write-Host "  Hay $nBreaking cambio(s) BREAKING de esquema." -ForegroundColor Red
    if ($FailOnBreaking) {
        Write-Host "  -FailOnBreaking activo -> GATE BLOCKED." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "  Advertencia (warn-only): reconoce estos cambios antes de mergear." -ForegroundColor DarkYellow
        Write-Host "  Un breaking change puede ser intencional (quitar una columna deprecada)." -ForegroundColor DarkGray
    }
}
exit 0
