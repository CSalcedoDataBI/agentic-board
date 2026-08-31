<#  Backup-Board.ps1 - make a COMPLETE backup of a Projects board. ALWAYS run before delete.
    Writes a JSON snapshot (project meta + fields + items) AND creates a restorable live clone.
    Requires $env:GH_TOKEN (via gh-account). Backups go to $env:ABIOS_BACKUP_DIR or ~/.agentic-board/backups.
    Usage: ./Backup-Board.ps1 -Number 13 -Owner CSalcedoDataBI
    NOTE: source is pure ASCII; the em-dash is built at runtime for Windows PowerShell 5.1 safety.  #>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$Number,
  [Parameter(Mandatory)][string]$Owner,
  [string]$BackupDir
)
$ErrorActionPreference = 'Stop'
$dash = [char]0x2014
# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
# gh fails by exit code only, and a native command exiting non-zero does not throw (#303).
# This script is the LAST line of defence before a delete, so it must never mistake a 401
# for an empty board and write a plausible-looking empty snapshot.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# ...nor mistake a CAPPED read for a whole board and write a plausible-looking PARTIAL one (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')
if (-not $BackupDir) {
  $BackupDir = if ($env:ABIOS_BACKUP_DIR) { $env:ABIOS_BACKUP_DIR } else { Join-Path (Get-AbiosStateDir -Root $HOME) 'backups' }
}
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

# Read everything first, and only then write, so a failure on the third read cannot leave
# two files behind that look like a partial backup nobody labelled as one.
#
# -RawJson validates the body as JSON but hands back gh's text instead of a parsed object:
# the snapshot must not be re-serialised, because ConvertTo-Json would reshape it and -Depth
# would quietly truncate it. It is NOT byte-for-byte gh output - PowerShell has already split
# stdout into lines and dropped the terminators before any of this runs - but it is
# unreshaped and untruncated, which is what a restorable backup actually needs.
$meta   = Invoke-Gh -GhArgs @('project', 'view',       "$Number", '--owner', $Owner, '--format', 'json') `
                    -What "leer el board #$Number de $Owner" -RawJson -Retries 2
$fields = Invoke-Gh -GhArgs @('project', 'field-list', "$Number", '--owner', $Owner, '--format', 'json') `
                    -What "leer los campos del board #$Number" -RawJson -Retries 2
$itemLimit = Get-BoardItemReadLimit
$items  = Invoke-Gh -GhArgs @('project', 'item-list',  "$Number", '--owner', $Owner, '--format', 'json', '--limit', "$itemLimit") `
                    -What "leer los items del board #$Number" -RawJson -Retries 2

$title  = ($meta | ConvertFrom-Json).title
if (-not $title) { throw "El board #$Number no devolvio un titulo - no hago un backup de algo que no pude leer." }

# This snapshot is the safety net taken BEFORE a destructive board operation, so a partial one is
# worse than none: it would license the delete it exists to make reversible. A read that stopped at
# the cap cannot be called a backup, so refuse to write one (#484). Checked on the raw text rather
# than through Get-BoardItems because the snapshot must keep gh's own bytes unreshaped.
$itemCount = @(($items | ConvertFrom-Json).items | Where-Object { $null -ne $_ }).Count
if ($itemCount -ge $itemLimit) {
    throw "No escribo el backup del board #$Number - la lectura de items se corto en $itemCount (el tope de lectura), y un backup parcial no es un backup."
}
$safe   = ($title -replace '[^\w\-]+', '_').Trim('_')
$base   = Join-Path $BackupDir ("{0}_{1}" -f $safe, $stamp)

# WriteAllText, not Out-File: Out-File -Encoding UTF8 writes a BOM on Windows PowerShell 5.1
# (which this script supports - see the header) and none on pwsh 7, so the same backup came
# out different depending on the host. A snapshot's encoding should not depend on who ran it.
$snapshotFiles = @{ "$base.project.json" = $meta; "$base.fields.json" = $fields; "$base.items.json" = $items }
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($f in $snapshotFiles.Keys) { [System.IO.File]::WriteAllText($f, $snapshotFiles[$f], $utf8NoBom) }

# Verify what was WRITTEN, not what we meant to write - by READING IT BACK and parsing it.
# A size check would be theatre: Invoke-Gh -RawJson already refused an empty body, so a
# zero-byte file was never reachable. What this catches is the write itself going wrong
# (truncation, a mangled encoding) - the failure a backup can only reveal on restore day.
foreach ($f in $snapshotFiles.Keys) {
    if (-not (Test-Path $f)) { throw "El backup no se escribio: $f" }
    try   { $null = (Get-Content $f -Raw) | ConvertFrom-Json }
    catch { throw "El backup quedo ilegible (no parsea como JSON): $f" }
}

# restorable live clone (fields/views + draft issues)
$cloneTitle = "$title $dash backup $stamp"
try {
    Invoke-Gh -GhArgs @('project', 'copy', "$Number", '--source-owner', $Owner, '--target-owner', $Owner, '--drafts', '--title', $cloneTitle) `
              -What "clonar el board #$Number" -Retries 2 | Out-Null
} catch {
    # The snapshot is already on disk and is perfectly good. Dying here without saying so
    # would leave three valid files the caller believes do not exist - so they either re-run
    # and pile up duplicate snapshots, or assume they have no backup at all. Report what
    # exists, report what failed, and still fail: the header promises BOTH halves.
    Write-Host "Backup PARCIAL:" -ForegroundColor Yellow
    Write-Host ("  JSON snapshot OK : {0}.project.json (+ .fields.json, .items.json)" -f $base) -ForegroundColor Yellow
    Write-Host  "  Live clone FALLO : el snapshot JSON sirve para restaurar; el clon vivo no se creo." -ForegroundColor Yellow
    throw
}

Write-Host "Backup OK:"
Write-Host ("  JSON snapshot: {0}.project.json (+ .fields.json, .items.json)" -f $base)
Write-Host ("  Live clone   : '{0}' in projects of {1}" -f $cloneTitle, $Owner)
