<#
.SYNOPSIS
    /cleanup transcripts: compress old session transcripts into an indexed archive, and restore
    them byte for byte (#736).

.DESCRIPTION
    Every Claude Code session writes ~/.claude/projects/<project>/<sessionId>.jsonl, plus a
    companion <sessionId>/ folder (tool results, subagents). Nothing ever removes them, so they
    fill the disk - measured on the reporter's machine on 2026-09-29: 2.8 GB in ~3000 files.

    This moves the OLD ones into <ArchiveDir>/<project>/<sessionId>.zip and records each in
    <ArchiveDir>/index.jsonl (session, folder, branch, issue, title, first/last activity, sizes,
    SHA-256). `-Restore <sessionId>` puts one back exactly where it was.

    What may be compressed (Get-TranscriptVerdict), all of it required:
      * older than -OlderThanDays (default 30) by its last write;
      * not the transcript of a running session (~/.claude/sessions, process + start time);
      * NOT a session the desktop app still shows. The app keeps one metadata file per session
        (claude-code-sessions/.../local_*.json, read-only here) naming its `cliSessionId` and
        whether it `isArchived`. A transcript whose app session is not archived is never touched:
        the sidebar would keep a session that no longer opens. Archive the session first
        (`/cleanup sessions`), or restore it later with -Restore.

    The original is deleted only after the zip has been read back and its transcript hashes to
    the same SHA-256. Plan only by default; -Force compresses.

.PARAMETER OlderThanDays
    Minimum age, by last write. Default 30.

.PARAMETER Force
    Compress. Without it nothing is written - the plan shows what each threshold would free.

.PARAMETER Restore
    Restore these session ids from the archive to their original place.

.PARAMETER Find
    List archived transcripts whose title, folder or branch contains this text.

.PARAMETER ArchiveDir
    Where the archive lives. Default ~/.claude/transcript-archive. Can be another drive.

.PARAMETER ClaudeHome
    The Claude home (default ~/.claude, or CLAUDE_CONFIG_DIR).

.PARAMETER AppSessionsDir
    The desktop app's session metadata folder. Default %APPDATA%\Claude\claude-code-sessions.

.PARAMETER Json
    Emit the plan / outcome as JSON.

.EXAMPLE
    .\Cleanup-Transcripts.ps1                      # plan: what would be compressed, and how much it frees
    .\Cleanup-Transcripts.ps1 -Force               # compress the eligible ones (30 days and older)
    .\Cleanup-Transcripts.ps1 -OlderThanDays 14 -Force
    .\Cleanup-Transcripts.ps1 -Find "fabric-apps"  # search the archive
    .\Cleanup-Transcripts.ps1 -Restore 06f53bb7-b5eb-49fd-a3f8-8fa4cbee130b
#>
[CmdletBinding()]
param(
    [int]     $OlderThanDays  = 30,
    [switch]  $Force,
    [string[]]$Restore        = @(),
    [string]  $Find           = "",
    [string]  $ArchiveDir     = "",
    [string]  $ClaudeHome     = "",
    [string]  $AppSessionsDir = "",
    [switch]  $Json
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ------------------------------------------------------------------ pure helpers

# May this transcript be compressed? PURE. Returns { Archive; Reason }.
#   $Transcript      - { SessionId; LastWriteUtc; Bytes; Entrypoint }
#   $LiveIds         - session ids of running (or not provably dead) sessions
#   $AppSessions     - cliSessionId -> { IsArchived; Title } from the desktop app's metadata
#   $AppIndexComplete- every app metadata file was readable; if not, an unmapped desktop
#                      transcript might belong to one of the unreadable ones -> keep it
function Get-TranscriptVerdict {
    param(
        $Transcript,
        [datetime]$Now = (Get-Date).ToUniversalTime(),
        [int]$OlderThanDays = 30,
        [string[]]$LiveIds = @(),
        [hashtable]$AppSessions = @{},
        [bool]$AppIndexComplete = $true
    )
    $mk = { param($ok, $why) [pscustomobject]@{ Archive = $ok; Reason = $why } }
    $id = "$($Transcript.SessionId)"
    if ($LiveIds -contains $id) { return (& $mk $false 'its session is running') }
    $age = ($Now - $Transcript.LastWriteUtc).TotalDays
    if ($age -lt $OlderThanDays) { return (& $mk $false ("recent ({0} of {1} day(s))" -f [int][math]::Floor($age), $OlderThanDays)) }
    if ($AppSessions.ContainsKey($id)) {
        $a = $AppSessions[$id]
        if (-not $a.IsArchived) { return (& $mk $false "still listed in the app ('$($a.Title)') - archive that session first, or it would no longer open") }
        return (& $mk $true ("archived in the app, idle {0} day(s)" -f [int]$age))
    }
    if ("$($Transcript.Entrypoint)" -like 'claude-desktop*' -and -not $AppIndexComplete) {
        return (& $mk $false 'an app session I could not map (some app metadata files were unreadable) - kept to be safe')
    }
    return (& $mk $true ("not an app session the app still holds, idle {0} day(s)" -f [int]$age))
}

# The branch-to-issue convention of this suite: issue-<n>-<slug>.
function Get-IssueFromBranch([string]$Branch) {
    if ($Branch -match '^issue-(\d+)') { return [int]$Matches[1] }
    return 0
}

# What the index remembers, from the first and last lines of a transcript (a transcript can be
# tens of MB; reading it whole to fill an index row is not worth it). PURE over the lines.
function Get-TranscriptMeta {
    param([string[]]$Head = @(), [string[]]$Tail = @())
    $cwd = ''; $branch = ''; $entry = ''; $title = ''; $first = ''; $last = ''
    foreach ($l in $Head) {
        $j = $null; try { $j = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $first -and $j.timestamp) { $first = "$(ConvertTo-IsoText $j.timestamp)" }
        if (-not $cwd -and $j.cwd) { $cwd = "$($j.cwd)" }
        if (-not $branch -and $j.gitBranch) { $branch = "$($j.gitBranch)" }
        if (-not $entry -and $j.entrypoint) { $entry = "$($j.entrypoint)" }
        if ($j.customTitle) { $title = "$($j.customTitle)" }
    }
    foreach ($l in $Tail) {
        $j = $null; try { $j = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($j.timestamp) { $last = "$(ConvertTo-IsoText $j.timestamp)" }
        if ($j.customTitle) { $title = "$($j.customTitle)" }
        if (-not $cwd -and $j.cwd) { $cwd = "$($j.cwd)" }
        if (-not $branch -and $j.gitBranch) { $branch = "$($j.gitBranch)" }
    }
    [pscustomobject]@{
        Cwd = $cwd; GitBranch = $branch; Issue = (Get-IssueFromBranch $branch); Entrypoint = $entry
        Title = $title; FirstTs = $first; LastTs = $last
    }
}

# ConvertFrom-Json turns ISO strings into DateTime; stringifying that uses the current culture
# (es-CO: day first). Always write the index in ISO 8601 UTC.
function ConvertTo-IsoText($Value) {
    if ($Value -is [datetime]) {
        $d = if ($Value.Kind -eq 'Unspecified') { [datetime]::SpecifyKind($Value, 'Utc') } else { $Value.ToUniversalTime() }
        return $d.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
    }
    return "$Value"
}

# How much each age threshold would free, counting only what is eligible besides its age. PURE.
#   $Rows - { Days; Bytes; Blocked }  (Blocked = kept for a reason other than age)
function Get-ThresholdSavings {
    param([object[]]$Rows = @(), [int[]]$Days = @(7, 14, 30, 60))
    foreach ($d in $Days) {
        $sel = @($Rows | Where-Object { -not $_.Blocked -and $_.Days -ge $d })
        [pscustomobject]@{ Days = $d; Count = $sel.Count; Bytes = [long](($sel | Measure-Object Bytes -Sum).Sum) }
    }
}

# SHA-256 of the transcript entry inside a zip, read back from the zip itself.
function Get-ZipEntrySha256 {
    param([string]$ZipPath, [string]$EntryName)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = $zip.GetEntry($EntryName)
        if (-not $e) { return '' }
        $s = $e.Open()
        try { return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($s))).Replace('-', '') }
        finally { $s.Dispose() }
    } finally { $zip.Dispose() }
}

