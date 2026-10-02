# BoardWork.Adapters.ps1 - the CLI adapter registry, probes and per-issue CLI picker,
# extracted VERBATIM from Board-Work.ps1 (#759). Function definitions only; Board-Work
# dot-sources this file before its own dot-source guard, so tests see the same surface.
# Get-ReviewerRoster.ps1 dot-sources it too, for the probe classifier (#770).

# =======================================================================
# Probe codes (#770): a CLOSED set. Every probe result is exactly one of these six.
#
# Before #770 one Get-CliProbeStatus ran a single regex list over every CLI's output, returned
# free-form words ('ok', 'no-quota', ...), and called anything that tripped no failure regex on
# exit 0 'ok'. "Nothing looked wrong" is not "it works": that is the same false-pass shape that
# let a refusal pass for a review in #651. Now:
#   * each adapter declares how ITS output reads (ProbeRules, an ordered list), so a Copilot
#     quota message and a jules session listing are handled where they are known;
#   * OK needs POSITIVE evidence - an adapter's OK rule matching on exit 0. A quota or limit
#     message on exit 0 therefore never reads as OK;
#   * output no rule recognises fails CLOSED to ERROR, never to OK.
# =======================================================================
function Get-CliProbeCodes { @('OK', 'AUTH', 'RATE_LIMIT', 'QUOTA', 'CONTEXT_WINDOW', 'ERROR') }

# Availability states that are NOT probe results, kept outside the probe set on purpose:
#   NOT_INSTALLED  the command is not on PATH - the probe never ran. Folding it into ERROR would
#                  hide the one state the fleet can fix (it offers the install).
#   NEEDS_BYPASS   the probe said OK, but the CLI cannot run unattended without a permission
#                  bypass the human did not opt in to (#761).
function Get-CliAvailabilityStates { @(Get-CliProbeCodes) + @('NOT_INSTALLED', 'NEEDS_BYPASS') }

# Pin a value to the closed set. Case-SENSITIVE on purpose: a leftover 'ok' from an old-style
# probe is not 'OK', and anything outside the set fails closed to ERROR. Pure.
function Confirm-CliProbeCode([string]$Code) {
    if ((Get-CliProbeCodes) -ccontains $Code) { return $Code }
    return 'ERROR'
}

# One classification rule: when Pattern matches the probe output, the result is Code. An OK rule
# only counts on exit 0; every other rule counts on any exit code (some CLIs print a quota or auth
# error and still exit 0). Reason is the human sentence a caller may print.
function New-CliProbeRule([string]$Code, [string]$Pattern, [string]$Reason) {
    [PSCustomObject]@{ Code = (Confirm-CliProbeCode $Code); Pattern = $Pattern; Reason = $Reason }
}

# Generic API-failure shapes several CLIs share. An adapter places them in its own ProbeRules
# where they belong in ITS order - this is not a global pass over every output. Phrases, not bare
# words: a healthy banner can say "Quota remaining: 500" or carry "401" inside an id (#537).
# QUOTA is checked before RATE_LIMIT: "429: quota exceeded" is the long wait, not the short one.
function Get-CliCommonProbeRules {
    @(
        New-CliProbeRule 'CONTEXT_WINDOW' '(?i)context (window|length) (exceeded|is full)|maximum context length|prompt is too long|exceeds? the context window' 'the prompt does not fit the model context window'
        New-CliProbeRule 'QUOTA' '(?i)quota (exceeded|exhausted|reached|limit)|(exceeded|out of|no) (your )?(quota|credits)|insufficient[_ ]quota|resource.?exhausted' 'out of quota'
        New-CliProbeRule 'RATE_LIMIT' '(?i)rate.?limit(ed)?\b|too many requests|\b(http|status|error|code)[ :=]*429\b' 'rate limited - retry later'
        New-CliProbeRule 'AUTH' '(?i)not logged in|logged out|login required|unauthori[sz]ed|unauthenticated|not authenticated|please (log ?in|sign ?in)|\b(http|status|error|code)[ :=]*40[13]\b' 'not authenticated'
    )
}

