<#
.SYNOPSIS
    Create native "blocked by" dependencies between issues - and check they landed on the RIGHT issue (#521).

.DESCRIPTION
    `/board work -Start` READS native blocked-by dependencies (it refuses an issue with open
    blockers), but nothing in the tool WROTE them, so the ordering a plan encodes was lost the
    moment it reached the board. An agent without a script falls back to the raw endpoint, and
    that endpoint has a trap:

        POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by     body {"issue_id": N}

    `issue_id` is the issue's DATABASE id, not its number. Passing the NUMBER does not fail: it
    returns 200 and links whatever issue anywhere on GitHub carries that database id. Observed
    on a real run: `{"issue_id": 17}` linked `jbarnette/johnson#3`, an unrelated public repository,
    while the other calls in the batch returned 404 - a partial success nobody would notice.

    So this script never trusts a write:

      1. Resolves each blocker NUMBER to its database id first (`GET issues/{n}`), and only ever
         sends that id. It also checks the answer: the number, the repository and the fact that it
         is an issue (not a pull request) must be what was asked for.
      2. REFUSES anything that is not in the target repository - `owner/repo#N` and issue URLs of
         another repo are rejected before a single write, because the accidental case is always
         cross-repo. All references are validated up front: a bad one blocks the whole batch.
      3. Reads the dependency list BEFORE and AFTER the write and compares them. The requested
         blocker must have appeared with the right number AND the right repository, and NOTHING
         else may have appeared. A link that did not stick, or a stranger that did, is an error
         (exit 1), never a success. It stops at the first failure: after an unexplained link,
         more writes would only compound it.
      4. Is idempotent: a blocker that is already linked is reported as such (and its repository
         is still checked) without another POST.

    Wiring this into `/board plan` so a plan's ordering is encoded when the issues are created is a
    follow-up; this is the checked primitive that wiring will call.

.PARAMETER Repo
    owner/name. Default: derived from the origin remote.

.PARAMETER Issue
    The issue that is BLOCKED (the one that must wait).

.PARAMETER BlockedBy
    One or more blockers, as numbers (`12`, `#12`) - `owner/repo#12` and issue URLs are accepted
    ONLY when they name -Repo itself.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default: resolved from the repo owner (and forced to the
    agent identity inside a brake-armed run), like New-BoardPR.ps1.

.PARAMETER DryRun
    Resolve and validate everything, write nothing.

.EXAMPLE
    .\Board-Depend.ps1 -Issue 40 -BlockedBy 36,37,38
    .\Board-Depend.ps1 -Repo CSalcedoDataBI/agentic-board -Issue 40 -BlockedBy '#36' -DryRun
#>
[CmdletBinding()]
param(
    [string]  $Repo     = '',
    [int]     $Issue    = 0,
    [string[]]$BlockedBy = @(),
    [string]  $TokenVar = '',
    [switch]  $DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# ── Pure + gh-through-the-wrapper core ─────────────────────────────────────────

# One blocker reference -> its issue number, refusing any other repository. Pure.
# Accepts: 12, #12, owner/name#12, https://github.com/owner/name/issues/12
function ConvertTo-DependencyNumber {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$TargetRepo)
    $r = $Ref.Trim()
    $other = $null; $num = $null
    if ($r -match '^#?(\d+)$') {
        $num = [int]$Matches[1]
    } elseif ($r -match '^([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)#(\d+)$') {
        $other = $Matches[1]; $num = [int]$Matches[2]
    } elseif ($r -match '^https?://github\.com/([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+)/issues/(\d+)/?$') {
        $other = $Matches[1]; $num = [int]$Matches[2]
    } else {
        throw "Referencia de bloqueador no valida: '$Ref'. Usa un numero (12 o #12)."
    }
    if ($num -le 0) { throw "Numero de issue no valido en '$Ref'." }
    if ($other -and ($other -ne $TargetRepo)) {
        throw ("'$Ref' es de OTRO repositorio ($other), no de $TargetRepo. Un bloqueador de otro repo es " +
               "justo el caso accidental que este script existe para impedir (#521): no se crea.")
    }
    return $num
}

# 'owner/name' of a dependency/issue object, from repository_url (always present on the REST issue
# shape) or repository.full_name. '' when neither says - and then the caller must NOT assume. Pure.
function Get-DependencyRepo {
    param($Entry)
    $url = "$($Entry.repository_url)"
    if ($url -match '/repos/([^/]+/[^/]+)/?$') { return $Matches[1] }
    if ($Entry.PSObject.Properties.Name -contains 'repository' -and $Entry.repository -and $Entry.repository.full_name) {
        return "$($Entry.repository.full_name)"
    }
    return ''
}

# Normalise an API issue object to the four things this script compares. Pure.
function ConvertTo-DependencyEntry {
    param($Raw)
    [pscustomobject]@{
        id     = if ($Raw.id) { [long]$Raw.id } else { 0 }
        number = if ($Raw.number) { [int]$Raw.number } else { 0 }
        repo   = (Get-DependencyRepo -Entry $Raw)
        state  = "$($Raw.state)"
        title  = "$($Raw.title)"
        isPr   = [bool]($Raw.PSObject.Properties.Name -contains 'pull_request' -and $Raw.pull_request)
    }
}

# Resolve number -> the issue's identity, and CHECK the answer is what was asked for. gh (through
# Invoke-Gh) throws on a 404, so a number that does not exist is an error here, not $null.
function Get-DependencyIssue {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Number)
    $raw = Invoke-Gh -GhArgs @('api', "repos/$Repo/issues/$Number") -What "leer el issue #$Number de $Repo" -Json
    $e = ConvertTo-DependencyEntry -Raw $raw
    if ($e.id -le 0)          { throw "GitHub no devolvio un id de base de datos para $Repo#$Number." }
    if ($e.number -ne $Number) { throw "Pedi $Repo#$Number y GitHub devolvio el issue #$($e.number)." }
    if (-not $e.repo)         { throw "No puedo comprobar a que repositorio pertenece $Repo#$Number (la respuesta no lo dice)." }
    if ($e.repo -ne $Repo)    { throw "Pedi $Repo#$Number y GitHub lo resuelve a $($e.repo)#$($e.number)." }
    if ($e.isPr)              { throw "$Repo#$Number es un pull request, no un issue: no puede ser parte de una dependencia." }
    return $e
}

