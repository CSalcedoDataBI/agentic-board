# BoardWork.Adapters.ps1 - the CLI adapter registry, probes and per-issue CLI picker,
# extracted VERBATIM from Board-Work.ps1 (#759). Function definitions only; Board-Work
# dot-sources this file before its own dot-source guard, so tests see the same surface.

# =======================================================================
# CLI adapter registry: one record per launchable AI CLI. Generalizes the
# previously Claude-only launch path (Build-WorktreeLaunch / Get-SessionBriefing).
# Kind: 'repl' = live tab in the worktree; 'async' = dispatches a cloud task.
# Hooks are scriptblocks so they stay pure/testable and are invoked with &.
# =======================================================================
function Get-CliAdapters {
    @(
        [PSCustomObject]@{
            Name         = 'claude'
            Command      = 'claude'
            Kind         = 'repl'
            IsDefault    = $true
            InstallArgs  = $null
            # claude is the host CLI running this very script -> always available.
            Probe        = { param($ctx) 'ok' }
            # Permission bypass is an explicit opt-in (#761): appended only when the launch
            # context carries AllowBypass (Board-Work -AllowPermissionBypass).
            BypassArgs   = '--permission-mode bypassPermissions'
            RequiresBypass = $false
            # Credentials this CLI may read from the environment, kept by the secret scrub (#769).
            # claude's own is the -ClaudeAuthVar, which Build-WorktreeLaunch always keeps.
            KeepEnv      = @()
            # Build the per-worktree claude launch script. $ctx carries at least
            # BriefingFile + AuthVar. This is the SAME construction Build-WorktreeLaunch
            # used inline before the adapter refactor - kept byte-identical on purpose
            # (see the O'Brien single-quote escaping + the -join "`r`n" below).
            BuildLaunch  = {
                param($ctx)
                # Double any single quote so a briefing path containing ' (valid on Windows, e.g. an
                # O'Brien user folder) can't break out of the single-quoted literal it is embedded in
                # inside the generated launch script (the Get-Content -LiteralPath '...' arg below).
                $safeBrief  = $ctx.BriefingFile -replace "'", "''"
                # Each step on its OWN line (a .ps1 file), so no ';' is ever needed - which is the
                # whole point: ';' on wt's command line would split the tab (see the header note).
                # The chosen credential is captured FIRST - the Windows user scope, else the process
                # (#767: there is no user scope off Windows) - then every competing one is cleared,
                # then it is set. One step per line; no value ever reaches the script text.
                $getAuth    = '$abiosAuth=[Environment]::GetEnvironmentVariable(''{0}'',''User'')' -f $ctx.AuthVar
                $getAuth2   = 'if (-not $abiosAuth) {{ $abiosAuth=[Environment]::GetEnvironmentVariable(''{0}'') }}' -f $ctx.AuthVar
                $clearAuth  = 'Remove-Item Env:ANTHROPIC_API_KEY,Env:ANTHROPIC_AUTH_TOKEN,Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue'
                $setAuth    = '$env:{0}=$abiosAuth' -f $ctx.AuthVar
                $clean      = 'Remove-Item Env:CLAUDECODE,Env:CLAUDE_CODE_SESSION_ID,Env:CLAUDE_CODE_CHILD_SESSION,Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue'
                $bypass     = if ($ctx.AllowBypass) { ' --permission-mode bypassPermissions' } else { '' }
                $run        = 'claude -p (Get-Content -Raw -LiteralPath ''{0}''){1} --no-session-persistence --verbose' -f $safeBrief, $bypass
                ($getAuth, $getAuth2, $clearAuth, $setAuth, $clean, $run) -join "`r`n"
            }
        }
        [PSCustomObject]@{
            # Replaces the former 'gemini' adapter (#615): Gemini CLI stopped authenticating
            # individual Google accounts on 2026-06-18 - its probe now always returns
            # IneligibleTierError/UNSUPPORTED_CLIENT and Google redirects to Antigravity, so
            # the fleet was routing Docs/Chore work to a CLI that could never come back.
            Name         = 'antigravity'
            Command      = 'agy'
            Kind         = 'repl'
            IsDefault    = $false
            # No npm package - Google ships an install script; the binary lands in
            # %LOCALAPPDATA%\agy\bin. A remote script piped into iex cannot be pinned or reviewed
            # (#765), so the tool never runs it: it points the user at the install page instead.
            InstallArgs  = $null
            InstallUrl   = 'https://antigravity.google/docs/cli/install'
            # One-token probe of auth/quota (see Get-CliProbeStatus). It carries NO permission
            # bypass (#761): a one-token reply calls no tool, so the flag made no difference to
            # it - measured 10s without it and 8s with it, exit 0 and 'OK' both ways.
            Probe        = { param($ctx) Invoke-CliProbe @('agy', '-p', 'reply OK') }
            BypassArgs   = '--dangerously-skip-permissions'
            KeepEnv      = @()
            # Without the bypass agy soft-denies its own file-read in headless mode and starts
            # blind, so -Fleet only picks it when the human passed -AllowPermissionBypass.
            RequiresBypass = $true
            BuildLaunch  = {
                param($ctx)
                # agy is told to READ the briefing rather than receiving its content as an
                # argument (what the other adapters do): a briefing carries backticks and
                # quotes, and PowerShell drops embedded quotes when handing an argument to a
                # native .exe. The path still gets the same single-quote doubling as the
                # claude adapter so an O'Brien-style folder can't break out of the literal.
                # --dangerously-skip-permissions is REQUIRED: without it agy soft-denies its
                # own file-read tool call in headless mode and the session starts blind.
                $b = $ctx.BriefingFile -replace "'", "''"
                $bypass = if ($ctx.AllowBypass) { ' --dangerously-skip-permissions' } else { '' }
                'agy -p ''Read the file {0} and follow its instructions to the letter.''{1}' -f $b, $bypass
            }
        }
        [PSCustomObject]@{
            Name         = 'jules'
            Command      = 'jules'
            Kind         = 'async'
            IsDefault    = $false
            InstallArgs  = @('npm', 'i', '-g', '@google/jules@0.1.42')   # pinned (#765)
            # jules is an ASYNC cloud agent: 'jules new' dispatches a session that operates
            # on the REMOTE repo, not this local worktree/branch. Phase-1 limitation: this
            # dispatch is best-effort - there is no local worktree/PR integration yet (the
            # cloud session runs independently of the branch this script checked out). Full
            # worktree/PR round-trip integration is deferred to a later phase.
            # 'jules remote list' returns "Must specify what to list" with exit 0 (a
            # false ok) - '--session' scopes it to a well-formed listing instead.
            Probe        = { param($ctx) Invoke-CliProbe @('jules', 'remote', 'list', '--session') }
            BypassArgs   = ''
            RequiresBypass = $false
            KeepEnv      = @()
            BuildLaunch  = {
                param($ctx)
                $b = $ctx.BriefingFile -replace "'", "''"
                'jules new (Get-Content -Raw -LiteralPath ''{0}'')' -f $b
            }
        }
        [PSCustomObject]@{
            Name         = 'codex'
            Command      = 'codex'
            Kind         = 'repl'
            IsDefault    = $false
            InstallArgs  = @('npm', 'i', '-g', '@openai/codex@0.160.0')  # pinned (#765)
            # 'codex login status' is a lightweight auth check (no stdin read, ~2.6s)
            # vs. the old 'codex exec' probe which took ~19.5s and reads stdin.
            Probe        = { param($ctx) Invoke-CliProbe @('codex', 'login', 'status') }
            BypassArgs   = '--dangerously-bypass-approvals-and-sandbox'
            RequiresBypass = $false
            KeepEnv      = @('OPENAI_API_KEY')
            BuildLaunch  = {
                param($ctx)
                # 'codex exec' reads stdin even with a prompt arg - in a wt tab (TTY
                # stdin) that hangs waiting for input. Piping $null gives it immediate
                # EOF so it proceeds using only the prompt argument.
                $b = $ctx.BriefingFile -replace "'", "''"
                $bypass = if ($ctx.AllowBypass) { ' --dangerously-bypass-approvals-and-sandbox' } else { '' }
                '$null | codex exec (Get-Content -Raw -LiteralPath ''{0}''){1}' -f $b, $bypass
            }
        }
        [PSCustomObject]@{
            Name         = 'copilot'
            Command      = 'copilot'
            Kind         = 'repl'
            IsDefault    = $false
            InstallArgs  = @('npm', 'i', '-g', '@github/copilot@1.0.91')  # pinned (#765)
            # Auth/quota probe without the bypass (#761): a one-token reply calls no tool.
            Probe        = { param($ctx) Invoke-CliProbe @('copilot', '-p', 'reply OK') }
            BypassArgs   = '--allow-all'
            RequiresBypass = $false
            KeepEnv      = @('COPILOT_GITHUB_TOKEN')
            BuildLaunch  = {
                param($ctx)
                $b = $ctx.BriefingFile -replace "'", "''"
                $bypass = if ($ctx.AllowBypass) { ' --allow-all' } else { '' }
                'copilot -p (Get-Content -Raw -LiteralPath ''{0}''){1}' -f $b, $bypass
            }
        }
    )
}