# Map one probe run to { Code; Reason }. Walks the adapter's ProbeRules IN ORDER and the first
# match wins; with no match the result is ERROR (fails closed). -Rules overrides the lookup so
# the classifier can be exercised without the registry. Pure.
function Resolve-CliProbeOutcome {
    param(
        [string]$Cli,
        [int]$ExitCode,
        [AllowEmptyString()][AllowNull()][string]$Output,
        [object[]]$Rules
    )
    if (-not $PSBoundParameters.ContainsKey('Rules')) {
        $adapter = Get-CliAdapters | Where-Object Name -eq $Cli | Select-Object -First 1
        $Rules   = if ($adapter) { @($adapter.ProbeRules) } else { @() }
    }
    $text = "$Output"
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        if ($r.Code -ceq 'OK' -and $ExitCode -ne 0) { continue }
        if ($text -match $r.Pattern) {
            return [PSCustomObject]@{ Code = (Confirm-CliProbeCode $r.Code); Reason = $r.Reason }
        }
    }
    $reason = if ($ExitCode -ne 0) { "exited $ExitCode with output no rule recognises" }
              elseif (-not $text.Trim()) { 'exited 0 but printed nothing - that is no evidence the CLI works' }
              else { 'exited 0 but the output is not the expected answer (unrecognised output fails closed)' }
    return [PSCustomObject]@{ Code = 'ERROR'; Reason = $reason }
}

# Just the code. Pure.
function ConvertTo-CliProbeCode([string]$Cli, [int]$ExitCode, [string]$Output) {
    (Resolve-CliProbeOutcome -Cli $Cli -ExitCode $ExitCode -Output $Output).Code
}

# A CLI that is out of quota or rate limited is skipped for the rest of a fleet run (the runtime
# backoff of Invoke-FleetDispatch); any other non-OK state is handled by the claude fallback. Pure.
function Test-CliProbeExhausted([string]$Code) { @('QUOTA', 'RATE_LIMIT') -ccontains $Code }

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
            # claude is the host CLI running this very script -> always available, so its probe
            # runs nothing. Its rules still classify claude's own output shapes (#770) - the
            # same messages a launched claude session dies with.
            Probe        = { param($ctx) 'OK' }
            ProbeRules   = @(
                New-CliProbeRule 'QUOTA' '(?i)usage limit reached|credit balance is too low|out of extra usage' 'Claude usage limit reached'
                New-CliProbeRule 'RATE_LIMIT' '(?i)rate_limit_error' 'rate limited - retry later'
                New-CliProbeRule 'AUTH' '(?i)invalid api key|please run /login|authentication_error|oauth token (has )?expired' 'not logged in (run /login or set the auth variable)'
                New-CliProbeRule 'CONTEXT_WINDOW' '(?i)prompt is too long' 'the prompt does not fit the model context window'
                Get-CliCommonProbeRules
                New-CliProbeRule 'OK' '(?i)\bOK\b' 'answered'
            )
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
            # One-token probe of auth/quota (classified by ProbeRules, #770). It carries NO permission
            # bypass (#761): a one-token reply calls no tool, so the flag made no difference to
            # it - measured 10s without it and 8s with it, exit 0 and 'OK' both ways.
            Probe        = { param($ctx) Invoke-CliProbe @('agy', '-p', 'reply OK') -Cli 'antigravity' }
            # Google's retired-client answer (IneligibleTierError / UNSUPPORTED_CLIENT) arrives on
            # exit 0 (#537, #615): it is an AUTH failure, never an answer. OK = it replied OK.
            ProbeRules   = @(
                New-CliProbeRule 'AUTH' '(?i)IneligibleTier|UNSUPPORTED_CLIENT|no longer supported' 'the provider retired this client (it can no longer authenticate)'
                New-CliProbeRule 'ERROR' '(?i)not running in a trusted directory|skip-trust|TRUST_WORKSPACE' 'refuses to run outside a trusted directory'
                Get-CliCommonProbeRules
                New-CliProbeRule 'OK' '(?i)\bOK\b' 'answered'
            )
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
            Probe        = { param($ctx) Invoke-CliProbe @('jules', 'remote', 'list', '--session') -Cli 'jules' }
            # OK = the session table's header row. It comes BEFORE the shared failure phrases on
            # purpose: the rows are the user's own session titles, and a title such as "fix the
            # rate limit" must not read as a rate limit. "Must specify what to list" (exit 0)
            # matches no rule, so it fails closed to ERROR.
            ProbeRules   = @(
                New-CliProbeRule 'AUTH' '(?i)jules login|not signed in|sign in to jules' 'not logged in (run jules login)'
                New-CliProbeRule 'OK' '(?m)^\s*ID\s+Description\s+Repo\s+Last active\s+Status\b' 'listed its sessions'
                Get-CliCommonProbeRules
            )
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
            Probe        = { param($ctx) Invoke-CliProbe @('codex', 'login', 'status') -Cli 'codex' }
            # 'Logged in using ChatGPT' / 'Logged in using an API key'. 'Not logged in' is matched
            # first, so the OK rule's 'Logged in' can never be read inside it.
            ProbeRules   = @(
                New-CliProbeRule 'AUTH' '(?im)^\s*not logged in|codex login' 'not logged in (run codex login)'
                Get-CliCommonProbeRules
                New-CliProbeRule 'OK' '(?im)^\s*logged in\b' 'logged in'
            )
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
            Probe        = { param($ctx) Invoke-CliProbe @('copilot', '-p', 'reply OK') -Cli 'copilot' }
            # Copilot's healthy footer says "Total usage est: 1 Premium request", so the words
            # "premium request" alone are NOT a quota signal - only running out of them is.
            ProbeRules   = @(
                New-CliProbeRule 'QUOTA' '(?i)(exceeded|reached|used up|out of|no remaining)\W+(\w+\W+){0,6}premium requests?|\b402\b' 'out of Copilot premium requests'
                New-CliProbeRule 'AUTH' '(?i)no authentication information found|use /login|copilot login' 'not logged in to Copilot'
                Get-CliCommonProbeRules
                New-CliProbeRule 'OK' '(?i)\bOK\b' 'answered'
            )
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

