# BoardWork.Processes.ps1 - process supervision (tree kill, orphan reaper), extracted
# VERBATIM from Board-Work.ps1 (#575). Function definitions only; Board-Work dot-sources
# this file before its own dot-source guard, so the surface is unchanged.


# Live pid->parentPid map from CIM. Thin (one reading) -> mocked in tests. PIDs are cast
# to [long] (they are unsigned 32-bit) so a value above [int]::MaxValue cannot throw during
# map construction and silently drop entries from the guard.
function Get-ProcessParentMap {
    $map = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        $map[[long]$p.ProcessId] = [long]$p.ParentProcessId
    }
    return $map
}

# Every transitive child of a root PID over a pid->parentPid map. PURE, cycle-safe. Used
# to veto a tree-kill whose subtree (taskkill /T kills descendants) contains a guarded PID.
function Get-DescendantPids([long]$RootPid, [hashtable]$ParentMap) {
    $children = @{}
    foreach ($k in $ParentMap.Keys) {
        $parent = [long]$ParentMap[$k]
        if (-not $children.ContainsKey($parent)) { $children[$parent] = @() }
        $children[$parent] += [long]$k
    }
    $result = @()
    $seen   = @{}
    $stack  = New-Object System.Collections.Stack
    $stack.Push($RootPid)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        foreach ($c in @($children[$cur])) {
            if ($c -and -not $seen.ContainsKey($c)) {
                $seen[$c] = $true
                $result += $c
                $stack.Push($c)
            }
        }
    }
    return @($result)
}

# The never-kill set: the given session PID (default this process) + its ancestor chain.
# ANCESTORS, not descendants: the fleet sessions are descendants and must stay killable,
# but the coordinator + its hosts must never be a target. An injectable ParentMap keeps it
# unit-testable; the default reads live CIM.
function Get-SessionGuardSet([int]$SelfPid = $PID, [hashtable]$ParentMap) {
    if (-not $ParentMap) { $ParentMap = Get-ProcessParentMap }
    return @(Get-AncestorChain $SelfPid $ParentMap)
}

# Subtract the guard set from a target list. PURE -> unit-testable.
function Remove-GuardedTargets([int[]]$Targets, [int[]]$Guard) {
    return @($Targets | Where-Object { $Guard -notcontains $_ })
}

# Tree-deep force kill of a PID and every descendant via `taskkill /PID <id> /T /F` (the
# reliable Windows tree-kill). SAFETY-CRITICAL and fail-safe:
#  * the guard is ALWAYS computed from the live process tree (self + ancestors), never
#    trusted from an omitted/partial caller arg - an extra -Guard only ADDS protection;
#  * FAILS CLOSED: if the process map can't be built, it refuses (can't verify safety);
#  * checks the whole TARGET SUBTREE (taskkill /T kills descendants) against the guard, so
#    a kill whose tree contains the session/an ancestor is refused, not just the root.
# -DryRun returns the plan without executing, so the decision path is fully unit-testable.
function Stop-ProcessTree {
    param(
        [int]$TargetPid,
        [int[]]$Guard = @(),
        [int]$SelfPid = $PID,
        [hashtable]$ParentMap,
        [switch]$DryRun
    )
    if ($TargetPid -le 0) {
        return [PSCustomObject]@{ Pid = $TargetPid; Refused = $true; Killed = $false; Reason = 'PID invalido' }
    }
    if (-not $ParentMap) { try { $ParentMap = Get-ProcessParentMap } catch { $ParentMap = @{} } }
    if (-not $ParentMap -or $ParentMap.Count -eq 0) {
        return [PSCustomObject]@{ Pid = $TargetPid; Refused = $true; Killed = $false; Reason = 'sin mapa de procesos - fail-closed' }
    }
    # Full guard = live self+ancestors (always) UNION any caller-supplied protected PIDs.
    $fullGuard = @(@(Get-AncestorChain $SelfPid $ParentMap) + @($Guard)) | Select-Object -Unique
    # taskkill /T kills the whole subtree -> a guarded PID ANYWHERE in the target's tree
    # (root or descendant) must veto the kill, not only the root.
    $subtree = @($TargetPid) + @(Get-DescendantPids $TargetPid $ParentMap)
    $blocked = @($subtree | Where-Object { $fullGuard -contains $_ })
    if ($blocked.Count -gt 0) {
        return [PSCustomObject]@{ Pid = $TargetPid; Refused = $true; Killed = $false; Reason = ("el arbol incluye PID(s) protegido(s): {0}" -f ($blocked -join ',')) }
    }
    $cmd = "taskkill /PID $TargetPid /T /F"
    if ($DryRun) {
        return [PSCustomObject]@{ Pid = $TargetPid; Refused = $false; Killed = $false; DryRun = $true; Command = $cmd }
    }
    & taskkill /PID $TargetPid /T /F 2>&1 | Out-Null
    return [PSCustomObject]@{ Pid = $TargetPid; Refused = $false; Killed = ($LASTEXITCODE -eq 0); Command = $cmd }
}

