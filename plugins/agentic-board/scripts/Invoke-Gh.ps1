<#  Invoke-Gh.ps1 - run gh so that a failure is a FAILURE, not an empty result (#303).

    Why this exists. `gh` signals failure ONLY through its exit code, and a native command
    that exits non-zero does NOT throw in PowerShell - not even under
    $ErrorActionPreference = 'Stop', which governs cmdlets only. So this:

        $fields = (gh project field-list 13 --owner x --format json | ConvertFrom-Json).fields

    turns a 401 into `$fields = @()`. Nothing errors, nothing warns, and the caller reads it
    as "the board has no fields" - which is exactly the premise it then WRITES from. That
    misread already shipped once: Board-Fill reported a healthy "no gaps" board it had never
    managed to read (issue #86). It was fixed in that one file and never generalised, which
    is why this is a shared helper and not another hand-written check.

    The contract, and both halves matter equally:
      * gh exits non-zero            -> throw, with the operation named and gh's stderr attached.
      * gh succeeds and returns []   -> return it as an empty result, NOT an error. A genuinely
                                        empty board is not a failure.
    If those two ever collapse into each other the helper has failed at its only job, so the
    test suite pins them as a pair.

    (Precisely: an empty JSON array comes back as $null, because `'[]' | ConvertFrom-Json` emits
    nothing. That is what every consumer already expects - @($x).Count, foreach and ForEach-Object
    all see zero either way - but the distinction is written down here rather than papered over.)

    Three failure modes, not one:
      1. non-zero exit                        -> -GhArgs alone covers it.
      2. exit 0 with an unparseable/empty body -> -Json (gh --json always emits at least [] or {}).
      3. exit 0 with a graphql errors[] body   -> -Graphql. The request succeeded; the query did not.
         -Graphql implies -Json: the check needs the parsed body, so the two cannot be separated.

    stderr is captured here rather than left to each call site, because the `2>$null` idiom
    that ~30 sites use hides the message AND the exit code goes unread, so the failure leaves
    no trace at all.

    Pure at load: dot-source it, it defines functions only (no gh, no output).
      . (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

    Usage:
      $board  = Invoke-Gh -GhArgs @('project','view','13','--owner','x','--format','json') `
                          -What 'leer el board #13' -Json
      $resp   = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$q") -What 'mover el item' -Graphql
      $null   = Invoke-Gh -GhArgs @('project','item-edit',...) -What 'escribir el campo' -Retries 3

    A body on stdin (`gh api graphql --input -`) travels as -StdIn, NOT as a pipe into this
    function - see Invoke-GhRaw for why a pipe would hang instead of failing:
      $resp   = Invoke-Gh -GhArgs @('api','graphql','--input','-') -StdIn $body -What '...' -Graphql
#>

# The ONE place the gh executable is touched. A seam, so the retry/parse/throw logic above
# it is unit-testable by mocking this: no token, no network, any exit code on demand.
# stdout is kept CLEAN (stderr goes to its own file, never merged with 2>&1, which would
# splice ErrorRecords into a body about to be parsed as JSON).
function Invoke-GhRaw {
    param([string[]]$GhArgs, [string]$StdIn)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # $StdIn feeds `gh ... --input -`. It must be piped HERE, explicitly: a native
        # command does NOT inherit the enclosing function's pipeline input, so a caller
        # writing `$body | Invoke-Gh ...` does not fail - gh blocks reading the console
        # forever. A hang is worse than the 401 this file exists to stop, so the body
        # travels as a parameter and the pipe is built where gh can actually see it.
        if ($PSBoundParameters.ContainsKey('StdIn')) { $out = $StdIn | & gh @GhArgs 2>$errFile }
        else                                         { $out = & gh @GhArgs 2>$errFile }
        $code = $LASTEXITCODE           # read FIRST: any native call after this clobbers it
        $err  = ''
        if (Test-Path $errFile) {
            # -Raw on an empty file returns $null, and ([string]$null).Trim() THROWS
            # ("cannot call a method on a null-valued expression") - so the empty-stderr
            # case, i.e. every successful call, has to be handled explicitly.
            $raw = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($raw) { $err = $raw.Trim() }
        }
        return [pscustomobject]@{ Output = $out; ExitCode = $code; StdErr = $err }
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Is this failure worth retrying? Only what retrying can actually fix: GitHub's transient
# 5xx and network stalls. A 401 or a 404 is a fact, and retrying it four times just makes
# the same error arrive later.
function Test-GhTransientError {
    param([string]$StdErr)
    if (-not $StdErr) { return $false }
    # 'secondary rate limit' arrives as a 403, so it has to be matched by TEXT, not status:
    # a plain permissions 403 must stay non-transient. This is the failure /board work
    # -Parallel actually produces - N processes hammering the API - so leaving it out made
    # -Retries useless for the one case it was needed. (Primary rate limiting is NOT here:
    # it resets on the hour, and a 500ms backoff cannot outwait it.)
    return ($StdErr -match 'HTTP 5\d\d' -or
            $StdErr -match 'i/o timeout' -or
            $StdErr -match 'connection reset' -or
            $StdErr -match 'TLS handshake timeout' -or
            $StdErr -match 'temporary failure' -or
            $StdErr -match 'secondary rate limit')
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)][string[]]$GhArgs,
        [string]$What = 'la operacion gh',
        [switch]$Json,
        [switch]$RawJson,
        [switch]$Graphql,
        [string]$StdIn,
        [int]   $Retries = 0,
        [int]   $RetryDelayMs = 500
    )

    # -RawJson: validate the body as JSON but hand back the TEXT rather than a parsed object.
    # For callers that persist what gh sent (Backup-Board writes the snapshot to disk) -
    # round-tripping through ConvertFrom/ConvertTo-Json would silently reshape a backup, and
    # -Depth would quietly truncate it.
    #
    # NOT byte-for-byte gh output, and it must not be sold as such: `& gh` hands stdout back
    # already split into lines with the terminators stripped, so CRLF, the trailing newline
    # and any surrounding whitespace are gone before this function ever sees the body. What
    # -RawJson guarantees is narrower and is the part that matters: unreshaped and untruncated.
    if ($RawJson) { $Json = $true }

    # -Graphql IMPLIES -Json. Checking errors[] means parsing the body, and the parse only
    # happens under -Json - so `-Graphql` alone used to return before the check ever ran,
    # making the switch a silent no-op at exactly the call sites it was written for. A
    # caller that asks for the graphql check must GET the graphql check.
    if ($Graphql) { $Json = $true }

    $attempt = 0
    while ($true) {
        $r = if ($PSBoundParameters.ContainsKey('StdIn')) { Invoke-GhRaw -GhArgs $GhArgs -StdIn $StdIn }
             else                                         { Invoke-GhRaw -GhArgs $GhArgs }
        if ($r.ExitCode -eq 0) { break }

        # Retry only a transient failure, and only while attempts remain.
        if ($attempt -lt $Retries -and (Test-GhTransientError -StdErr $r.StdErr)) {
            $attempt++
            Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)   # linear backoff
            continue
        }
        $detail = if ($r.StdErr) { ": $($r.StdErr)" } else { '' }
        throw "No pude $What (gh exit $($r.ExitCode))$detail"
    }

    if (-not $Json) { return $r.Output }

    # gh --json ALWAYS emits at least [] or {}. Nothing means something went wrong in a way
    # the exit code did not report - never hand that back as an empty result.
    $body = ($r.Output -join "`n").Trim()
    if (-not $body) { throw "No pude $What - gh salio 0 pero sin salida (se esperaba JSON)" }

    try   { $parsed = $body | ConvertFrom-Json }
    catch { throw "No pude $What - la respuesta de gh no es JSON valido: $($_.Exception.Message)" }

    # graphql's own failure mode: HTTP 200 + exit 0, with the failure inside the body.
    if ($Graphql -and $parsed.PSObject.Properties.Name -contains 'errors' -and @($parsed.errors).Count -gt 0) {
        throw "No pude $What - graphql devolvio errores: $(@($parsed.errors)[0].message)"
    }
    if ($RawJson) { return $body }
    return $parsed
}

# ── Read cache (#571) ───────────────────────────────────────────────────────────
# Every gh invocation is a fresh process + TLS round trip, and NOTHING was cached: one clean
# /board work cycle made ~50-65 calls, many of them re-reading facts that had not changed
# (project fields, board schema). This is a small FILE cache - each script runs in its own pwsh
# process, so an in-memory cache dies within a second of being populated (the Apply-FieldPreset
# hashtable proved that). STRICTLY for read-only queries the caller can afford to see up to
# -TtlSec seconds stale; anything that feeds a WRITE decision at second granularity keeps using
# Invoke-Gh directly.

function Get-GhCacheDir {
    Join-Path ([System.IO.Path]::GetTempPath()) 'abios-gh-cache'
}

function Clear-GhCache {
    $dir = Get-GhCacheDir
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-GhCached {
    param(
        [Parameter(Mandatory)][string[]]$GhArgs,
        [string]$What = 'la operacion gh',
        [int]$TtlSec = 120,
        [switch]$Json,
        [switch]$Graphql,
        [switch]$Force
    )
    if ($Graphql) { $Json = $true }
    $key = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes(($GhArgs -join "`u{1f}")))) -replace '-', ''
    $dir  = Get-GhCacheDir
    $path = Join-Path $dir "$key.txt"

    if (-not $Force -and $TtlSec -gt 0 -and (Test-Path -LiteralPath $path)) {
        try {
            $age = ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalSeconds
            if ($age -lt $TtlSec) {
                $cached = Get-Content -LiteralPath $path -Raw
                # A HIT must behave exactly like a fresh -Json call would; a corrupt OR EMPTY
                # entry (Set-Content is not atomic across processes - a concurrent reader can
                # see a truncated file) is a MISS, never a $null handed to the caller as "the
                # board has no fields" (external review round 1).
                if (-not [string]::IsNullOrWhiteSpace($cached)) {
                    if ($Json) {
                        $parsedHit = $cached | ConvertFrom-Json
                        # A HIT owes the same graphql errors[] check a miss gets (round 2): only
                        # successful bodies are written, but a same-args -Json call or a stale
                        # artifact could have cached an errors payload - treat it as a MISS.
                        if ($Graphql -and $parsedHit.PSObject.Properties.Name -contains 'errors' -and @($parsedHit.errors).Count -gt 0) {
                            # fall through to a fresh fetch
                        } else {
                            return $parsedHit
                        }
                    } else {
                        return $cached
                    }
                }
            }
        } catch { }
    }

    # MISS (or bust): fetch through the fail-closed wrapper. Only a SUCCESSFUL result is
    # cached - a thrown failure must stay a failure on the next call too, never a cached one.
    if ($Json) {
        $body = Invoke-Gh -GhArgs $GhArgs -What $What -RawJson -Graphql:$Graphql
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath $path -Encoding UTF8 -Value $body
        } catch { }
        return ($body | ConvertFrom-Json)
    }
    $out = Invoke-Gh -GhArgs $GhArgs -What $What
    $text = ($out -join "`n")
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $text
    } catch { }
    return $text
}