# Zip one transcript (+ its companion folder), verify, then delete the originals. Returns
# { Ok; ZipPath; Sha256; ZipBytes; OrigBytes; Error }. Nothing is deleted unless the transcript
# read back from the zip hashes the same as the original. -VerifyHook replaces the read-back
# (tests use it to simulate a corrupt archive).
function Compress-Transcript {
    param([string]$JsonlPath, [string]$ArchiveDir, $Meta, [scriptblock]$VerifyHook = $null)
    $fail = { param($why) [pscustomobject]@{ Ok = $false; ZipPath = ''; Sha256 = ''; ZipBytes = 0; OrigBytes = 0; Error = $why } }
    try {
        $item = Get-Item -LiteralPath $JsonlPath
        $id = $item.BaseName
        $projDir = $item.Directory
        $companion = Join-Path $projDir.FullName $id
        $destDir = Join-Path $ArchiveDir $projDir.Name
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        $zipPath = Join-Path $destDir "$id.zip"
        if (Test-Path -LiteralPath $zipPath) { return (& $fail "an archive for $id already exists - restore or remove it first") }
        $sha = (Get-FileHash -LiteralPath $JsonlPath -Algorithm SHA256).Hash
        $orig = $item.Length
        $files = @()
        if (Test-Path -LiteralPath $companion -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $companion -Recurse -File -Force)
            $orig += [long](($files | Measure-Object Length -Sum).Sum)
        }
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $JsonlPath, "$id.jsonl", 'Optimal')
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($projDir.FullName.Length + 1).Replace('\', '/')
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, 'Optimal')
            }
        } finally { $zip.Dispose() }

        $back = if ($VerifyHook) { & $VerifyHook $zipPath } else { Get-ZipEntrySha256 -ZipPath $zipPath -EntryName "$id.jsonl" }
        $count = 0
        $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath); try { $count = $z.Entries.Count } finally { $z.Dispose() }
        if ($back -ne $sha -or $count -ne (1 + $files.Count)) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return (& $fail 'the archive did not read back identical - original kept')
        }
        Remove-Item -LiteralPath $JsonlPath -Force
        if (Test-Path -LiteralPath $companion) { Remove-Item -LiteralPath $companion -Recurse -Force }
        return [pscustomobject]@{ Ok = $true; ZipPath = $zipPath; Sha256 = $sha; ZipBytes = (Get-Item -LiteralPath $zipPath).Length; OrigBytes = $orig; Error = '' }
    } catch { return (& $fail "$($_.Exception.Message)") }
}