# The current blocked-by list of an issue, normalised. One page of 100: a list that FILLS the page
# cannot be verified (a link could be on page 2), so it fails instead of guessing.
function Get-BlockedByList {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Issue)
    $raw = Invoke-Gh -GhArgs @('api', "repos/$Repo/issues/$Issue/dependencies/blocked_by?per_page=100") `
                     -What "leer los bloqueadores de $Repo#$Issue" -Json
    $items = @($raw | Where-Object { $_ })
    if ($items.Count -ge 100) { throw "$Repo#$Issue ya tiene 100 o mas bloqueadores: no puedo verificar el resultado en una sola pagina." }
    return @($items | ForEach-Object { ConvertTo-DependencyEntry -Raw $_ })
}

# Did the write do EXACTLY what was asked? Pure: compares the list before and after.
#   Target = the blocker as resolved (id, number, repo)
# Returns @{ ok; already; reason; strangers }.
function Test-DependencyLanded {
    param($Before, $After, [Parameter(Mandatory)]$Target)
    $prior = @($Before | Where-Object { $_ })
    $now   = @($After  | Where-Object { $_ })
    $priorIds = @($prior | ForEach-Object { $_.id })

    $match    = @($now | Where-Object { $_.id -eq $Target.id })
    $wasThere = @($prior | Where-Object { $_.id -eq $Target.id }).Count -gt 0

    $strangers = @($now | Where-Object { $priorIds -notcontains $_.id -and $_.id -ne $Target.id })
    if ($strangers.Count -gt 0) {
        $names = ($strangers | ForEach-Object { "$(if ($_.repo) { $_.repo } else { '?' })#$($_.number)" }) -join ', '
        return @{ ok = $false; already = $false; strangers = $strangers
                  reason = "aparecio un bloqueador que NO se pidio: $names. GitHub enlazo otro issue." }
    }
    if ($match.Count -eq 0) {
        return @{ ok = $false; already = $false; strangers = @()
                  reason = "el enlace NO quedo: $($Target.repo)#$($Target.number) no aparece entre los bloqueadores tras escribir." }
    }
    $m = $match[0]
    if (-not $m.repo) {
        return @{ ok = $false; already = $wasThere; strangers = @()
                  reason = "no puedo comprobar el repositorio del bloqueador enlazado (la respuesta no lo dice); no lo doy por bueno." }
    }
    if ($m.repo -ne $Target.repo -or $m.number -ne $Target.number) {
        return @{ ok = $false; already = $wasThere; strangers = @()
                  reason = "el bloqueador enlazado es $($m.repo)#$($m.number), no $($Target.repo)#$($Target.number)." }
    }
    return @{ ok = $true; already = $wasThere; strangers = @(); reason = '' }
}

# The whole operation for one blocked issue and its blockers. Returns one result per blocker:
#   @{ Ref; Number; Status = linked | already | dry-run | FAILED | skipped; Message }
# Validates EVERYTHING before the first write; stops at the first failed write.
function Invoke-BoardDepend {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string[]]$BlockedBy,
        [switch]$DryRun
    )
    if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo debe ser owner/name (recibi '$Repo')." }
    if ($Issue -le 0)                    { throw 'Falta -Issue (el issue que queda bloqueado).' }
    $refs = @($BlockedBy | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($refs.Count -eq 0)               { throw 'Falta -BlockedBy (uno o mas bloqueadores).' }

    # 1. Validate every reference first: nothing is written if any of them is refused.
    $numbers = @()
    foreach ($ref in $refs) {
        $n = ConvertTo-DependencyNumber -Ref $ref -TargetRepo $Repo
        if ($n -eq $Issue) { throw "#$Issue no puede bloquearse a si mismo." }
        if ($numbers -notcontains $n) { $numbers += $n }
    }
    # 2. Resolve number -> database id (and verify the answers) before any write.
    $null = Get-DependencyIssue -Repo $Repo -Number $Issue
    $targets = @()
    foreach ($n in $numbers) { $targets += (Get-DependencyIssue -Repo $Repo -Number $n) }

    # 3. Write one at a time, verifying each against a before/after read.
    $results = @()
    $failed  = $false
    foreach ($t in $targets) {
        $ref = "#$($t.number)"
        if ($failed) { $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'skipped'; Message = 'no se intento: un enlace anterior fallo' }; continue }
        $before = Get-BlockedByList -Repo $Repo -Issue $Issue
        if (@($before | Where-Object { $_.id -eq $t.id }).Count -gt 0) {
            $chk = Test-DependencyLanded -Before $before -After $before -Target $t
            if ($chk.ok) { $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'already'; Message = 'ya estaba enlazado' } }
            else         { $failed = $true; $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'FAILED'; Message = $chk.reason } }
            continue
        }
        if ($DryRun) { $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'dry-run'; Message = "se enlazaria $Repo#$($t.number) (id $($t.id))" }; continue }

        try {
            # The database id - NEVER the number. It travels in the body, as an integer.
            $body = '{"issue_id":' + $t.id + '}'
            $null = Invoke-Gh -GhArgs @('api', '-X', 'POST', "repos/$Repo/issues/$Issue/dependencies/blocked_by", '--input', '-') `
                              -StdIn $body -What "enlazar $Repo#$($t.number) como bloqueador de #$Issue"
            $after = Get-BlockedByList -Repo $Repo -Issue $Issue
            $chk = Test-DependencyLanded -Before $before -After $after -Target $t
            if ($chk.ok) { $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'linked'; Message = 'enlazado y verificado' } }
            else         { $failed = $true; $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'FAILED'; Message = $chk.reason } }
        } catch {
            $failed = $true
            $results += [pscustomobject]@{ Ref = $ref; Number = $t.number; Status = 'FAILED'; Message = $_.Exception.Message }
        }
    }
    return $results
}

