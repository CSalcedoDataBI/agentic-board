# BoardWork.Capacity.ps1 - the machine-capacity governor, extracted VERBATIM from
# Board-Work.ps1 (#575). Function definitions only; Board-Work dot-sources this file
# before its own dot-source guard, so tests and callers see the same surface as before.


# ==============================================================================
# Governor - machine capacity (Phase 2). Get-DispatchPlan/Invoke-FleetDispatch
# pace launches to what the box can carry: free RAM / per-session budget, capped
# by cores-2, and pausing while CPU is saturated.
# ==============================================================================

# Normalize raw readings into a capacity snapshot. PURE -> unit-testable (the live
# CIM calls are isolated in Get-MachineCapacity). CpuLoads is the per-socket
# LoadPercentage array (Win32_Processor returns one instance per socket); free/total
# are physical memory in KB (Win32_OperatingSystem reports KB).
function Get-MachineCapacityCore([object[]]$CpuLoads, [double]$FreePhysicalKB, [double]$TotalPhysicalKB, [int]$LogicalCores) {
    # LoadPercentage can be momentarily $null; drop those before averaging, default 0.
    $vals = @($CpuLoads | Where-Object { $_ -ne $null } | ForEach-Object { [double]$_ })
    $cpu  = if ($vals.Count) { [int][math]::Round((($vals | Measure-Object -Average).Average), 0) } else { 0 }
    if ($cpu -lt 0) { $cpu = 0 }
    $freeGB  = [math]::Round(([math]::Max($FreePhysicalKB, 0)  / 1MB), 2)   # KB -> GB (1MB numeric = 1048576)
    $totalGB = [math]::Round(([math]::Max($TotalPhysicalKB, 0) / 1MB), 2)
    [PSCustomObject]@{
        CpuLoadPercent = $cpu
        FreeRamGB      = $freeGB
        TotalRamGB     = $totalGB
        Cores          = $LogicalCores
    }
}

# Live capacity: read CPU load + physical memory via CIM and fold into the pure core.
# CPU via Win32_Processor.LoadPercentage, NEVER Get-Counter (fails c0000bb8 on this
# localized Windows - see the Phase 2 spec). LogicalCores defaults to the real count
# but is injectable so the governor can cap/override and tests stay deterministic.
function Get-MachineCapacity {
    param([int]$LogicalCores = [Environment]::ProcessorCount)
    $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    $loads = @($procs | ForEach-Object { $_.LoadPercentage })
    $os    = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $free  = if ($os) { [double]$os.FreePhysicalMemory }     else { 0 }
    $total = if ($os) { [double]$os.TotalVisibleMemorySize } else { 0 }
    Get-MachineCapacityCore $loads $free $total $LogicalCores
}