# Classify a probe outcome into one status word. Pure -> unit-testable.
# Order matters: quota/rate-limit and auth are checked FIRST, even on exit 0 -
# some CLIs (observed live) print an error message but wrongly exit 0, so a
# generic exit-0 "ok" short-circuit would hide a real quota/auth failure.
function Get-CliProbeStatus([int]$ExitCode, [string]$Stderr) {
    $s = "$Stderr".ToLower()
    if ($s -match 'rate.?limit|quota|429|resource.?exhausted|too many requests') { return 'no-quota' }
    if ($s -match '401|403|unauthor|authenticat|not logged in|login required')   { return 'auth' }
    if ($ExitCode -eq 0) { return 'ok' }
    return 'error'
}

# Shared probe runner for 'repl' CLIs that accept a one-shot prompt: run the
# adapter's probe command, capture exit code + stderr, classify. Each adapter's
# Probe scriptblock calls this with its own argument list (filled per CLI in the
# spike tasks). Kept separate so Test-CliAvailability can be tested with a mock Probe.
# Runs the command in a background job with a timeout so a slow/hung CLI (e.g.
# codex exec waiting on stdin) can never block the fleet launch indefinitely.
function Invoke-CliProbe([string[]]$CommandLine, [int]$TimeoutSec = 30) {
    $exe  = $CommandLine[0]
    $rest = @($CommandLine[1..($CommandLine.Count-1)])
    $j = Start-Job { param($e,$a) $o = & $e @a 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o } } -ArgumentList $exe, $rest
    if (Wait-Job $j -Timeout $TimeoutSec) {
        $r = Receive-Job $j; Remove-Job $j -Force
        return Get-CliProbeStatus $r.Exit $r.Out
    }
    Stop-Job $j; Remove-Job $j -Force
    return 'error'
}

