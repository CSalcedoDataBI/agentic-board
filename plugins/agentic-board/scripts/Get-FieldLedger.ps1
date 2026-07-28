<#
.SYNOPSIS
    Ledger and incremental watermark for /board telemetry — the field-observation sweep.

.DESCRIPTION
    Discovers local session transcripts and decides which ones still need reading. The unit of
    incrementality is a WATERMARK (events + bytes already processed), never a boolean "scanned"
    flag: sessions keep growing, so a flag would retire a session permanently the first time it is
    read and silently lose everything appended afterwards.

    This script is READ-ONLY over the transcript store. It never writes into
    ~/.claude/projects — that store is the only copy of the evidence. Its own outputs go to the
    field root, which is machine-level and never versioned.

    Pure core behind $env:ABIOS_FIELDLEDGER_DOTSOURCE for unit tests; the CLI walks the real store.

.EXAMPLE
    . .\Get-FieldLedger.ps1 ; Select-SessionsToScan -Disk $d -Ledger $l
#>
[CmdletBinding()]
param(
    [string]$FieldRoot,
    [string]$ProjectsRoot,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ── Pure core ───────────────────────────────────────────────────────────────────

$script:LedgerColumns = @('sessionId','project','title','events','bytes','scannedAt','usedTool','incidents')

function Get-LedgerKey {
    # A session id is unique per project directory, not globally: worktrees and re-clones reuse ids.
    [CmdletBinding()]
    param([string]$Project, [string]$SessionId)
    "$Project/$SessionId"
}

function Select-SessionsToScan {
    <#  Returns one entry per session still owing work, each carrying `fromEvent` — the index the
        reader must resume at. Skipping too much and skipping too little are equally broken, so
        both directions are pinned by tests. #>
    [CmdletBinding()]
    param([object[]]$Disk, [object[]]$Ledger)

    $seen = @{}
    foreach ($row in @($Ledger)) {
        if (-not $row) { continue }
        $seen[(Get-LedgerKey -Project $row.project -SessionId $row.sessionId)] = $row
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Disk)) {
        if (-not $d) { continue }
        $prev = $seen[(Get-LedgerKey -Project $d.project -SessionId $d.sessionId)]

        if (-not $prev) {
            $out.Add([pscustomobject]@{ sessionId=$d.sessionId; project=$d.project; fromEvent=0; events=$d.events; bytes=$d.bytes })
            continue
        }

        $prevEvents = [int]$prev.events
        $prevBytes  = [long]$prev.bytes
        $nowEvents  = [int]$d.events
        $nowBytes   = [long]$d.bytes

        # Unchanged on both axes — nothing to do. This is the common case on a re-run.
        if ($nowEvents -eq $prevEvents -and $nowBytes -eq $prevBytes) { continue }

        # Shrunk: the file was rotated or rewritten, so the old watermark describes content that no
        # longer exists. Resuming from it would skip real events; start over.
        $from = if ($nowEvents -lt $prevEvents -or $nowBytes -lt $prevBytes) { 0 } else { $prevEvents }

        $out.Add([pscustomobject]@{ sessionId=$d.sessionId; project=$d.project; fromEvent=$from; events=$nowEvents; bytes=$nowBytes })
    }
    $out.ToArray()
}

function Update-LedgerRow {
    <#  Advances the watermark for one session. Called only AFTER the events were successfully
        processed — a watermark written before the work is a gate that passes for the wrong
        reason. #>
    [CmdletBinding()]
    param(
        [object[]]$Ledger,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Project,
        [int]$Events, [long]$Bytes, [int]$Incidents,
        [string]$UsedTool = 'no',
        [Parameter(Mandatory)][string]$ScannedAt
    )
    $key = Get-LedgerKey -Project $Project -SessionId $SessionId
    $out = [System.Collections.Generic.List[object]]::new()
    $found = $false

    foreach ($row in @($Ledger)) {
        if (-not $row) { continue }
        if ((Get-LedgerKey -Project $row.project -SessionId $row.sessionId) -eq $key) {
            $found = $true
            $out.Add([pscustomobject]@{
                sessionId = $SessionId; project = $Project; title = $row.title
                events = $Events; bytes = $Bytes; scannedAt = $ScannedAt
                usedTool = $UsedTool; incidents = $Incidents })
        } else {
            $out.Add($row)
        }
    }
    if (-not $found) {
        $out.Add([pscustomobject]@{
            sessionId = $SessionId; project = $Project; title = ''
            events = $Events; bytes = $Bytes; scannedAt = $ScannedAt
            usedTool = $UsedTool; incidents = $Incidents })
    }
    $out.ToArray()
}

# ── Field root + ledger IO (touches the filesystem; kept out of the pure core) ──

function Get-FieldRoot {
    [CmdletBinding()]
    param([string]$Override)
    if ($Override) { return $Override }
    if ($env:ABIOS_FIELD_ROOT) { return $env:ABIOS_FIELD_ROOT }
    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    Join-Path $userHome '.claude/agentic-board-field'
}

function Get-TranscriptRoot {
    [CmdletBinding()]
    param([string]$Override)
    if ($Override) { return $Override }
    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    Join-Path $userHome '.claude/projects'
}

function Read-FieldLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Import-Csv -LiteralPath $Path)
}

function Write-FieldLedger {
    <#  Atomic: an interrupted sweep must not leave a truncated ledger, or the next run would
        re-read everything and report it as new. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [object[]]$Ledger)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    @($Ledger) | Select-Object $script:LedgerColumns | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    $Path
}

function Get-DiskSessions {
    <#  READ-ONLY walk of the transcript store. Counting lines is the cheapest honest proxy for
        "how many events" without parsing 571 MB of JSON. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue) {
        $count = 0
        try {
            $reader = [System.IO.File]::OpenText($f.FullName)
            try { while ($null -ne $reader.ReadLine()) { $count++ } } finally { $reader.Dispose() }
        } catch { continue }
        $out.Add([pscustomobject]@{
            sessionId = $f.BaseName
            project   = $f.Directory.Name
            path      = $f.FullName
            events    = $count
            bytes     = $f.Length
        })
    }
    $out.ToArray()
}

# Dot-source guard: tests load the pure core only.
if ($env:ABIOS_FIELDLEDGER_DOTSOURCE) { return }

# ── CLI: report what the next sweep would read ──────────────────────────────────
$root       = Get-FieldRoot -Override $FieldRoot
$transcript = Get-TranscriptRoot -Override $ProjectsRoot
$ledgerPath = Join-Path $root 'ledger.csv'

$disk    = Get-DiskSessions -Root $transcript
$ledger  = Read-FieldLedger -Path $ledgerPath
$pending = Select-SessionsToScan -Disk $disk -Ledger $ledger

$summary = [pscustomobject]@{
    fieldRoot      = $root
    transcriptRoot = $transcript
    ledger         = $ledgerPath
    sessionsOnDisk = @($disk).Count
    sessionsKnown  = @($ledger).Count
    pending        = @($pending).Count
    newEvents      = (@($pending) | Measure-Object -Property events -Sum).Sum - (@($pending) | Measure-Object -Property fromEvent -Sum).Sum
}

if ($Json) { $summary | ConvertTo-Json -Depth 4 } else { $summary }
