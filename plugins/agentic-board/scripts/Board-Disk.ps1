<#
.SYNOPSIS
    /board disk: one plan-first report of what fills the disk, and one --force that cleans only
    what is provably safe (#737).

.DESCRIPTION
    Measured on the reporter's machine on 2026-09-29, ~/.claude held about 5.6 GB. The biggest
    items were:
      * projects            2.8 GB  session transcripts          -> /board transcripts (#736)
      * compact-snapshots   1.7 GB  copies of those transcripts  -> cleaned here
      * plugins             0.7 GB  old cached plugin builds     -> cleaned here (plugins clean)
      * markitdown-venv     0.4 GB  a third-party tool           -> reported, never touched
    and each repo's .agentic-board/ state (briefings, logs) -> cleaned here for THIS repo.

    What --force does, and the rule behind each:
      * Compaction snapshots. The old PreCompact hook copied the whole transcript on every
        compaction; the hook now writes a marker instead (#737). A copy is deleted only when the
        original transcript still exists, starts the same and is at least as long - or was
        compressed into the transcript archive and covers it. Otherwise it may be the last copy
        and is kept.
      * Old plugin builds: exactly `/board plugins clean -Execute` (Get-VersionCleanupPlan +
        Invoke-PluginCleanup, re-verified right before deleting).
      * This repo's .agentic-board/ state: exactly Clear-AbiosState.ps1 -Force.
    Transcripts are only REPORTED here: they have their own verb, their own confirmation and a
    restore path (/board transcripts). Nothing outside ~/.claude and this repo is touched.

.PARAMETER Force
    Clean. Without it nothing is written.

.PARAMETER ClaudeHome
    The Claude home (default ~/.claude, or CLAUDE_CONFIG_DIR).

.PARAMETER Json
    Emit the plan / outcome as JSON.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ClaudeHome = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ pure helpers

# May this compaction snapshot be deleted? PURE.
#   $Snapshot      - { SessionId; Bytes; Head }   Head = the first bytes, as text, for comparison
#   $Original      - { Exists; Bytes; Head }      the transcript in ~/.claude/projects
#   $ArchivedBytes - size of that transcript in the transcript archive (0 = not archived)
function Get-SnapshotVerdict {
    param($Snapshot, $Original, [long]$ArchivedBytes = 0)
    $mk = { param($ok, $why) [pscustomobject]@{ Delete = $ok; Reason = $why } }
    if (-not "$($Snapshot.SessionId)") { return (& $mk $false 'could not read which session it belongs to - kept') }
    if ($Original -and $Original.Exists) {
        if ($Original.Head -ne $Snapshot.Head) { return (& $mk $false 'does not start like the transcript of its session - not a plain copy, kept') }
        if ($Original.Bytes -lt $Snapshot.Bytes) { return (& $mk $false 'longer than the transcript of its session - the transcript does not hold all of it, kept') }
        return (& $mk $true 'duplicate: the transcript of its session still holds all of it')
    }
    if ($ArchivedBytes -ge $Snapshot.Bytes -and $ArchivedBytes -gt 0) {
        return (& $mk $true 'duplicate: its transcript is in the transcript archive and covers it')
    }
    return (& $mk $false 'its transcript is gone - this may be the only copy, kept')
}

# Big folders of the Claude home that no component of this verb manages. PURE. Reported so the
# user sees them; never touched.
function Get-UnmanagedBigDirs {
    param([object[]]$Dirs = @(), [string[]]$Managed = @(), [long]$MinBytes = 100MB)
    @($Dirs | Where-Object { $_.Bytes -ge $MinBytes -and $Managed -notcontains $_.Name } | Sort-Object Bytes -Descending)
}

if ($env:ABIOS_DISK_DOTSOURCE) { return }

# ------------------------------------------------------------- live (side-effecting)

. (Join-Path $PSScriptRoot 'PluginState.ps1')
$script:PrevDotSource = $env:ABIOS_BOARDWORK_DOTSOURCE
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
try   { . (Join-Path $PSScriptRoot 'Board-Work.ps1') }
finally {
    $env:ABIOS_BOARDWORK_DOTSOURCE = $script:PrevDotSource
    foreach ($k in $PSBoundParameters.Keys) { Set-Variable -Name $k -Value $PSBoundParameters[$k] -Scope Local }
}

$home_ = Get-ClaudeHomeDir $ClaudeHome
$mb = { param($b) "{0:N0} MB" -f ($b / 1MB) }
$dirBytes = { param($p) if (Test-Path -LiteralPath $p) { [long]((Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) } else { 0L } }
$headOf = { param($p)
    $fs = [IO.File]::OpenRead($p)
    try { $buf = New-Object byte[] 4096; $n = $fs.Read($buf, 0, $buf.Length); [Convert]::ToBase64String($buf, 0, $n) } finally { $fs.Dispose() } }

# --- 1. compaction snapshots --------------------------------------------------
$transcripts = @{}
$projects = Join-Path $home_ 'projects'
if (Test-Path -LiteralPath $projects) {
    foreach ($f in @(Get-ChildItem -LiteralPath $projects -Recurse -Depth 1 -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) { $transcripts[$f.BaseName] = $f }
}
$archived = @{}
$archIndex = Join-Path (Join-Path $home_ 'transcript-archive') 'index.jsonl'
if (Test-Path -LiteralPath $archIndex) {
    foreach ($l in (Get-Content -LiteralPath $archIndex -Encoding utf8)) { try { $j = $l | ConvertFrom-Json; $archived["$($j.sessionId)"] = [long]$j.origBytes } catch { } }
}
$snapFiles = @()
$globalSnaps = Join-Path $home_ 'compact-snapshots'
if (Test-Path -LiteralPath $globalSnaps) { $snapFiles += @(Get-ChildItem -LiteralPath $globalSnaps -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) }
$repoRoot = "$(git rev-parse --show-toplevel 2>$null)".Trim()
if ($repoRoot) {
    $repoSnaps = Join-Path (Join-Path $repoRoot '.agentic-board') 'compact-snapshots'
    if (Test-Path -LiteralPath $repoSnaps) { $snapFiles += @(Get-ChildItem -LiteralPath $repoSnaps -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) }
}
$snapRows = foreach ($s in $snapFiles) {
    $sid = ''
    foreach ($l in @(Get-Content -LiteralPath $s.FullName -TotalCount 10 -Encoding utf8 -ErrorAction SilentlyContinue)) {
        try { $j = $l | ConvertFrom-Json -ErrorAction Stop; if ($j.sessionId) { $sid = "$($j.sessionId)"; break } } catch { }
    }
    $o = $transcripts[$sid]
    $orig = if ($o) { [pscustomobject]@{ Exists = $true; Bytes = $o.Length; Head = (& $headOf $o.FullName) } } else { [pscustomobject]@{ Exists = $false; Bytes = 0; Head = '' } }
    $v = Get-SnapshotVerdict -Snapshot ([pscustomobject]@{ SessionId = $sid; Bytes = $s.Length; Head = (& $headOf $s.FullName) }) `
        -Original $orig -ArchivedBytes $(if ($sid -and $archived.ContainsKey($sid)) { $archived[$sid] } else { 0 })
    [pscustomobject]@{ Path = $s.FullName; Bytes = $s.Length; SessionId = $sid; Delete = $v.Delete; Reason = $v.Reason; Outcome = 'planned' }
}
$snapRows = @($snapRows)

# --- 2. old plugin builds -----------------------------------------------------
$pluginPlan = Get-VersionCleanupPlan -ClaudeHome $ClaudeHome
$pluginRemovable = if ($pluginPlan.Ok) { @($pluginPlan.Items | Where-Object Action -eq 'remove') } else { @() }

# --- 3. this repo's .agentic-board state (Clear-AbiosState, plan only here) ---
$clearState = Join-Path $PSScriptRoot 'Clear-AbiosState.ps1'

# --- 4. transcripts (reported only) -------------------------------------------
$tr = $null
try { $tr = (& (Join-Path $PSScriptRoot 'Board-Transcripts.ps1') -Json -ClaudeHome $ClaudeHome 6>$null) -join "`n" | ConvertFrom-Json } catch { $tr = $null }

# --- 5. what else is big and not ours -----------------------------------------
$topDirs = @(Get-ChildItem -LiteralPath $home_ -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = (& $dirBytes $_.FullName) } })
$unmanaged = @(Get-UnmanagedBigDirs -Dirs $topDirs -Managed @('projects', 'compact-snapshots', 'plugins', 'transcript-archive'))

# --- execute ------------------------------------------------------------------
$pluginOut = $null
if ($Force) {
    foreach ($r in @($snapRows | Where-Object Delete)) {
        try { Remove-Item -LiteralPath $r.Path -Force; $r.Outcome = 'deleted' } catch { $r.Outcome = "failed: $($_.Exception.Message)" }
    }
    # Leave no empty per-repo snapshot folders behind (moved.log is the other hook's own log: kept).
    if (Test-Path -LiteralPath $globalSnaps) {
        foreach ($d in @(Get-ChildItem -LiteralPath $globalSnaps -Directory)) {
            if (-not (Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File)) { }
        }
    }
    if ($pluginPlan.Ok -and $pluginRemovable.Count -gt 0) { $pluginOut = Invoke-PluginCleanup -Plan $pluginPlan -ClaudeHome $ClaudeHome }
    if ($repoRoot) { & $clearState -Force 6>$null | Out-Null }
}

# --- report -------------------------------------------------------------------
$snapDel = @($snapRows | Where-Object Delete); $snapKeep = @($snapRows | Where-Object { -not $_.Delete })
$snapDelBytes = [long](($snapDel | Measure-Object Bytes -Sum).Sum)
$plugBytes = [long](($pluginRemovable | Measure-Object SizeBytes -Sum).Sum)
if ($Json) {
    [pscustomobject]@{
        executed = [bool]$Force; claudeHome = $home_
        snapshots = [pscustomobject]@{ total = $snapRows.Count; deletable = $snapDel.Count; deletableBytes = $snapDelBytes; kept = @($snapKeep | Group-Object Reason | ForEach-Object { [pscustomobject]@{ reason = $_.Name; count = $_.Count } }); deleted = @($snapRows | Where-Object Outcome -eq 'deleted').Count }
        pluginBuilds = [pscustomobject]@{ ok = [bool]$pluginPlan.Ok; reason = $pluginPlan.Reason; removable = $pluginRemovable.Count; removableBytes = $plugBytes; removed = $(if ($pluginOut) { @($pluginOut.Removed).Count } else { 0 }) }
        transcripts = $(if ($tr) { [pscustomobject]@{ total = $tr.transcripts; totalBytes = $tr.totalBytes; thresholds = $tr.thresholds } } else { $null })
        unmanaged = @($unmanaged)
    } | ConvertTo-Json -Depth 6
    exit 0
}

$mode = if ($Force) { 'EJECUTADO' } else { 'PLAN - no se cambio nada' }
Write-Host ""
Write-Host "=== /board disk  ($mode) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Copias de transcripts de compactaciones: $($snapRows.Count) ($(& $mb (($snapRows | Measure-Object Bytes -Sum).Sum)))" -ForegroundColor Yellow
Write-Host ("     Borrables (el transcript original las contiene): {0}, {1}" -f $snapDel.Count, (& $mb $snapDelBytes))
foreach ($g in @($snapKeep | Group-Object Reason)) { Write-Host ("     Se conservan {0}: {1}" -f $g.Count, $g.Name) -ForegroundColor DarkGray }
Write-Host ""
if ($pluginPlan.Ok) { Write-Host ("  2. Versiones viejas de plugins que nadie usa: {0}, {1}" -f $pluginRemovable.Count, (& $mb $plugBytes)) -ForegroundColor Yellow }
else { Write-Host "  2. Versiones viejas de plugins: no pude planear ($($pluginPlan.Reason)) - no se toca nada" -ForegroundColor Yellow }
Write-Host ""
if ($repoRoot) { Write-Host "  3. Estado temporal de este repo (.agentic-board: briefings, logs viejos): lo limpia el mismo reaper de /board doctor" -ForegroundColor Yellow }
else { Write-Host "  3. Estado temporal: no estoy dentro de un repo, se omite" -ForegroundColor DarkGray }
Write-Host ""
if ($tr) {
    $t30 = @($tr.thresholds | Where-Object Days -eq 30)[0]
    Write-Host ("  4. Transcripts de sesiones: {0} ({1}). Con 30 dias se comprimirian {2} ({3})." -f $tr.transcripts, (& $mb $tr.totalBytes), $t30.Count, (& $mb $t30.Bytes)) -ForegroundColor Yellow
    Write-Host "     Tienen su propio verbo, con confirmacion y forma de recuperarlos: /board transcripts" -ForegroundColor DarkGray
} else { Write-Host "  4. Transcripts: no pude medirlos - usa /board transcripts" -ForegroundColor DarkGray }
if ($unmanaged.Count) {
    Write-Host ""
    Write-Host "  Tambien ocupan espacio, pero no son de esta herramienta (no se tocan):" -ForegroundColor DarkGray
    foreach ($u in $unmanaged) { Write-Host ("     {0,-24} {1}" -f $u.Name, (& $mb $u.Bytes)) -ForegroundColor DarkGray }
}
Write-Host ""
if ($Force) {
    $del = @($snapRows | Where-Object Outcome -eq 'deleted')
    $freed = [long](($del | Measure-Object Bytes -Sum).Sum)
    if ($pluginOut) { $freed += [long]((@($pluginOut.Removed) | Measure-Object SizeBytes -Sum).Sum) }
    Write-Host ("  Liberados {0}: {1} copia(s) de transcripts, {2} version(es) de plugins; estado temporal del repo limpiado." -f (& $mb $freed), $del.Count, $(if ($pluginOut) { @($pluginOut.Removed).Count } else { 0 })) -ForegroundColor Green
    foreach ($f in @($snapRows | Where-Object { $_.Outcome -like 'failed*' })) { Write-Host "  NO  $($f.Path): $($f.Outcome)" -ForegroundColor Yellow }
    if ($pluginOut) { foreach ($f in @($pluginOut.Failed)) { Write-Host "  NO  $($f.Path): $($f.FailReason)" -ForegroundColor Yellow } }
} else {
    Write-Host ("  Con -Force se liberarian unos {0} (copias + plugins). Los transcripts van aparte." -f (& $mb ($snapDelBytes + $plugBytes))) -ForegroundColor Yellow
}
Write-Host ""
exit 0