# Dot-source guard: tests load the functions above without touching gh, git or the registry.
if ($env:ABIOS_BOARDDEPEND_DOTSOURCE) { return }

# ── Main ───────────────────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
if (-not $Repo) { $Repo = Get-RepoFromOrigin }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo debe ser owner/name (recibi '$Repo')." }
$owner = ($Repo -split '/')[0]

# Identity: the owner's account, or the AGENT's inside a braked run, decided by the one resolver
# (same path as New-BoardPR; an explicit -TokenVar is judged, not honoured blindly).
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
$ctx = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner $owner -ExplicitVar $TokenVar
$env:GH_TOKEN = $ctx.token

Write-Host "=== Board-Depend  $Repo  #$Issue ===" -ForegroundColor Cyan
Write-Host "  Identidad: $($ctx.var)$(if ($DryRun) { '  [dry-run]' })"

$results = Invoke-BoardDepend -Repo $Repo -Issue $Issue -BlockedBy $BlockedBy -DryRun:$DryRun
foreach ($r in $results) {
    $color = switch ($r.Status) { 'linked' { 'Green' } 'already' { 'Green' } 'dry-run' { 'DarkGray' } 'skipped' { 'DarkYellow' } default { 'Red' } }
    Write-Host ("  {0,-8} {1}  {2}" -f $r.Status, $r.Ref, $r.Message) -ForegroundColor $color
}
if (@($results | Where-Object { $_.Status -eq 'FAILED' }).Count -gt 0) {
    Write-Host "FALLO: al menos un enlace no se pudo verificar. Revisa la lista de bloqueadores del issue antes de seguir." -ForegroundColor Red
    exit 1
}
exit 0
