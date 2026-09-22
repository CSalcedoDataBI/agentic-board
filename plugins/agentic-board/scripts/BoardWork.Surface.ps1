# BoardWork.Surface.ps1 - launch "surfaces" for the /board work fleet (#710, phase P1).
#
# `-Parallel ... -Launch` only ever opened a Windows Terminal tab or a standalone pwsh window
# (issue #100). A user working inside a host app (the Claude desktop app's Code tab, an IDE) got N
# detached terminal windows instead of N visible sessions in the app's own sidebar, and no signal
# back in the conversation that started the run. #710 makes the launch surface an adapter:
#   terminal  - unchanged (a wt tab / pwsh window). The default - byte-for-byte today's behaviour.
#   app       - a host-app session per issue. A SCRIPT CANNOT OPEN ONE - only the agent can, via the
#               host's own session-spawn tool - so this surface does everything -Parallel does today
#               EXCEPT create a worktree and EXCEPT spawn a process: it emits a dispatch manifest (one
#               entry per issue, self-contained) for the agent to hand to that tool, then records the
#               id it gets back with `-RegisterSession -Issue <n> -HostSessionId <id>`.
#   headless  - not implemented yet (a later phase); the ValidateSet accepts the value so callers can
#               name it, but Board-Work.ps1 refuses to actually dispatch on it rather than silently
#               falling back to a visible terminal.
#
# Two things this phase also fixes because parallel VISIBLE sessions make them far more likely to
# bite (#710 decisions 5-6):
#   * every read-modify-write of sessions.json goes through Invoke-WithSessionRegistryLock, so two
#     processes writing at once never clobber each other's row (a real concurrency test proves it -
#     see BoardWork.Surface.Tests.ps1).
#   * a read-only listing (-Sessions, -Watch) must never CREATE .agentic-board/ - Get-AbiosStateDir
#     already supports -NoCreate; Board-Work.ps1's session-registry reads now pass it.
#
# Function definitions only. Pure at load (no gh, no git, no output) except the lock helper, which is
# necessarily side-effecting (it takes a real OS mutex) but deterministic and independently testable.

# A session registered with a hostSessionId (#710 decision 5/P1) has NO pid this script can ever
# see - the host process owns it, not this script's launch path. Every "is it alive" check in this
# file reads as ">0 = alive", so a host-managed session reports this SENTINEL rather than 0 (which
# would prune it from -Sessions or mark it "process terminated" the moment it has no real pid to
# check). It is not a real Windows process id: nothing may ever pass it to Get-Process - callers that
# would otherwise do that (Show-SessionFleet) branch on hostSessionId first instead.
function Get-HostManagedPidMarker { return 1 }

# Serialize every read-modify-write of sessions.json through one named OS mutex, so two processes
# (two parallel `/board work` launches, a launch racing a -RegisterSession, -Watch's teardown racing
# a live launch) never interleave a read and a write and drop each other's row (#710 decision 5).
# The mutex name is derived from the resolved sessions.json PATH, not a fixed string, so two
# different repos (two different state dirs) never block each other.
#
# "Global\" needs no special privilege on an ordinary desktop session; it is only rejected under a
# locked-down Terminal Services session, where a "Local\" (session-scoped) mutex still serializes
# every process this fleet actually spawns (they all run in the same interactive session) - so a
# UnauthorizedAccessException falls back to that instead of failing the whole operation closed.
#
# $Body runs ONCE, holding the lock, and its return value is passed through. A $Path that cannot be
# resolved (no state dir - outside a git repo) runs $Body unlocked: there is no shared file to
# protect, and every caller already treats "$null path" as "nothing to read/write".
function Invoke-WithSessionRegistryLock {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Path,
        [int]$TimeoutMs = 15000
    )
    if (-not $Path) { return (& $Body) }
    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))
    ).Replace('-', '')
    $name = "Global\agentic-board-sessions-$hash"
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $name)
    } catch [System.UnauthorizedAccessException] {
        $name  = "Local\agentic-board-sessions-$hash"
        $mutex = New-Object System.Threading.Mutex($false, $name)
    }
    $owns = $false
    try {
        $owns = $mutex.WaitOne($TimeoutMs)
        if (-not $owns) {
            throw "Timed out after ${TimeoutMs}ms waiting for the sessions.json lock ($name) - another process is holding it far too long."
        }
        return (& $Body)
    } finally {
        if ($owns) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# One dispatch-manifest entry for the 'app'/'headless' fleet surfaces (#710 P1): everything a
# session-spawn tool (or a human) needs to actually start the session, with no worktree and no pid
# assumption baked in - the host creates the worktree, not this script. PURE: every fact is an
# argument, so this is unit-testable with no gh/git/disk.
function New-DispatchManifestEntry {
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Title = '',
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Briefing,
        [string[]]$OwnedPaths = @(),
        [Parameter(Mandatory)][string]$RunId
    )
    [pscustomobject]@{
        issue      = $Issue
        title      = $Title
        repo       = $Repo
        branch     = $Branch
        briefing   = $Briefing
        ownedPaths = @($OwnedPaths | Where-Object { $_ })
        runId      = $RunId
    }
}

