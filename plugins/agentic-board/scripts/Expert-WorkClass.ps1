<#
.SYNOPSIS
    Classify a change as CODE or VISUAL, so the autonomy boundary can follow the owner's actual
    rule instead of a flat action list (#529, part of #526).

.DESCRIPTION
    The rule this exists to express, stated by the owner:

      "En cosas que en verdad se requiere revisar codigo y cosas complejas, esas tareas deseo que
       los agentes apliquen una revision cuidadosa y lo puedan hacer solo. Cuando es una pagina web
       donde se ve visiblemente un tablero, una imagen, cosas asi, alli si me gustaria tomar la
       decision yo de hacer el review y darle el ok."

    So the boundary is not about WHICH ACTION (merge/deploy/...), it is about WHAT THE CHANGE
    PRODUCES. Asking a non-programmer to approve a diff he cannot evaluate is not caution - it
    hands him a decision he has no way to make. Asking him to approve a dashboard IS meaningful:
    he is the only one who can look at it and say whether it reads right.

    TIMING - the constraint that shapes this file. The brake marker is written at LAUNCH, before a
    single line exists, so the work class CANNOT be decided there. The contract therefore carries
    the POLICY (what counts as visual, and whether code-class may merge itself); the CLASSIFICATION
    runs later, against the paths the run actually touched. Facts first, decision second.

    FAIL DIRECTION: any visual path in the diff makes the WHOLE change visual. A human glancing at
    something he did not strictly need to see costs a minute; an agent merging a report he wanted
    to eyeball costs trust, and trust is the thing this whole module runs on.

    Pure (no side effects) behind a dot-source guard ($env:ABIOS_WORKCLASS_DOTSOURCE).

.EXAMPLE
    . .\Expert-WorkClass.ps1 ; Get-WorkClass -ChangedPaths @('src/app.ps1') -Policy (New-WorkClassPolicy)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

<#
    The default policy: which paths produce something the owner can judge by LOOKING at it.

    Deliberately NOT here: plain markdown and docs. They are read, not seen - judging them needs the
    same reading a diff needs, so routing them to the owner would recreate exactly the friction this
    is meant to remove. A project where prose IS the product (a website's posts) adds its own
    patterns to the contract rather than having that guessed for it.
#>
function New-WorkClassPolicy {
    @{
        visualPatterns = @(
            # Power BI / Fabric artefacts - the report side, which is looked at
            '*.pbix', '*.pbip', '*.pbir',
            '**/definition/pages/**', '**/*.Report/**', '**/report.json', '**/visual.json',
            '**/*.theme.json',
            # Web surfaces
            '*.html', '*.htm', '*.css', '*.scss', '*.sass', '*.vue', '*.svelte',
            '**/public/**', '**/static/**', '**/assets/**',
            # Images - the thing you cannot review by reading
            '*.png', '*.jpg', '*.jpeg', '*.gif', '*.webp', '*.svg', '*.ico'
        )
        # SUBTRACTED from visualPatterns (#567): paths that wear a web-tech extension but are
        # judged by READING, not by looking. In a web app (a FabricApp) every change touches
        # css/html/assets, so without exceptions the whole project routes to the owner and the
        # classification stops carrying information. Empty by default - each project declares
        # its own plumbing in the contract (workClass.codeExceptions), e.g.
        # 'src/components/**/*.css' for utility styles nobody screenshots. The FAIL DIRECTION
        # is preserved: an exception must be declared, never guessed.
        codeExceptions = @()
        # Classes the human always approves personally, whatever the run was told to do.
        humanApproves  = @('visual')
    }
}

# Translate one glob to a regex. `-like` cannot do this: it has no '**' and its '*' happily crosses
# '/', so 'src/*.ps1' would match 'src/deep/nested/x.ps1' and the classification would drift wider
# with every subdirectory.
function ConvertTo-GlobRegex {
    param([Parameter(Mandatory)][string]$Pattern)
    $p = ($Pattern -replace '\\', '/')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $p.Length) {
        $ch = $p[$i]
        if ($ch -eq '*') {
            if ($i + 1 -lt $p.Length -and $p[$i + 1] -eq '*') {
                # '**/' matches any number of leading directories, including none.
                if ($i + 2 -lt $p.Length -and $p[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*'); $i++; continue      # single '*' stays inside one segment
        }
        if ($ch -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
        [void]$sb.Append([regex]::Escape([string]$ch)); $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

# Does this path match any pattern? A bare '*.png' matches at ANY depth - a glob written the way a
# human writes it, rather than one that only catches files in the repo root.
function Test-IsVisualPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string[]]$VisualPatterns = @()
    )
    # Strip a literal './' prefix only. `TrimStart('./')` takes a CHARACTER SET, not a prefix, so it
    # also ate the leading dot of '.reports/x.md' -> 'reports/x.md', and a project pattern like
    # '.reports/**' would then never match: a visual change silently reclassified as code.
    $norm = ("$Path" -replace '\\', '/').Trim()
    while ($norm.StartsWith('./')) { $norm = $norm.Substring(2) }
    if (-not $norm) { return $false }
    foreach ($pat in @($VisualPatterns)) {
        if (-not "$pat".Trim()) { continue }
        $rx = ConvertTo-GlobRegex -Pattern $pat
        if ($norm -match "(?i)$rx") { return $true }
        # A pattern with no directory part applies at every depth, so 'docs/img/a.png' matches '*.png'.
        if ("$pat" -notmatch '[\\/]' -and ($norm -split '/')[-1] -match "(?i)$rx") { return $true }
    }
    return $false
}

<#
    Classify the change. Returns @{ class; visualPaths; reason }.

    'visual' when ANY touched path is visual (see FAIL DIRECTION in the header), 'code' otherwise.
    An EMPTY path list is 'unknown', never 'code': "I could not see what changed" must not be the
    same answer as "I looked and it was all code" - that conflation is the defect this repo keeps
    finding in its own surfaces.
#>
function Get-WorkClass {
    param(
        [string[]]$ChangedPaths = @(),
        [hashtable]$Policy
    )
    if (-not $Policy) { $Policy = New-WorkClassPolicy }
    $paths = @(@($ChangedPaths) | Where-Object { "$_".Trim() })
    if ($paths.Count -eq 0) {
        return @{ class = 'unknown'; visualPaths = @(); visualGroups = @()
                  reason = 'no pude determinar que archivos cambiaron' }
    }
    $visual = @($paths | Where-Object {
        (Test-IsVisualPath -Path $_ -VisualPatterns $Policy.visualPatterns) -and
        -not (Test-IsVisualPath -Path $_ -VisualPatterns @($Policy.codeExceptions))
    })
    if ($visual.Count -gt 0) {
        # The BATCH view (#567): the owner approves SECTIONS, not 47 file rows. Grouping by the
        # top-level directory turns "review these paths" into "look at the dashboard section" -
        # the decision he can actually make.
        $groups = @($visual | ForEach-Object {
            $segs = (("$_" -replace '\\', '/') -split '/')
            if ($segs.Count -gt 1) { $segs[0] } else { '(raiz)' }
        } | Sort-Object -Unique)
        return @{
            class        = 'visual'
            visualPaths  = $visual
            visualGroups = $groups
            reason       = "el cambio toca $($visual.Count) archivo(s) que se juzgan mirandolos, en $($groups.Count) seccion(es): $($groups -join ', ')"
        }
    }
    return @{ class = 'code'; visualPaths = @(); visualGroups = @(); reason = 'el cambio es codigo: se juzga leyendolo' }
}

<#
    Must a human approve this personally?

    'unknown' answers YES. Not knowing what changed is not permission - and this is the one place
    where the cheap failure (the owner glances at something routine) and the expensive one (an
    agent ships a dashboard he wanted to see) are wildly asymmetric.
#>
function Test-HumanMustApprove {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Class,
        [hashtable]$Policy
    )
    if (-not $Policy) { $Policy = New-WorkClassPolicy }
    $c = "$Class".Trim().ToLowerInvariant()
    if (-not $c -or $c -eq 'unknown') { return $true }
    $needs = @(@($Policy.humanApproves) | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    return [bool]($needs -contains $c)
}

# Reads the CONTRACT's policy when there is one, falling back to the defaults. Kept next to the
# pure core so callers have one obvious way to get the effective policy.
function Get-EffectiveWorkClassPolicy {
    param([hashtable]$Contract)
    $defaults = New-WorkClassPolicy
    if (-not $Contract -or -not $Contract.workClass) { return $defaults }
    $wc = $Contract.workClass
    $out = @{}
    foreach ($k in $defaults.Keys) {
        $out[$k] = if ($wc.ContainsKey($k) -and @($wc[$k]).Count -gt 0) { @($wc[$k]) } else { $defaults[$k] }
    }
    return $out
}

<#
    Which definition-of-done gates does THIS diff actually owe? (#569)

    The contract defaults all six gates to true and the brief listed them flat, so a 10-line
    docs fix owed the same six-gate verify pass as a model migration. The review gate already
    self-skips bpa/tmdl on non-model PRs; this extends that shape to the whole DoD, from the
    same facts (the changed paths):

      - bpa / tmdlBreaking : only when a semantic-model file changed (*.tmdl, *.bim, *.pbism)
      - build / lint / tests: only when something EXECUTABLE changed - docs, images and data
        files are read, not run
      - ci                  : always; it is the harness that proves the others ran

    FAIL DIRECTION: an empty path list returns every enabled gate - "I could not see what
    changed" must never waive a single check. And this only ever DISABLES gates the contract
    already enabled; it cannot invent one the contract turned off. Pure.
#>
function Get-ApplicableDodGates {
    param(
        [hashtable]$Dod = @{},
        [string[]]$ChangedPaths = @()
    )
    # Strict boolean, not truthiness (external review): a hand-edited contract with "bpa":"false"
    # is a non-empty string, and truthiness would re-enable the gate the owner turned off.
    $enabled = @(@($Dod.Keys) | Where-Object {
        $v = $Dod[$_]
        ($v -is [bool] -and $v) -or ("$v" -match '^\s*(?i)true\s*$')
    })
    $paths = @(@($ChangedPaths) | ForEach-Object { ("$_" -replace '\\', '/').Trim() } | Where-Object { $_ })
    if ($paths.Count -eq 0) { return @($enabled) }   # unknown diff -> every enabled gate

    $modelTouched = [bool]($paths | Where-Object { $_ -match '(?i)\.(tmdl|bim|pbism)$' })
    $nonExecutable = '(?i)\.(md|markdown|txt|png|jpg|jpeg|gif|webp|svg|ico|csv)$'
    $execTouched  = [bool]($paths | Where-Object { $_ -notmatch $nonExecutable })

    $out = @()
    foreach ($g in $enabled) {
        $keep = switch ("$g".ToLowerInvariant()) {
            'bpa'          { $modelTouched }
            'tmdlbreaking' { $modelTouched }
            'build'        { $execTouched }
            'lint'         { $execTouched }
            'tests'        { $execTouched }
            default        { $true }          # ci and anything unknown: always owed
        }
        if ($keep) { $out += $g }
    }
    return @($out)
}

# Dot-source guard: tests set $env:ABIOS_WORKCLASS_DOTSOURCE to load the pure core only.
if ($env:ABIOS_WORKCLASS_DOTSOURCE) { return }

# ── CLI: classify the current branch against the default branch ────────────────
# No Get-AbiosStateDir dot-source here: Read-ExpertContract -> Get-ExpertContractPath already does it.
$prevC = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC

$baseRef = git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
if (-not $baseRef) { $baseRef = 'origin/main' }
$changed = @(git diff --name-only "$baseRef...HEAD" 2>$null | Where-Object { "$_".Trim() })

$policy  = Get-EffectiveWorkClassPolicy -Contract (Read-ExpertContract)
$verdict = Get-WorkClass -ChangedPaths $changed -Policy $policy

Write-Host "=== Clase de trabajo  (vs $baseRef) ===" -ForegroundColor Cyan
Write-Host ("  Archivos cambiados : {0}" -f $changed.Count)
Write-Host ("  Clase              : {0}" -f $verdict.class) -ForegroundColor $(if ($verdict.class -eq 'code') { 'Green' } else { 'Yellow' })
Write-Host ("  Motivo             : {0}" -f $verdict.reason) -ForegroundColor DarkGray
if ($verdict.visualPaths.Count -gt 0) {
    Write-Host ("  Secciones a mirar (aprueba por LOTE, no archivo por archivo): {0}" -f ($verdict.visualGroups -join ', ')) -ForegroundColor Yellow
    Write-Host "  Lo que se juzga mirando:" -ForegroundColor Yellow
    $verdict.visualPaths | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
}
if (Test-HumanMustApprove -Class $verdict.class -Policy $policy) {
    Write-Host "  -> Lo aprueba una persona: hay algo que se juzga viendolo." -ForegroundColor Yellow
} else {
    Write-Host "  -> El agente puede cerrarlo solo, si cumple los estandares." -ForegroundColor Green
}

# Which DoD gates THIS diff owes (#569): derived from the same changed paths, so a docs fix does
# not pay a model migration's toll. An unreadable diff owes every enabled gate.
$contractForGates = Read-ExpertContract
# RAW values, no [bool] coercion (review round 2): [bool]'false' is $true in PowerShell, so the
# cast re-enabled exactly the string-disabled gates the helper's strict parser refuses.
$dodTable = @{}
if ($contractForGates.dod) { foreach ($k in $contractForGates.dod.Keys) { $dodTable[$k] = $contractForGates.dod[$k] } }
$owed = @(Get-ApplicableDodGates -Dod $dodTable -ChangedPaths $changed)
# "Skipped" = enabled by the same strict rule the helper uses, minus what the diff owes.
$enabledAll = @(Get-ApplicableDodGates -Dod $dodTable -ChangedPaths @())
$skipped = @($enabledAll | Where-Object { $owed -notcontains $_ })
Write-Host ""
Write-Host ("  DoD que APLICA a este diff : {0}" -f $(if ($owed.Count) { ($owed | Sort-Object) -join ', ' } else { '(ninguna)' })) -ForegroundColor Cyan
if ($skipped.Count) {
    Write-Host ("  DoD que NO aplica (nada que la dispare en el diff): {0}" -f (($skipped | Sort-Object) -join ', ')) -ForegroundColor DarkGray
}