# Availability = installed on PATH AND (for repl CLIs) a live probe. Returns
# { Cli, Status, Detail }. Status in ok/no-quota/auth/not-installed/error.
function Test-CliAvailability {
    param([Parameter(Mandatory)][object]$Adapter)
    if (-not (Get-Command $Adapter.Command -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Cli=$Adapter.Name; Status='not-installed'; Detail="$($Adapter.Command) is not on PATH" }
    }
    $status = & $Adapter.Probe $null
    return [PSCustomObject]@{ Cli=$Adapter.Name; Status=$status; Detail='' }
}

# A CLI that cannot work unattended without its permission bypass (RequiresBypass) is
# reported 'needs-bypass' unless the human opted in with -AllowPermissionBypass (#761), so
# the picker never offers it and Resolve-LaunchCli degrades its issue to claude. Pure.
function Resolve-BypassAvailability([object]$Adapter, [string]$Status, [bool]$AllowBypass) {
    if ($Status -eq 'ok' -and $Adapter.RequiresBypass -and -not $AllowBypass) { return 'needs-bypass' }
    return $Status
}

# One visible line stating the permission mode the launched sessions will run under (#761).
# Returns the text so it can be asserted; prints it in red when the bypass is on.
function Write-PermissionModeNotice([bool]$AllowBypass) {
    if ($AllowBypass) {
        $msg = "  WARNING: -AllowPermissionBypass - launched sessions run with each CLI's permission BYPASS flag: they can edit files and run commands without asking. Only the PreToolUse brake still applies."
        Write-Host $msg -ForegroundColor Red
    } else {
        $msg = "  Permissions: each session uses its CLI's own permission mode and your allow-list (a headless session is denied, not asked, for anything outside it). Opt in to the bypass with -AllowPermissionBypass."
        Write-Host $msg -ForegroundColor DarkGray
    }
    return $msg
}