# Put one transcript back where it was, verify it, then drop the zip. Refuses to overwrite a
# transcript that exists again at that path (the session may have been resumed and written to).
function Restore-Transcript {
    param([string]$ZipPath, [string]$JsonlPath, [string]$Sha256)
    $fail = { param($why) [pscustomobject]@{ Ok = $false; Error = $why } }
    try {
        if (-not (Test-Path -LiteralPath $ZipPath)) { return (& $fail "archive not found: $ZipPath") }
        if (Test-Path -LiteralPath $JsonlPath) { return (& $fail "a transcript already exists at $JsonlPath - not overwritten") }
        $projDir = Split-Path -Parent $JsonlPath
        New-Item -ItemType Directory -Force -Path $projDir | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($e in $zip.Entries) {
                $target = [IO.Path]::GetFullPath((Join-Path $projDir $e.FullName))
                if (-not $target.StartsWith([IO.Path]::GetFullPath($projDir))) { throw "unsafe path in archive: $($e.FullName)" }
                if (Test-Path -LiteralPath $target) { throw "a file already exists at $target - not overwritten" }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target)
            }
        } finally { $zip.Dispose() }
        $now = (Get-FileHash -LiteralPath $JsonlPath -Algorithm SHA256).Hash
        if ($Sha256 -and $now -ne $Sha256) { return (& $fail 'the restored transcript does not match its recorded SHA-256 - archive kept') }
        Remove-Item -LiteralPath $ZipPath -Force
        return [pscustomobject]@{ Ok = $true; Error = '' }
    } catch { return (& $fail "$($_.Exception.Message)") }
}