# Shared probe runner: run the adapter's probe command, capture exit code + output, and
# classify it with THAT adapter's ProbeRules (-Cli names it; #770). Each adapter's Probe
# scriptblock calls this with its own argument list. Kept separate so Test-CliAvailability
# can be tested with a mock Probe.
# Runs the command in a background job with a timeout so a slow/hung CLI (e.g.
# codex exec waiting on stdin) can never block the fleet launch indefinitely - a timeout is
# ERROR, never a guess.
function Invoke-CliProbe([string[]]$CommandLine, [int]$TimeoutSec = 30, [string]$Cli) {
    $exe  = $CommandLine[0]
    $rest = @($CommandLine[1..($CommandLine.Count-1)])
    $j = Start-Job { param($e,$a) $o = & $e @a 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o } } -ArgumentList $exe, $rest
    if (Wait-Job $j -Timeout $TimeoutSec) {
        $r = Receive-Job $j; Remove-Job $j -Force
        return ConvertTo-CliProbeCode -Cli $Cli -ExitCode $r.Exit -Output $r.Out
    }
    Stop-Job $j; Remove-Job $j -Force
    return 'ERROR'
}

# Availability = installed on PATH AND (for repl CLIs) a live probe. Returns
# { Cli, Status, Detail }. Status is a probe code (Get-CliProbeCodes), or NOT_INSTALLED when
# the probe never ran. Whatever the Probe returns is pinned to the closed set (#770): a probe
# that answers anything else - including an old lower-case 'ok' - is ERROR.
function Test-CliAvailability {
    param([Parameter(Mandatory)][object]$Adapter)
    if (-not (Get-Command $Adapter.Command -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Cli=$Adapter.Name; Status='NOT_INSTALLED'; Detail="$($Adapter.Command) is not on PATH" }
    }
    $status = Confirm-CliProbeCode (& $Adapter.Probe $null)
    return [PSCustomObject]@{ Cli=$Adapter.Name; Status=$status; Detail='' }
}

# A CLI that cannot work unattended without its permission bypass (RequiresBypass) is
# reported NEEDS_BYPASS unless the human opted in with -AllowPermissionBypass (#761), so
# the picker never offers it and Resolve-LaunchCli degrades its issue to claude. Pure.
function Resolve-BypassAvailability([object]$Adapter, [string]$Status, [bool]$AllowBypass) {
    if ($Status -ceq 'OK' -and $Adapter.RequiresBypass -and -not $AllowBypass) { return 'NEEDS_BYPASS' }
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
    if ($Chosen -and $Availability[$Chosen] -ceq 'OK') { return $Chosen }
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
# capture the rendered text. Green OK / yellow otherwise.
function Show-CliAvailability([hashtable]$Availability) {
    foreach ($cli in ($Availability.Keys | Sort-Object)) {
        $st = $Availability[$cli]
        $color = if ($st -ceq 'OK') { 'Green' } else { 'DarkYellow' }
        $line = "  {0,-11} {1}" -f $cli, $st
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
    $available = @($Availability.Keys | Where-Object { $Availability[$_] -ceq 'OK' })
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