# The v1 safety net: an unavailable chosen CLI silently degrades to claude (the
# always-present default), never aborting the batch. Pure -> unit-testable.
function Resolve-LaunchCli([string]$Chosen, [hashtable]$Availability) {
    if ($Chosen -and $Availability[$Chosen] -eq 'ok') { return $Chosen }
    return 'claude'
}

# Pure core of the picker: given issues + raw choices + live availability, resolve each
# issue to an available CLI (Resolve-LaunchCli enforces fallback). Unit-testable.
function Resolve-IssueCliMap([int[]]$Issues, [hashtable]$Choices, [hashtable]$Availability) {
    $map = @{}
    foreach ($i in $Issues) {
        $chosen = if ($Choices.ContainsKey($i)) { $Choices[$i] } else { 'claude' }
        $map[$i] = Resolve-LaunchCli -Chosen $chosen -Availability $Availability
    }
    return $map
}

# Render the availability table: one colored line per CLI on the console, and the
# same plain line emitted to the pipeline so callers (and tests, via Out-String) can
# capture the rendered text. Green ok / yellow otherwise.
function Show-CliAvailability([hashtable]$Availability) {
    foreach ($cli in ($Availability.Keys | Sort-Object)) {
        $st = $Availability[$cli]
        $color = if ($st -eq 'ok') { 'Green' } else { 'DarkYellow' }
        $line = "  {0,-8} {1}" -f $cli, $st
        Write-Host $line -ForegroundColor $color
        $line
    }
}

# The install command as text, for display. Pure.
function Get-CliInstallText([object]$Adapter) {
    if ($Adapter.InstallArgs) { return (@($Adapter.InstallArgs) -join ' ') }
    if ($Adapter.InstallUrl)  { return "see $($Adapter.InstallUrl)" }
    return ''
}

# Install a not-installed CLI after explicit user approval, then re-probe. Impure.
# Runs a PINNED argv (#765), never a string through Invoke-Expression; a CLI with no pinnable
# package (InstallArgs = $null) is never installed by the tool - the user gets the page instead.
function Install-CliOnApproval([object]$Adapter) {
    if (-not $Adapter.InstallArgs) {
        Write-Host ("  {0} is not installed. Install it yourself: {1}" -f $Adapter.Name, $Adapter.InstallUrl) -ForegroundColor Yellow
        return $false
    }
    Write-Host ("  {0} is not installed. Command: {1}" -f $Adapter.Name, (Get-CliInstallText $Adapter)) -ForegroundColor Yellow
    $ans = Read-Host "  Install now? (y/N)"
    if ($ans -notmatch '^[sSyY]') { Write-Host "  Skipped." -ForegroundColor DarkGray; return $false }
    $argv = @($Adapter.InstallArgs)
    & $argv[0] @($argv | Select-Object -Skip 1)
    return ($LASTEXITCODE -eq 0)
}

# Interactive per-issue picker: prints availability, prompts a CLI per issue, then
# resolves through the pure core. Returns the issue->cli map.
function Select-CliPerIssue([int[]]$Issues, [hashtable]$Availability) {
    Show-CliAvailability $Availability | Out-Null
    $available = @($Availability.Keys | Where-Object { $Availability[$_] -eq 'ok' })
    $choices = @{}
    foreach ($i in $Issues) {
        $ans = Read-Host ("  Which assistant works issue #{0}? [{1}] (Enter = claude)" -f $i, ($available -join '/'))
        if ($ans) { $choices[$i] = $ans.Trim().ToLower() }
    }
    return Resolve-IssueCliMap -Issues $Issues -Choices $choices -Availability $Availability
}

# Pair each started worktree with the CLI the picker resolved for it. Pure.
function Build-FleetPlan([object[]]$Started, [hashtable]$CliMap) {
    foreach ($r in $Started) {
        $cli = if ($CliMap.ContainsKey($r.issue)) { $CliMap[$r.issue] } else { 'claude' }
        [PSCustomObject]@{ issue=$r.issue; repo=$r.repo; branch=$r.branch; workPath=$r.workPath; cli=$cli }
    }
}