# Dot-source guard: with $env:ABIOS_TRANSCRIPTS_DOTSOURCE set, stop after the pure helpers.
if ($env:ABIOS_TRANSCRIPTS_DOTSOURCE) { return }

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
$projectsDir = Join-Path $home_ 'projects'
if (-not $ArchiveDir) { $ArchiveDir = Join-Path $home_ 'transcript-archive' }
if (-not $AppSessionsDir) { $AppSessionsDir = Join-Path $env:APPDATA 'Claude\claude-code-sessions' }
$indexPath = Join-Path $ArchiveDir 'index.jsonl'
$now = (Get-Date).ToUniversalTime()

function Read-ArchiveIndex {
    if (-not (Test-Path -LiteralPath $indexPath)) { return @() }
    @(Get-Content -LiteralPath $indexPath -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}
function Write-ArchiveIndex([object[]]$Rows) {
    New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
    $tmp = "$indexPath.tmp"
    [IO.File]::WriteAllLines($tmp, [string[]]@($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $indexPath -Force
}

# --- find ---------------------------------------------------------------------
if ($Find) {
    $hits = @(Read-ArchiveIndex | Where-Object { "$($_.title) $($_.cwd) $($_.gitBranch) $($_.sessionId)" -like "*$Find*" })
    if ($Json) { @($hits) | ConvertTo-Json -Depth 4; exit 0 }
    Write-Host "=== Archived transcripts matching '$Find' ($($hits.Count)) ===" -ForegroundColor Cyan
    foreach ($h in $hits) { Write-Host ("  {0}  {1,-40}  {2}  [{3}]" -f $h.sessionId, $h.title, $h.cwd, $h.lastTs) }
    if ($hits.Count) { Write-Host "  To restore one: /cleanup transcripts restore <sessionId>" -ForegroundColor DarkGray }
    exit 0
}

# --- restore ------------------------------------------------------------------
if ($Restore.Count -gt 0) {
    $idx = @(Read-ArchiveIndex)
    $out = @()
    foreach ($id in $Restore) {
        $row = @($idx | Where-Object sessionId -eq $id) | Select-Object -First 1
        if (-not $row) { $out += [pscustomobject]@{ SessionId = $id; Ok = $false; Error = 'not in the archive index' }; continue }
        $r = Restore-Transcript -ZipPath $row.zipPath -JsonlPath $row.originalPath -Sha256 $row.sha256
        if ($r.Ok) { $idx = @($idx | Where-Object sessionId -ne $id) }
        $out += [pscustomobject]@{ SessionId = $id; Ok = $r.Ok; Error = $r.Error; Path = $row.originalPath }
    }
    Write-ArchiveIndex $idx
    if ($Json) { @($out) | ConvertTo-Json -Depth 4; exit 0 }
    foreach ($o in $out) {
        if ($o.Ok) { Write-Host "  OK  restored $($o.SessionId) -> $($o.Path)" -ForegroundColor Green }
        else { Write-Host "  NO  $($o.SessionId): $($o.Error)" -ForegroundColor Yellow }
    }
    exit 0
}

# --- inventory ----------------------------------------------------------------
$liveIds = @()
foreach ($s in @((Read-ClaudeSessions -ClaudeHome $ClaudeHome).Sessions)) {
    # 'unknown' counts as live: a session we cannot prove dead keeps its transcript.
    if ((Get-HolderLiveness -ProcessId $s.Pid -StartFt $s.ProcStart) -ne 'dead') { $liveIds += $s.SessionId }
}

$app = @{}; $appBad = 0; $appSeen = 0
if (Test-Path -LiteralPath $AppSessionsDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $AppSessionsDir -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
        $appSeen++
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if ($j.cliSessionId) { $app["$($j.cliSessionId)"] = [pscustomobject]@{ IsArchived = [bool]$j.isArchived; Title = "$($j.title)"; HostId = "$($j.sessionId)" } }
        } catch { $appBad++ }
    }
}
$appComplete = ($appBad -eq 0)

$rows = @()
if (Test-Path -LiteralPath $projectsDir) {
    foreach ($pd in @(Get-ChildItem -LiteralPath $projectsDir -Directory)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pd.FullName -Filter '*.jsonl' -File)) {
            $companion = Join-Path $pd.FullName $f.BaseName
            $bytes = $f.Length
            if (Test-Path -LiteralPath $companion) { $bytes += [long]((Get-ChildItem -LiteralPath $companion -Recurse -File -Force | Measure-Object Length -Sum).Sum) }
            $head = @(Get-Content -LiteralPath $f.FullName -TotalCount 40 -Encoding utf8 -ErrorAction SilentlyContinue)
            $meta = Get-TranscriptMeta -Head $head -Tail @()
            $t = [pscustomobject]@{ SessionId = $f.BaseName; LastWriteUtc = $f.LastWriteTimeUtc; Bytes = $bytes; Entrypoint = $meta.Entrypoint }
            $v0 = Get-TranscriptVerdict -Transcript $t -Now $now -OlderThanDays 0 -LiveIds $liveIds -AppSessions $app -AppIndexComplete $appComplete
            $v = Get-TranscriptVerdict -Transcript $t -Now $now -OlderThanDays $OlderThanDays -LiveIds $liveIds -AppSessions $app -AppIndexComplete $appComplete
            $rows += [pscustomobject]@{
                Path = $f.FullName; Project = $pd.Name; SessionId = $f.BaseName; Bytes = $bytes
                Days = [int][math]::Floor(($now - $f.LastWriteTimeUtc).TotalDays)
                Archive = $v.Archive; Reason = $v.Reason; Blocked = (-not $v0.Archive); Meta = $meta
                AppTitle = $(if ($app.ContainsKey($f.BaseName)) { $app[$f.BaseName].Title } else { '' })
                HostId = $(if ($app.ContainsKey($f.BaseName)) { $app[$f.BaseName].HostId } else { '' })
            }
        }
    }
}
$eligible = @($rows | Where-Object Archive)
$savings = @(Get-ThresholdSavings -Rows $rows -Days @(7, 14, 30, 60, 90))