# The fleet issue a process belongs to, parsed from its command line. PURE. Detection is
# ISSUE-precise, not a broad substring: a launcher runs `...launch-<n>.ps1`, a CLI reads
# `...briefing-<n>.txt`, and worktrees live under `...--worktrees\issue-<n>`. Requiring
# DIGITS right after the artifact keyword avoids matching unrelated scripts (e.g.
# `launch-server.js`). Returns 0 when the process is not a fleet artifact.
function Get-FleetIssueFromCommandLine([string]$CommandLine) {
    if (-not $CommandLine) { return 0 }
    # Anchored to the EXACT generated artifacts so unrelated commands do not over-match:
    #   launch-<n>.ps1  (the launcher)   briefing-<n>.txt  (the CLI's prompt file)
    #   --worktrees\issue-<n>  (the grouped worktree path). e.g. `launch-42-test.ps1` or
    #   `node tools/issue-123-reproducer.js` are NOT fleet artifacts and return 0.
    if ($CommandLine -match 'launch-(\d+)\.ps1')            { return [int]$Matches[1] }
    if ($CommandLine -match 'briefing-(\d+)\.txt')          { return [int]$Matches[1] }
    if ($CommandLine -match '--worktrees[\\/]issue-(\d+)')  { return [int]$Matches[1] }
    return 0
}

# From a list of {ProcessId, CommandLine}, the ESCAPED fleet orphans. PURE. A process is a
# fleet process when its command line carries a fleet issue artifact. It is an orphan
# UNLESS (a) its PID is a live registry session, OR (b) its issue belongs to a live
# session - the latter is essential for `wt` launches, where the registry tracks the host
# PID (the real spawned pwsh PID is not registered) so PID-only matching would reap a LIVE
# session. Returns the non-orphan-safe escaped processes.
function Find-FleetOrphansCore([object[]]$Processes, [int[]]$LivePids, [int[]]$LiveIssues) {
    $orphans = @()
    foreach ($p in @($Processes)) {
        $issue = Get-FleetIssueFromCommandLine $p.CommandLine
        if ($issue -le 0) { continue }                             # not a fleet artifact
        if ($LivePids   -contains [int]$p.ProcessId) { continue }  # tracked live PID
        if ($LiveIssues -contains $issue)            { continue }  # a live session owns this issue (wt)
        $orphans += $p
    }
    return @($orphans)
}

# Live: escaped fleet processes. Queries ONLY pwsh.exe (every session's launch-<n>.ps1
# launcher) and node.exe (the CLIs - claude/gemini/codex/copilot all run under node).
# Deliberately NOT 'claude.exe': that is the Claude Desktop host app, whose renderers would
# be false-positive kill targets (and are NOT in the guard set). Thin -> the pure core is
# Find-FleetOrphansCore, cross-checking BOTH live PIDs and live issues.
function Find-FleetOrphans {
    $filter = "Name='pwsh.exe' OR Name='node.exe'"
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
               Select-Object ProcessId, CommandLine)
    $live       = @(Read-SessionRegistry)
    $livePids   = @($live | ForEach-Object { [int]$_.sessionPid })
    $liveIssues = @($live | ForEach-Object { [int]$_.issue })
    return Find-FleetOrphansCore $procs $livePids $liveIssues
}

# Tree-kill a set of fleet candidates, each through the fail-safe Stop-ProcessTree (self +
# ancestors always excluded). FAIL-SAFE: the live registry session PIDs are ALWAYS folded
# into the guard here (not just whatever the caller passes), so a legitimate live session
# inside a candidate's subtree is protected even if the caller omits -Guard (taskkill /T
# kills descendants). -DryRun plans without killing.
#
# RESIDUAL LIMITATION (wt): a `wt` launch registers the host/proxy PID, not the real spawned
# pwsh. If that proxy dies while the tab still runs, the registry prunes the entry and its
# issue leaves $liveIssues, so a still-live session could be listed as an orphan. The
# backstop is the spec-mandated flow: -Reap DEFAULTS to a dry-run listing and requires human
# confirmation before any forced kill (wired at the CLI in #198) - never an unattended sweep.
function Invoke-FleetReap {
    param(
        [object[]]$Candidates,
        [int]$SelfPid = $PID,
        [int[]]$Guard = @(),
        [hashtable]$ParentMap,
        [switch]$KillLive,   # whole-fleet teardown (-KillAll): DO kill tracked live sessions
        [switch]$DryRun
    )
    if (-not $ParentMap) { try { $ParentMap = Get-ProcessParentMap } catch { $ParentMap = @{} } }
    # -Reap protects every live registry session (only escaped orphans should die); -KillAll
    # (-KillLive) tears the whole fleet down, so it does NOT fold the live PIDs - but the
    # coordinator is STILL safe because Stop-ProcessTree always excludes self + ancestors.
    if ($KillLive) {
        $fullGuard = @($Guard)
    } else {
        # FAIL CLOSED: a registry READ FAILURE (throw) is distinct from a legitimately empty
        # registry - if we cannot enumerate live sessions we cannot verify safety, so refuse
        # everything rather than proceed with an empty guard.
        $liveGuard = $null
        try { $liveGuard = @(Read-SessionRegistry | ForEach-Object { [int]$_.sessionPid }) } catch { $liveGuard = $null }
        if ($null -eq $liveGuard) {
            return @(@($Candidates) | ForEach-Object {
                [PSCustomObject]@{ Pid = [int]$_.ProcessId; Refused = $true; Killed = $false; Reason = 'no se pudo leer el registro de sesiones - fail-closed' }
            })
        }
        $fullGuard = @(@($Guard) + $liveGuard) | Select-Object -Unique
    }
    $results = @()
    foreach ($c in @($Candidates)) {
        $results += Stop-ProcessTree -TargetPid ([int]$c.ProcessId) -Guard $fullGuard -SelfPid $SelfPid -ParentMap $ParentMap -DryRun:$DryRun
    }
    return $results
}
