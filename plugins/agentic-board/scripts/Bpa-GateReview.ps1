<#  Bpa-GateReview.ps1 — run Tabular Editor's Best Practice Analyzer against a PBIP/TMDL model and,
    on request, BLOCK a merge when it reports rule violations (M3.3, issue #16).

    The review gate already runs Tmdl-DiffReview.ps1 (breaking schema changes) warn-only. M3.3 adds
    the hard block: for a PR that touches a semantic model, BPA is the objective, automatable quality
    bar, so an ERROR-severity violation should stop the merge the same way a failing CI check does.

    Mirrors Tmdl-DiffReview.ps1: warn-only by default, `-FailOn error` (the gate's mode) exits 1 when
    the model has error-severity violations. Degrades SAFELY — a PR with no model, a repo with no BPA
    rules file, or a machine without Tabular Editor is NOT a gate failure: it is reported and skipped
    (exit 0). Blocking a merge requires actually having run BPA and found errors, never the absence of
    the tool.

    Two ways to point at the model + rules:
      # PR mode (the gate): only acts when the PR touches *.tmdl; model + rules resolved from the cwd.
      ./Bpa-GateReview.ps1 -Repo owner/name -PR 42 -FailOn error
      # Local mode:
      ./Bpa-GateReview.ps1 -Model ./MyReport.pbip -Rules ./bpa/rules.json -FailOn error

    Rules are resolved from -Rules, else $env:ABIOS_BPA_RULES, else a repo-committed BPA rules file
    (BPARules.json / .bpa/rules.json). Tabular Editor is resolved from `te` (TE3) or TabularEditor.exe
    (TE2); both emit GitHub-annotation output (::error:: / ::warning:: / ::notice::) that this parses.

    Requires $env:GH_TOKEN for PR mode (via the gh-account skill).
#>
[CmdletBinding()]
param(
    [string]$Repo = "",
    [int]   $PR = 0,
    [string]$Model = "",
    [string]$Rules = "",
    [ValidateSet('error','warning','none')][string]$FailOn = 'error',
    [switch]$Json,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)
$ErrorActionPreference = "Stop"

# ── Pure helpers (unit-testable; no gh/TE/network) ────────────────────────────

# Parse Tabular Editor's GitHub-annotation output (TE2 `-G`, TE3 `--ci github`) into counts +
# findings. Both CLIs emit one line per violation: `::error ...::message` / `::warning ...::message`
# / `::notice ...::message`. Anything else (progress, banners) is ignored. Pure.
function ConvertFrom-BpaAnnotations {
    param([string[]]$Lines)
    $counts   = @{ error = 0; warning = 0; notice = 0 }
    $findings = @()
    foreach ($line in @($Lines)) {
        $m = [regex]::Match([string]$line, '^\s*::(error|warning|notice)\b[^:]*::\s*(.*)$')
        if (-not $m.Success) { continue }
        $sev = $m.Groups[1].Value
        $counts[$sev]++
        $findings += [pscustomobject]@{ severity = $sev; message = $m.Groups[2].Value.Trim() }
    }
    # `info` is the friendlier alias for GitHub's `notice`, so the report reads BREAKING-style.
    return [pscustomobject]@{ error = $counts.error; warning = $counts.warning; info = $counts.notice; findings = $findings }
}

# Decide whether BPA results block the merge, given the counts and the -FailOn level. Pure.
#   error   -> block on any error-severity violation (the gate default).
#   warning -> block on error OR warning (stricter).
#   none    -> never block (warn-only), whatever was found.
function Get-BpaVerdict {
    param($Counts, [string]$FailOn = 'error')
    $err  = [int]$Counts.error
    $warn = [int]$Counts.warning
    if ($FailOn -eq 'none')    { return [pscustomobject]@{ Blocked = $false; Reason = '' } }
    if ($FailOn -eq 'warning' -and ($err -gt 0 -or $warn -gt 0)) {
        return [pscustomobject]@{ Blocked = $true; Reason = "$err error(s), $warn warning(s)" }
    }
    if ($FailOn -eq 'error' -and $err -gt 0) {
        return [pscustomobject]@{ Blocked = $true; Reason = "$err error(s)" }
    }
    return [pscustomobject]@{ Blocked = $false; Reason = '' }
}

# Dot-source guard: tests set $env:ABIOS_BPA_DOTSOURCE to load the pure helpers only.
if ($env:ABIOS_BPA_DOTSOURCE) { return }

# ── Side-effecting from here ──────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# A safe skip: report why BPA did not run and exit 0. Never block a merge on the ABSENCE of the tool
# or config — only on violations it actually found.
function Exit-BpaSkip([string]$Why) {
    if ($Json) { [pscustomobject]@{ ran = $false; skipped = $Why; summary = $null } | ConvertTo-Json -Depth 5 }
    else       { Write-Host "  BPA: $Why - salteado (no bloquea)." -ForegroundColor DarkYellow }
    exit 0
}

# 1. PR mode: only act when the PR touches a semantic model (*.tmdl). A read failure throws (#316).
if ($PR -gt 0) {
    if (-not $Repo) { throw "-PR necesita -Repo owner/name." }
    if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
    $tmdlChanged = Invoke-Gh -GhArgs @('api',"repos/$Repo/pulls/$PR/files",'--paginate','--jq','.[] | select(.filename | endswith(".tmdl")) | .filename') `
                             -What "leer los archivos del PR #$PR"
    if (-not $tmdlChanged) { Exit-BpaSkip "el PR no toca ningun modelo (*.tmdl)" }
}

# 2. Resolve the model source: -Model, else a .pbip or a TMDL definition folder in the cwd.
if (-not $Model) {
    $pbip = Get-ChildItem -Path . -Recurse -Filter *.pbip -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pbip) {
        $Model = $pbip.FullName
    } else {
        $anyTmdl = Get-ChildItem -Path . -Recurse -Filter *.tmdl -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($anyTmdl) { $Model = $anyTmdl.Directory.FullName }
    }
}
if (-not $Model) { Exit-BpaSkip "no encontre un modelo (.pbip / carpeta .tmdl) para analizar" }

# 3. Resolve the BPA rules file. No rules = no objective bar; skip rather than block every BI PR.
if (-not $Rules) { $Rules = $env:ABIOS_BPA_RULES }
if (-not $Rules) {
    $cand = Get-ChildItem -Path . -Recurse -Include 'BPARules.json','rules.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '(?i)bpa' } | Select-Object -First 1
    if ($cand) { $Rules = $cand.FullName }
}
if (-not $Rules -or -not (Test-Path $Rules)) {
    Exit-BpaSkip "no hay archivo de reglas BPA (pasa -Rules, define ABIOS_BPA_RULES, o commitea BPARules.json)"
}

# 4. Resolve Tabular Editor: `te` (TE3) preferred, else TabularEditor.exe (TE2). Absence = skip.
$te3 = Get-Command te -ErrorAction SilentlyContinue
$te2 = Get-Command TabularEditor.exe -ErrorAction SilentlyContinue
if (-not $te3 -and -not $te2) {
    Exit-BpaSkip "Tabular Editor no esta instalado (ni 'te' TE3 ni TabularEditor.exe TE2)"
}

# 5. Run BPA with GitHub-annotation output so both CLIs' results parse the same way.
Write-Host "  BPA: analizando '$([System.IO.Path]::GetFileName($Model))' con reglas '$([System.IO.Path]::GetFileName($Rules))'..." -ForegroundColor Cyan
if ($te3) {
    # TE3: `te bpa run` returns non-zero on --fail-on; we parse annotations for the report and let
    # Get-BpaVerdict decide, so run it warn-only here (--fail-on none) and own the verdict ourselves.
    $raw = & te bpa run -m "$Model" -r "$Rules" --ci github --fail-on none 2>&1
} else {
    # TE2: `-G` emits GitHub annotations; `-A <rules>` runs them against the model/PBIP folder.
    $raw = & TabularEditor.exe "$Model" -A "$Rules" -G 2>&1
}
$lines   = @($raw | ForEach-Object { [string]$_ })
$parsed  = ConvertFrom-BpaAnnotations $lines
$verdict = Get-BpaVerdict $parsed $FailOn

if ($Json) {
    [pscustomobject]@{
        ran     = $true
        summary = [pscustomobject]@{ error = $parsed.error; warning = $parsed.warning; info = $parsed.info }
        blocked = $verdict.Blocked
        findings = $parsed.findings
    } | ConvertTo-Json -Depth 6
    if ($verdict.Blocked) { exit 1 } else { exit 0 }
}

Write-Host ("  BPA: {0} error(es), {1} warning(s), {2} info." -f $parsed.error, $parsed.warning, $parsed.info) `
    -ForegroundColor $(if ($parsed.error) { 'Red' } elseif ($parsed.warning) { 'DarkYellow' } else { 'Green' })
foreach ($f in ($parsed.findings | Select-Object -First 30)) {
    $c = switch ($f.severity) { 'error' { 'Red' } 'warning' { 'DarkYellow' } default { 'DarkGray' } }
    Write-Host ("    [{0}] {1}" -f $f.severity, $f.message) -ForegroundColor $c
}
if ($verdict.Blocked) {
    Write-Host ("  BPA GATE BLOCKED: {0} (-FailOn {1})." -f $verdict.Reason, $FailOn) -ForegroundColor Red
    exit 1
}
Write-Host "  BPA OK (sin violaciones que bloqueen con -FailOn $FailOn)." -ForegroundColor Green
exit 0