# --- compress -----------------------------------------------------------------
$done = @(); $failed = @()
if ($Force) {
    $idx = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (Read-ArchiveIndex)) { $idx.Add($r) }
    foreach ($r in $eligible) {
        $tail = @(Get-Content -LiteralPath $r.Path -Tail 40 -Encoding utf8 -ErrorAction SilentlyContinue)
        $head = @(Get-Content -LiteralPath $r.Path -TotalCount 40 -Encoding utf8 -ErrorAction SilentlyContinue)
        $m = Get-TranscriptMeta -Head $head -Tail $tail
        $c = Compress-Transcript -JsonlPath $r.Path -ArchiveDir $ArchiveDir -Meta $m
        if (-not $c.Ok) { $failed += [pscustomobject]@{ SessionId = $r.SessionId; Error = $c.Error }; continue }
        $idx.Add([pscustomobject]@{
            sessionId = $r.SessionId; project = $r.Project; originalPath = $r.Path; zipPath = $c.ZipPath
            title = $(if ($r.AppTitle) { $r.AppTitle } else { $m.Title }); hostSessionId = $r.HostId
            cwd = $m.Cwd; gitBranch = $m.GitBranch; issue = $m.Issue; entrypoint = $m.Entrypoint
            firstTs = $m.FirstTs; lastTs = $m.LastTs; origBytes = $c.OrigBytes; zipBytes = $c.ZipBytes
            sha256 = $c.Sha256; archivedAt = (ConvertTo-IsoText $now)
        })
        $done += $c
        # Written after every transcript, so an interrupted run never leaves a zip nobody indexed.
        Write-ArchiveIndex @($idx)
    }
}