# Serialize a manifest-entry array to a JSON string, always an array even when empty. PURE - the
# same "an empty pipeline emits nothing" footgun this repo already guards in
# Remove-SessionRegistryEntry and Fleet-Ownership's ConvertTo-OwnershipJson: piping @() into
# ConvertTo-Json produces NO output, which would hand a JSON consumer nothing at all instead of "[]".
function ConvertTo-DispatchManifestJson {
    param([object[]]$Entries = @())
    if (@($Entries).Count -eq 0) { return '[]' }
    return ($Entries | ConvertTo-Json -Depth 6 -AsArray)
}

# Whatever Fleet-Ownership already has on record for this issue, so a dispatched session's manifest
# entry carries the same "these are my files" fact a terminal-surface session declares for itself
# with `Fleet-Ownership.ps1 -Claim` (the phase-4 overlap check is what actually gates on this - here
# it is only carried through). Read-only and best-effort: an unreadable or missing ownership.json
# reads as "nothing claimed yet", never an error, and -NoCreate means reading it never creates
# .agentic-board/ (the same rule as the session registry - #710 decision 6).
#
# Deliberately does NOT dot-source Fleet-Ownership.ps1: that script's own top-level param() block
# (-Issue, -Branch, -Paths, -Json...) would land in Board-Work.ps1's OWN script scope and clobber the
# very parameters this phase adds under the same names.
function Get-IssueOwnedPaths {
    param([int]$IssueNum)
    $state = Get-AbiosStateDir -NoCreate
    if (-not $state) { return @() }
    $path = Join-Path (Join-Path $state 'fleet') 'ownership.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $claims = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return @() }
    $mine = @($claims | Where-Object { $_ -and [int]$_.issue -eq $IssueNum } | Select-Object -First 1)
    if ($mine.Count -eq 0) { return @() }
    return @($mine[0].paths | Where-Object { $_ })
}

# Record the id the host's session-spawn tool returned for an issue already started on
# `-Surface app` (`-RegisterSession -Issue <n> -HostSessionId <id>`). Refuses to invent a row for an
# issue that was never started that way - the same "never invent a session" rule
# Add-SessionPullRequest already follows for -RecordPr. Returns { Ok; Message }.
function Register-HostSession {
    param([Parameter(Mandatory)][int]$IssueNum, [Parameter(Mandatory)][string]$HostSessionId)
    $prev = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq $IssueNum }) | Select-Object -First 1
    if (-not $prev) {
        return [pscustomobject]@{
            Ok = $false
            Message = "el issue #$IssueNum no tiene sesion registrada (arrancalo primero con -Parallel ... -Surface app): no invento una fila para anotar el hostSessionId."
        }
    }
    Write-SessionRegistryEntry -IssueNum $IssueNum -HostSessionId $HostSessionId
    $surface = if ($prev.PSObject.Properties['surface']) { "$($prev.surface)" } else { '' }
    return [pscustomobject]@{
        Ok = $true
        Message = "hostSessionId '$HostSessionId' anotado para el issue #$IssueNum (surface $surface)."
    }
}