# How many sessions to launch in the next wave. PURE -> unit-testable. The concurrency
# ceiling is the MIN of: free RAM / per-session budget, cores-2 (the same cap the
# platform uses, floored at 1), and an explicit -MaxConcurrent. The wave is the free
# slots under that ceiling (ceiling - already running), never more than the pending
# count. Forward-progress guard: when nothing is running yet, always launch at least 1
# even if RAM looks exhausted (each session is recoverable in its own worktree, so the
# governor may be aggressive rather than deadlock).
function Get-DispatchPlan {
    param(
        [double]$FreeRamGB,
        [int]$Cores,
        [int]$Pending,
        [int]$Running = 0,
        [double]$PerSessionGB = 2.0,
        [int]$MaxConcurrent = 0
    )
    # Clamp degenerate inputs so a corrupt reading can neither produce a negative
    # ceiling nor (via a negative running count) INFLATE the free-slot math.
    $Pending = [math]::Max($Pending, 0)
    $Running = [math]::Max($Running, 0)
    $ramCap  = [math]::Max([int][math]::Floor($FreeRamGB / [math]::Max($PerSessionGB, 0.1)), 0)
    $coreCap = [math]::Max($Cores - 2, 1)
    # Named caps so the binding constraint can be reported (monitor / log visibility).
    $caps = [ordered]@{ ram = $ramCap; cores = $coreCap }
    if ($MaxConcurrent -gt 0) { $caps['maxconcurrent'] = $MaxConcurrent }
    $ceiling  = ($caps.Values | Measure-Object -Minimum).Minimum
    $capBound = ($caps.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
    $freeSlots = [math]::Max($ceiling - $Running, 0)
    $wave      = [math]::Min($freeSlots, $Pending)
    # Which constraint actually decided the wave, for the narrator. -le so an exhausted
    # or empty queue (Pending <= freeSlots, incl. Pending 0) reads as 'pending', not a cap.
    $boundBy = if ($Pending -le $freeSlots) { 'pending' } else { $capBound }
    # Never deadlock: if the queue has work and no session is live, launch one.
    if ($wave -le 0 -and $Running -le 0 -and $Pending -gt 0) {
        $wave = 1
        $boundBy = 'progress-floor'
    }
    [PSCustomObject]@{
        WaveSize     = [int]$wave
        Concurrency  = [int]$ceiling
        RamCap       = [int]$ramCap
        CoreCap      = [int]$coreCap
        BoundBy      = $boundBy
        PerSessionGB = $PerSessionGB
    }
}

# A launch slot is free when a session has finished (fewer running than the baseline we
# started waiting at) OR the CPU has cooled below the threshold. PURE -> unit-testable;
# Wait-FleetSlot polls live state and calls this.
function Test-SlotFree([int]$StartRunning, [int]$CurrentRunning, [int]$CpuLoad, [int]$CpuThreshold) {
    return ($CurrentRunning -lt $StartRunning) -or ($CpuLoad -lt $CpuThreshold)
}

# Block until a launch slot frees or a timeout elapses. Side-effecting (reads the live
# registry + capacity, sleeps) -> not unit-tested directly; its decision is Test-SlotFree.
function Wait-FleetSlot {
    param([int]$CpuThreshold = 85, [int]$TimeoutSec = 300, [int]$PollSec = 5)
    $baseline = @(Read-SessionRegistry).Count
    $waited = 0
    while ($waited -lt $TimeoutSec) {
        Start-Sleep -Seconds $PollSec
        $waited += $PollSec
        $cur = @(Read-SessionRegistry).Count
        $cpu = (Get-MachineCapacity).CpuLoadPercent
        if (Test-SlotFree $baseline $cur $cpu $CpuThreshold) { return }
    }
}

# The governor loop. Never fires the whole batch at once: each iteration sizes a wave
# from live capacity (Get-DispatchPlan), launches it, and - if work remains - blocks on
# Wait-FleetSlot until a session dies or the CPU cools, then re-plans. A CLI known to be
# out of quota is skipped for the rest of the run (its issue still launches, on claude).
# The live operations are injected as hooks so the loop is unit-testable with fakes.
function Invoke-FleetDispatch {
    param(
        [object[]]$Queue,                 # items with .issue and .cli (+ whatever LaunchSession needs)
        [int]$MaxConcurrent = 0,
        [double]$PerSessionGB = 2.0,
        [int]$CpuThreshold = 85,
        [int]$MaxStalls = 120,            # consecutive zero-wave waits before giving up (never hang)
        [hashtable]$NoQuotaClis = @{},
        [scriptblock]$LaunchSession,      # & $LaunchSession $item $cli -> the actual CLI launched
        [scriptblock]$GetCapacity  = { Get-MachineCapacity },
        [scriptblock]$CountRunning = { @(Read-SessionRegistry).Count },
        [scriptblock]$WaitForSlot  = { Wait-FleetSlot -CpuThreshold $CpuThreshold }
    )
    if (-not $LaunchSession) { throw "Invoke-FleetDispatch requires a -LaunchSession hook." }
    $items = @($Queue)
    $idx = 0
    $waveNum = 0
    $stalls = 0
    $launched = @()
    while ($idx -lt $items.Count) {
        $cap  = & $GetCapacity
        $run  = [int](& $CountRunning)
        $plan = Get-DispatchPlan -FreeRamGB $cap.FreeRamGB -Cores $cap.Cores `
                                 -Pending ($items.Count - $idx) -Running $run `
                                 -PerSessionGB $PerSessionGB -MaxConcurrent $MaxConcurrent
        if ($plan.WaveSize -le 0) {
            # Ceiling full (sessions still running): wait for a slot to free, then re-plan.
            # Bounded so a fleet of hung sessions that never free a slot can't loop forever -
            # after MaxStalls consecutive zero-wave waits, give up and report the remainder.
            $stalls++
            if ($stalls -ge $MaxStalls) {
                Write-Host ("  WARN governor: {0} issue(s) sin lanzar - no se liberaron slots tras {1} esperas." -f ($items.Count - $idx), $stalls) -ForegroundColor DarkYellow
                break
            }
            & $WaitForSlot | Out-Null
            continue
        }
        $stalls = 0
        $waveNum++
        for ($k = 0; $k -lt $plan.WaveSize -and $idx -lt $items.Count; $k++, $idx++) {
            $item = $items[$idx]
            # Runtime backoff: a CLI known out of quota is skipped for the rest of the run;
            # the issue still launches on the always-available claude fallback.
            $cli = $item.cli
            if ($cli -and $NoQuotaClis.ContainsKey($cli) -and $NoQuotaClis[$cli]) { $cli = 'claude' }
            # Record the CLI the hook ACTUALLY launched (its return), not our pre-launch guess,
            # so the dispatch result stays accurate if the hook re-resolves availability.
            $actual = & $LaunchSession $item $cli
            $launched += [PSCustomObject]@{ issue = $item.issue; cli = $actual; wave = $waveNum }
        }
        # Pace: if work remains, block until the next slot frees before the next wave.
        if ($idx -lt $items.Count) { & $WaitForSlot | Out-Null }
    }
    return $launched
}

# ==============================================================================
# Kill layer (Phase 2 task reaper foundation). Every kill path is guarded by
# Get-SessionGuardSet (this session's PID + ancestor chain) so the tool can never
# terminate itself, its terminal host, or the Claude host above it. Fleet sessions
# are (re)parented DESCENDANTS -> not in the guard set -> stay killable.
# ==============================================================================

# Walk ParentProcessId from a start PID to the root over a pid->parentPid map. PURE ->
# unit-testable. Returns start + ancestors, and is cycle-safe (a $seen set stops a loop).
function Get-AncestorChain([int]$StartPid, [hashtable]$ParentMap) {
    $chain = @()
    $seen  = @{}
    $cur   = $StartPid
    while ($cur -and $cur -gt 0 -and -not $seen.ContainsKey($cur)) {
        $chain += $cur
        $seen[$cur] = $true
        $cur = if ($ParentMap.ContainsKey($cur)) { [int]$ParentMap[$cur] } else { 0 }
    }
    return @($chain)
}