# --- report -------------------------------------------------------------------
$mb = { param($b) "{0:N0} MB" -f ($b / 1MB) }
if ($Json) {
    [pscustomobject]@{
        executed = [bool]$Force; olderThanDays = $OlderThanDays; archiveDir = $ArchiveDir
        transcripts = $rows.Count; totalBytes = [long](($rows | Measure-Object Bytes -Sum).Sum)
        eligible = $eligible.Count; eligibleBytes = [long](($eligible | Measure-Object Bytes -Sum).Sum)
        thresholds = $savings; appSessionsRead = $appSeen; appSessionsUnreadable = $appBad
        kept = @($rows | Where-Object { -not $_.Archive } | Group-Object { $_.Reason -replace '\d+', 'N' -replace "\('.*'\)", "('...')" } | ForEach-Object { [pscustomobject]@{ reason = $_.Name; count = $_.Count } })
        compressed = $done.Count; freedBytes = [long](($done | Measure-Object OrigBytes -Sum).Sum) - [long](($done | Measure-Object ZipBytes -Sum).Sum)
        failed = @($failed)
    } | ConvertTo-Json -Depth 5
    exit 0
}

$mode = if ($Force) { 'EXECUTED' } else { 'PLAN - nothing changed' }
Write-Host ""
Write-Host "=== /cleanup transcripts  ($mode) ===" -ForegroundColor Cyan
Write-Host ("  {0} transcripts take {1}. Archive: {2}" -f $rows.Count, (& $mb (($rows | Measure-Object Bytes -Sum).Sum)), $ArchiveDir) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  What each age threshold would free (only what may be compressed):" -ForegroundColor Yellow
foreach ($s in $savings) {
    $mark = if ($s.Days -eq $OlderThanDays) { '  <- the current threshold' } else { '' }
    Write-Host ("    {0,3} days or older: {1,5} transcripts, {2}{3}" -f $s.Days, $s.Count, (& $mb $s.Bytes), $mark)
}
Write-Host ""
Write-Host "  Kept:" -ForegroundColor DarkGray
foreach ($g in @($rows | Where-Object { -not $_.Archive } | Group-Object { $_.Reason -replace '\d+', 'N' -replace "\('.*'\)", "('...')" } | Sort-Object Count -Descending)) {
    Write-Host ("    {0,5}  {1}" -f $g.Count, $g.Name) -ForegroundColor DarkGray
}
if ($appBad -gt 0) { Write-Host "    ($appBad app session file(s) unreadable: unmapped app sessions are kept)" -ForegroundColor DarkGray }
Write-Host ""
if ($Force) {
    $freed = [long](($done | Measure-Object OrigBytes -Sum).Sum) - [long](($done | Measure-Object ZipBytes -Sum).Sum)
    Write-Host ("  Compressed {0} transcripts; freed {1}." -f $done.Count, (& $mb $freed)) -ForegroundColor Green
    foreach ($f in $failed) { Write-Host "  NO  $($f.SessionId): $($f.Error)" -ForegroundColor Yellow }
    Write-Host "  Find one: /cleanup transcripts find <text>   Restore it: /cleanup transcripts restore <sessionId>" -ForegroundColor DarkGray
} else {
    Write-Host ("  At {0} days, {1} transcripts ({2}) would be compressed. Run with -Force to do it." -f $OlderThanDays, $eligible.Count, (& $mb (($eligible | Measure-Object Bytes -Sum).Sum))) -ForegroundColor Yellow
}
Write-Host ""
exit 0
