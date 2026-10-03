# BoardWork.Launch.ps1 - the session launcher (briefing, brake, secret scrub, launch script,
# spawn) and the fleet dashboard, extracted VERBATIM from Board-Work.ps1 (#759: the directory
# rejects files over 256 KiB). Function definitions only; Board-Work dot-sources this file
# before its own dot-source guard, so tests and callers see the same surface as before.

# =======================================================================
# Parallel session launcher (mode 5 -Launch): one visible Claude session per
# worktree, each briefed to work its own issue end-to-end.
# =======================================================================

# Compute the effective brake for a launched session (#598).
# All launched sessions stop at a reviewed PR by default — a session that merges its
# own PR has no human review and the board has no safety check on the result (proven on
# 2026-08-03: two sessions merged unreviewed, one shipped a DoD item it had not built).
# -AllowMerge is the explicit opt-in for autonomous merging; -StopAtPR:$false from an
# expert contract that allows merging is also honoured. -AllowMerge beats everything.
# Pure (no side effects) -> unit-testable. Called from the -Launch and -Fleet paths.
function Resolve-LaunchBrake {
    param(
        [bool]$AllowMerge,
        # Was -StopAtPR explicitly bound by the caller? ($PSBoundParameters.ContainsKey('StopAtPR'))
        [bool]$StopAtPRBound,
        [bool]$StopAtPR
    )
    if ($AllowMerge) { return $false }
    if ($StopAtPRBound) { return $StopAtPR }
    return $true    # default: brake for every fleet/launch session (#598)
}

# How the session briefing NAMES a plugin script so the session can run it (#480).
# The briefing used to hard-code `plugins/agentic-board/scripts/<name>`, a path relative to the
# session's working directory that exists in exactly one repository - this one. In every
# consumer project the four commands pointed at nothing, the session improvised a bare
# `gh pr create`, and the review gate never ran.
#   1. The session's own working copy carries the plugin (this repo, or one that vendors it):
#      keep the relative form. It resolves from the session's cwd exactly as before and runs
#      the branch's own copy of the script.
#   2. Anywhere else: the copy of the script sitting next to the one that is composing the
#      briefing - the same install, so it exists by construction. Forward slashes (safe for pwsh
#      on Windows), quoted only when the path has whitespace.
#   3. Neither exists: say so (found = $false) so the briefing can report it instead of naming a
#      path that leads nowhere.
# The absolute form embeds the install's directory, which is version-pinned for a marketplace
# install; that directory stays on disk while the session that was handed it runs.
function Resolve-BriefingScriptRef {
    param([string]$Name, [string]$WorkPath, [string]$ScriptsDir)
    $rel = "plugins/agentic-board/scripts/$Name"
    if ($WorkPath -and (Test-Path -LiteralPath (Join-Path $WorkPath $rel))) {
        return [pscustomobject]@{ ref = $rel; found = $true }
    }
    $abs = if ($ScriptsDir) { Join-Path $ScriptsDir $Name } else { '' }
    if ($abs -and (Test-Path -LiteralPath $abs)) {
        $p = $abs -replace '\\', '/'
        if ($p -match '\s') { $p = '"' + $p + '"' }
        return [pscustomobject]@{ ref = $p; found = $true }
    }
    return [pscustomobject]@{ ref = $rel; found = $false }
}

# The one-line first message a spawned Claude session receives. Pure -> testable.
# -Cli is threaded (default 'claude') so Phase-2 adapters can specialize the leading
# autonomy sentence per CLI without another signature change; Phase 1 keeps the
# body text identical for every repl CLI.
#
# -StopAtPR is the irreversible brake (#440). The auto-expert's contract can mark `merge` as
# irreversible, but that brake used to live ONLY in expert-brief-<n>.md - a file this launcher
# never read - while THIS briefing ordered the merge outright and made it the completion
# condition. A session that merged to main was obeying its brief, not defying it. With the
# brake on, the merge step is never emitted and the finish line moves to a reviewed PR.
# -BriefFile is the other half: it hands the session the expert brief it was never given.
#
# -ScriptsDir is where the plugin scripts live; it defaults to THIS script's own folder, so a
# briefing names scripts that exist on the machine that composed it (#480). A parameter so a test
# can point it at a folder that lacks a script.
function Get-SessionBriefing {
    param(
        [int]$issueNum,
        [string]$repo,
        [string]$branch,
        [string]$workPath,
        [string]$Cli = 'claude',
        [switch]$StopAtPR,
        [string]$BriefFile = '',
        [string]$ScriptsDir = '',
        # Cross-repo issue (#487): the work goes to these OTHER repos (or, with -CrossRepo alone, to
        # repos the issue names itself). The session is told this worktree is its base, not the
        # destination, and to open one PR per target repo.
        [string[]]$TargetRepos = @(),
        [switch]$CrossRepo,
        # -Surface app (#710 P1): this session's worktree does not exist yet when the briefing is
        # composed - the host creates it, not this script (that is the whole point of the surface).
        # $workPath is typically empty here; the "on branch X in this worktree (Y)" sentence below
        # would otherwise read as "in this worktree ()".
        [switch]$HostManaged
    )
    if (-not $ScriptsDir) { $ScriptsDir = $PSScriptRoot }
    $isCross = ($CrossRepo -or @($TargetRepos).Count -gt 0)
    # Every plugin script the briefing names, resolved so the session can actually run it.
    $needed = @('Fleet-Findings', 'Fleet-Handoff', 'Fleet-Ownership', 'New-BoardPR', 'Board-ReviewGate')
    if (-not $StopAtPR) { $needed += 'Board-Merge' }
    if ($isCross)       { $needed += 'Board-Work' }
    $sc = @{}; $unreachable = @()
    foreach ($n in $needed) {
        $r = Resolve-BriefingScriptRef -Name "$n.ps1" -WorkPath $workPath -ScriptsDir $ScriptsDir
        $sc[$n] = $r.ref
        if (-not $r.found) { $unreachable += "$n.ps1" }
    }
    # An unreachable script must be REPORTED, not routed around: a session that could not find
    # New-BoardPR.ps1 used to improvise a bare `gh pr create`, losing the identity resolution,
    # the push-permission check and the credential helper, and skipped the review gate without
    # anyone being told (#480). The standing sentence covers a script that exists but fails.
    $noSubstitute = "If a script named here is missing or fails to run, STOP and report exactly which one and why - " +
                    "do NOT replace New-BoardPR.ps1 with a bare 'gh pr create' and do NOT skip the review gate: " +
                    "they carry the account check and the review, and a substitute drops both silently. "
    if ($unreachable.Count -gt 0) {
        $noSubstitute = "WARNING - these plugin scripts were NOT found on this machine: " + ($unreachable -join ', ') +
                        ". Report that as a broken install before doing anything else. " + $noSubstitute
    }
    # Steps after the review gate are renumbered so the brake never leaves a hole at (5).
    $mergeStep = if ($StopAtPR) { "" } else {
        "(5) merge it (ruleset-safe): pwsh $($sc['Board-Merge']) -PR <pr> ; "
    }
    $recordNum = if ($StopAtPR) { "(5)" } else { "(6)" }
    # Cross-repo swaps steps (2)-(4) for the one-PR-per-target-repo flow, and never lets the session
    # close the issue: it closes when ALL its PRs have merged, which is the human's call.
    $flow = "(2) implement it fully in this worktree and commit your changes ; " +
            "(3) open the PR with: pwsh $($sc['New-BoardPR']) -Issue $issueNum " +
            "and note the PR number it prints ; " +
            "(4) pass the review gate: pwsh $($sc['Board-ReviewGate']) -PR <pr> ; " +
            "address any feedback and re-run until it is green ; "
    if ($isCross) {
        $flow = Format-CrossRepoBriefing -IssueNum $issueNum -HomeRepo $repo -TargetRepos $TargetRepos -Refs $sc
        $mergeStep = if ($StopAtPR) { "" } else { "(5) merge each PR (ruleset-safe): pwsh $($sc['Board-Merge']) -Repo <target owner/name> -PR <pr> ; " }
        $flow += "Do NOT close issue #$issueNum yourself: it stays open until ALL of its PRs are merged. "
    }
    $closing = if ($StopAtPR) {
        "Then STOP: leave the PR open and ready for the human to merge. Your contract marks the " +
        "merge as irreversible - do NOT merge, deploy, publish or delete anything, and do not " +
        "treat the merge as your finish line. You are done when the PR is open, the review gate " +
        "is green and your findings are recorded."
    } else {
        "When the PR is merged and your findings recorded, you are done."
    }
    $briefLine = if ($BriefFile) {
        "Your full brief for this run is at $BriefFile - read it FIRST and follow it; where it " +
        "conflicts with the generic steps below, it overrides them. "
    } else { "" }
    # Host-managed (#710 P1): the host created THIS session's worktree - never claim one this
    # script planned (there may not even be one at this exact path yet).
    $worktreeClause = if ($HostManaged) {
        "on branch $branch. Your host application created this session's own worktree for you - " +
        "you are already inside it. Never create another worktree or switch branches. "
    } else {
        "on branch $branch in this worktree ($workPath). "
    }
    return ($briefLine +
            "You are running AUTONOMOUSLY - permissions are pre-approved, so work this " +
            "task end-to-end WITHOUT stopping to ask for confirmation. " +
            "Pick up GitHub issue #$issueNum in $repo. It is already In Progress and claimed, " +
            $worktreeClause +
            "COMMIT WITH AN EXPLICIT PATHSPEC - 'git commit -m <message> -- <paths>' - never a bare 'git commit' after 'git add': " +
            "a bare commit takes whatever else is staged in the index, and if another session ever touches this folder your branch " +
            "ends up carrying its files under your message. " +
            "FIRST load fleet coordination context so you collaborate with sibling sessions: " +
            "read prior findings with 'pwsh $($sc['Fleet-Findings']) -List' ; " +
            "inherit any upstream hand-off with 'pwsh $($sc['Fleet-Handoff']) -Context -Issue $issueNum' ; " +
            "and once you know which files you will edit, claim them with " +
            "'pwsh $($sc['Fleet-Ownership']) -Claim -Issue $issueNum -Branch $branch -Paths <files>' " +
            "(if it warns of overlap with another live session, steer clear of those files). Then: " +
            "(1) read it with: gh issue view $issueNum --repo $repo ; " +
            $flow +
            $mergeStep +
            "$recordNum record what you learned for other sessions with " +
            "'pwsh $($sc['Fleet-Findings']) -Add -Issue $issueNum -Status done -Files <files touched> -Decisions <key decisions> -Gotchas <pitfalls>' " +
            "and free your files with 'pwsh $($sc['Fleet-Ownership']) -Release -Issue $issueNum' . " +
            $noSubstitute +
            "Work ONLY this issue - never touch other worktrees or issues. " + $closing)
}

# The briefing for a LOW-TRUST CLI (#773, dsh). It runs in a container that holds the worktree at
# /work and nothing else: no gh, no pwsh, no plugin scripts, no GitHub token. So it is given the
# issue text itself (it cannot fetch it) and exactly one job - edit files - and told plainly that
# git, the PR and the network are not its business: the human reviews `git diff` and opens the PR.
# The body is the issue's own text, capped so a huge issue cannot crowd out the instructions. Pure.
$script:ContainerBriefBodyCap = 8000
function Get-ContainerEditBriefing {
    param([int]$IssueNum, [string]$Repo, [string]$Title, [string]$Body)
    $text = "$Body".Trim()
    if ($text.Length -gt $script:ContainerBriefBodyCap) { $text = $text.Substring(0, $script:ContainerBriefBodyCap) + "`n[... issue text truncated]" }
    if (-not $text) { $text = '(the issue has no description)' }
    @(
        "Issue #$IssueNum in $Repo - $Title"
        ''
        '--- issue text ---'
        $text
        '--- end of issue text ---'
        ''
        'Your job: edit the files in the current directory (/work, a checkout of the repository) so that they resolve this issue. Keep the change to what the issue asks for.'
        'That is the whole job. Only read and edit files under /work.'
        'Do NOT run git (no add, commit, branch or push), do NOT try to open a pull request or comment on the issue, and do NOT use the network: a person reviews your edits and does all of that.'
        'When you are done, reply with a short summary of the files you changed and why.'
    ) -join "`n"
}

# -- Fleet session marker (reaper fingerprint) ---------------------------------
# Every fleet-spawned session is stamped at launch with ABIOS_FLEET_SESSION=<issue>-<runId>
# in its generated launch-<n>.ps1, so the child (claude/antigravity/...) and its CLI grandchild
# carry it in their environment. The task reaper (Find-FleetOrphans) keys on this marker -
# a far stronger discriminator than a bare binary name, since the operator runs many
# unrelated claude/node processes.

# A short per-run token that ties together all sessions launched in one dispatch.
function New-FleetRunId { [guid]::NewGuid().ToString('N').Substring(0, 8) }

# Compose the marker for one session. PURE -> unit-testable. The runId is reduced to a bare
# alphanumeric token so the marker is safe to embed verbatim in a single-quoted env
# assignment AND to match later with a WQL/`-like` fingerprint (no quotes, spaces or slashes).
function New-FleetSessionMarker([int]$IssueNum, [string]$RunId) {
    $safe = ($RunId -replace '[^A-Za-z0-9]', '')
    return ("{0}-{1}" -f $IssueNum, $safe)
}

# Build the exact launch command for a worktree session. Returns an object
# { launcher, args, briefingFile, launchScriptFile, launchScript } WITHOUT spawning -
# pure enough to unit-test and to preview under -DryRun. Windows Terminal tab when
# 'wt' exists (grouped in a named window), else a standalone pwsh window.
#
# CRITICAL - why the setup runs from a .ps1 FILE, not an inline `-Command`:
# Windows Terminal's `wt` command line uses ';' as its OWN sub-command separator
# (new-tab ; split-pane ; ...). A `pwsh -Command "a; b; c"` passed to `wt` therefore
# had its ';' eaten by wt, which split ONE intended tab into FOUR (one per segment) -
# 2 issues -> 8 stray tabs, and the real `claude -p` landed in a bare tab with no
# auth setup, so no session actually worked its issue. Writing the setup+run to
# launch-<issue>.ps1 and launching `pwsh -NoExit -File <script>` puts ZERO ';' on
# wt's command line, so wt opens exactly one tab. The briefing is likewise passed by
# file so no long/quoted text ever hits the command line.
# Secret scrub for a launched session (#769). A spawned CLI used to inherit the launcher's whole
# environment - every token, key and password the user had exported, including owner tokens the
# session has no business holding. The launch script now drops every variable whose NAME carries
# TOKEN, KEY, SECRET or PASSWORD, then puts back only an allowlist: the CLI's own model credential
# ($Keep) and ONE GitHub identity, exposed as GH_TOKEN, read from $GhTokenVar BEFORE the scrub.
#   - $GhTokenVar = 'GH_TOKEN'           -> unarmed run: the GH_TOKEN it inherited, unchanged.
#   - $GhTokenVar = 'GITHUB_TOKEN_AGENT' -> brake-armed run: the agent identity, never the owner's.
#   - $GhTokenVar = ''                   -> no GH_TOKEN: gh falls back to its own stored login.
# Values are captured from the process first, then the Windows USER scope (null elsewhere), and
# only NAMES ever reach the script text - never a value. Pure -> unit-testable.
# STATED LIMIT: this removes what the session INHERITS. A process running as the same user can
# still read the user's own stores (HKCU\Environment on Windows, a keyring, a dotfile).
function Get-SecretScrubScript([string[]]$Keep = @(), [string]$GhTokenVar = 'GH_TOKEN') {
    $names = @(@($Keep) + @($GhTokenVar) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($n in $names) {
        if ($n -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Scrub allowlist entry '$n' is not a valid environment variable name." }
    }
    $list = ($names | ForEach-Object { "'$_'" }) -join ','
    $lines = @(
        ('$abiosKeep = @{{}}; foreach ($n in @({0})) {{ $v = [Environment]::GetEnvironmentVariable($n); if (-not $v) {{ $v = [Environment]::GetEnvironmentVariable($n, ''User'') }}; if ($v) {{ $abiosKeep[$n] = $v }} }}' -f $list)
        'Get-ChildItem Env: | Where-Object { $_.Name -match ''TOKEN|KEY|SECRET|PASSWORD'' } | ForEach-Object { Remove-Item -LiteralPath (''Env:'' + $_.Name) -ErrorAction SilentlyContinue }'
        # The identity variable comes back ONLY as GH_TOKEN, never under its own name as well.
        ('foreach ($n in $abiosKeep.Keys) {{ if ($n -notin @(''GH_TOKEN'', ''{0}'')) {{ Set-Item -LiteralPath (''Env:'' + $n) -Value $abiosKeep[$n] }} }}' -f $GhTokenVar)
    )
    if ($GhTokenVar) { $lines += ('if ($abiosKeep[''{0}'']) {{ $env:GH_TOKEN = $abiosKeep[''{0}''] }}' -f $GhTokenVar) }
    $lines += 'Remove-Variable abiosKeep, n, v -ErrorAction SilentlyContinue'
    return ($lines -join "`r`n")
}

function Build-WorktreeLaunch([int]$issueNum, [string]$workPath, [string]$briefingFile, [string]$windowName = "abios-parallel", [string]$claudeAuthVar = "ANTHROPIC_API_KEY", [string]$Cli = 'claude', [string]$fleetSession = '', [string]$logPath = '', [bool]$allowBypass = $false, [string]$ghTokenVar = 'GH_TOKEN') {
    $tabTitle  = "issue-$issueNum"
    # Defense-in-depth: this name is interpolated into the spawned launch script,
    # so it MUST be a bare env-var identifier - never let ';'/quotes/spaces through.
    if ($claudeAuthVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "ClaudeAuthVar '$claudeAuthVar' is not a valid environment variable name."
    }
    # The spawned session is UNATTENDED, so it must never block on an interactive
    # prompt. Headless -p is the only mode that clears ALL of them: it skips the
    # new-worktree trust dialog AND the one-time "Bypass Permissions mode" accept
    # (both are interactive-only). ONLY with -AllowPermissionBypass (#761),
    # --permission-mode bypassPermissions keeps it from pausing on per-tool approvals;
    # by default the session keeps the user's own permission mode and allow-list
    # (headless -p denies, rather than asks for, a tool outside it). --no-session-persistence stops parallel
    # sessions colliding on session state, and --verbose streams progress into the
    # tab so it visibly works instead of looking frozen. (An interactive
    # --dangerously-skip-permissions launch still stops at the one-time bypass
    # accept, which is why the tabs opened but never finished.)
    #
    # AUTH: a `claude` child gets no usable OAuth when spawned under the Claude
    # Desktop host (the host holds/refreshes the token in memory and strips the env),
    # so each tab authenticates with an explicit credential read at RUNTIME from the
    # Windows USER env var named by $claudeAuthVar (default ANTHROPIC_API_KEY; set it
    # to CLAUDE_CODE_OAUTH_TOKEN to bill the subscription instead). Only the var NAME
    # touches the command line - the secret never does. Re-reading from the registry
    # also RESTORES the value even when the launching context (Desktop) has stripped
    # it. We FIRST clear every competing Anthropic credential so the chosen one is
    # authoritative regardless of auth precedence - ANTHROPIC_API_KEY outranks
    # CLAUDE_CODE_OAUTH_TOKEN, so an inherited API key would otherwise silently
    # override a subscription token (or 401 if stale). We also drop the inherited
    # CLAUDE_CODE_* session markers so the child starts as a clean top-level session.
    # Delegate the launch-script construction to the chosen CLI's adapter. The adapter
    # receives a context object and RETURNS the launch-script string; the claude adapter
    # reproduces the exact lines this function used to build inline (byte-identical).
    $ctx = @{
        IssueNum     = $issueNum
        WorkPath     = $workPath
        BriefingFile = $briefingFile
        TabTitle     = $tabTitle
        WindowName   = $windowName
        AuthVar      = $claudeAuthVar
        AllowBypass  = $allowBypass
    }
    $adapter = Get-CliAdapters | Where-Object { $_.Name -eq $Cli } | Select-Object -First 1
    if (-not $adapter) { throw "Unknown CLI adapter '$Cli'." }
    $launchScript = & $adapter.BuildLaunch $ctx
    # A low-trust CLI (dsh, #773) only edits files: it has no token, commits nothing and opens no PR,
    # and nothing here does it for it. When its container exits, the tab says what is left - for the
    # human. The worktree path is a single-quoted literal (quotes doubled), never code.
    if ($adapter.LowTrust) {
        $wpLit = "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($workPath) + "'"
        $launchScript += "`r`n" + ('Write-Host (''{0} finished (exit {{0}}). It does not commit, push or open a PR. Next step for you: review `git diff` in {{1}}, then commit and open the PR.'' -f $LASTEXITCODE, {1}) -ForegroundColor Yellow' -f $adapter.Name, $wpLit)
    }
    # Scrub inherited secrets before the CLI starts (#769): the model credential this adapter
    # authenticates with and one GitHub identity survive, nothing else matching the pattern does.
    $keep = @($claudeAuthVar) + @($adapter.KeepEnv | Where-Object { $_ })
    $launchScript = ((Get-SecretScrubScript -Keep $keep -GhTokenVar $ghTokenVar), $launchScript) -join "`r`n"
    # Stamp the reaper fingerprint FIRST (adapter-agnostic prefix), so it is in the
    # environment for the whole script and inherited by the CLI child + grandchild. The
    # marker is validated to a bare token so it can never break out of the '...' literal.
    if ($fleetSession) {
        # Exact marker shape (<issue>-<runId>): digits, a single '-', then alphanumerics.
        # '_' is deliberately NOT allowed - it is a WQL LIKE single-char wildcard, and this
        # token is matched as a process fingerprint by the reaper (a '_' would over-match).
        if ($fleetSession -notmatch '^[0-9]+-[A-Za-z0-9]+$') {
            throw "FleetSession '$fleetSession' is not a valid marker token (<issue>-<runId>)."
        }
        $markerLine   = '$env:ABIOS_FLEET_SESSION=''{0}''' -f $fleetSession
        $launchScript = ($markerLine, $launchScript) -join "`r`n"
    }
    # Session log redirection (#198): capture the whole session stream to a file the
    # -Sessions dashboard tails, while still showing it live in the tab. Start-Transcript
    # is adapter-agnostic (works for every CLI). Opt-in via $logPath so the golden claude
    # parity (which passes none) stays byte-identical. Single-quotes doubled so a path with
    # a ' cannot break the literal.
    if ($logPath) {
        $safeLog = $logPath -replace "'", "''"
        $safeDir = (Split-Path -Parent $logPath) -replace "'", "''"
        $transcript = @(
            ('New-Item -ItemType Directory -Force -Path ''{0}'' *> $null' -f $safeDir)
            ('Start-Transcript -Path ''{0}'' -Append *> $null' -f $safeLog)
        ) -join "`r`n"
        $launchScript = ($transcript, $launchScript) -join "`r`n"
    }
    # The launch script lives next to the briefing (same dir the caller chose).
    $launchScriptFile = Join-Path (Split-Path -Parent $briefingFile) "launch-$issueNum.ps1"
    $safeScriptPath   = $launchScriptFile   # a plain path arg (its own arg element -> Start-Process quotes it)
    # Windows Terminal is Windows-only; elsewhere the session runs as a background pwsh whose output
    # goes to files next to the launch script (#767) - -NoExit would wait on a terminal that is not there.
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        return [PSCustomObject]@{
            launcher         = "pwsh"
            args             = @('-NoProfile', '-File', $safeScriptPath)
            briefingFile     = $briefingFile
            launchScriptFile = $launchScriptFile
            launchScript     = $launchScript
            fleetSession     = $fleetSession
            usesWt           = $false
            detached         = $true
            consoleLog       = ([System.IO.Path]::ChangeExtension($launchScriptFile, '.console.log'))
        }
    }
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{
            launcher         = "wt"
            args             = @('-w', $windowName, 'new-tab', '--title', $tabTitle,
                                 '--startingDirectory', $workPath, 'pwsh', '-NoExit', '-File', $safeScriptPath)
            briefingFile     = $briefingFile
            launchScriptFile = $launchScriptFile
            launchScript     = $launchScript
            fleetSession     = $fleetSession
            usesWt           = $true
        }
    }
    return [PSCustomObject]@{
        launcher         = "pwsh"
        args             = @('-NoExit', '-File', $safeScriptPath)
        briefingFile     = $briefingFile
        launchScriptFile = $launchScriptFile
        launchScript     = $launchScript
        fleetSession     = $fleetSession
        usesWt           = $false
    }
}

# Pick which Windows USER env var each spawned session authenticates with. Pure ->
# testable. An EXPLICIT -ClaudeAuthVar always wins; otherwise prefer the subscription
# OAuth token (CLAUDE_CODE_OAUTH_TOKEN, billed to the plan) when it is present, else
# fall back to the given default (ANTHROPIC_API_KEY, per-token console billing).
function Resolve-ClaudeAuthVar([bool]$explicit, [string]$chosen, [bool]$oauthTokenPresent) {
    if ($explicit) { return $chosen }
    if ($oauthTokenPresent) { return 'CLAUDE_CODE_OAUTH_TOKEN' }
    return $chosen
}

# Spawn (or -Preview) ONE visible Claude session for a started worktree.
function Start-WorktreeSession {
    param(
        [int]$IssueNum, [string]$Repo, [string]$Branch, [string]$WorkPath,
        [string]$ClaudeAuthVar = "ANTHROPIC_API_KEY",
        [string]$Cli = 'claude',
        [string]$FleetSession = '',
        [switch]$StopAtPR,
        [string]$BriefFile = '',
        [string[]]$Irreversible = @(),
    # The human ORDERED this run to finish end-to-end (#530). Travels with the instruction, not with
    # a setting on disk: it is recorded in the brake marker so the merge decision -- taken later,
    # when the facts exist -- still knows what was actually asked for.
    [switch]$EndToEnd,
        # Contract time budget in minutes, written into the brake marker for the hook to enforce (#564).
        [int]$SessionBudgetMinutes = 0,
        # Explicit opt-in to the CLI's permission bypass flag (#761). Off by default.
        [switch]$AllowPermissionBypass,
        # The issue's facts { labels; type; size; visibility; title; body } (#773, Get-IssueLaunchFacts).
        # A low-trust CLI is launched only when they put the issue on the docs/chore route of a
        # PUBLIC repo; without them (a relaunch, an older caller) it is refused - claude starts.
        [object]$IssueFacts = $null,
        [switch]$Preview
    )
    # Launch-time low-trust gate (#773). Every path that starts a session comes through here - the
    # fleet picker, an explicit per-issue choice, a relaunch - so this is where dsh is refused for an
    # issue that is not Docs/Chore of a public repo, with one line saying why.
    $chosenAdapter = Get-CliAdapters | Where-Object { $_.Name -ceq $Cli } | Select-Object -First 1
    if ($chosenAdapter -and $chosenAdapter.LowTrust) {
        $facts = $IssueFacts
        # The board item normally carries the visibility; when it does not, ask GitHub once
        # (an unreadable answer stays empty, and empty is refused).
        if ($facts -and -not "$($facts.visibility)".Trim()) {
            $facts = [pscustomobject]@{ labels = $facts.labels; type = $facts.type; size = $facts.size
                                        visibility = "$(Get-CliRepoVisibility $Repo)"; title = $facts.title; body = $facts.body }
        }
        $gate = Resolve-CliLowTrustLaunch -Chosen $Cli -Adapters @($chosenAdapter) -Facts $facts -IssueNum $IssueNum
        if ($gate.Warning) { Write-Host "  WARN $($gate.Warning)" -ForegroundColor DarkYellow }
        $Cli = $gate.Cli
        $IssueFacts = $facts
    }
    $lowTrust = [bool]($chosenAdapter -and $chosenAdapter.LowTrust -and $Cli -ceq $chosenAdapter.Name)
    $abios = Get-AbiosDir
    $briefingFile = if ($abios) { Join-Path $abios "briefing-$IssueNum.txt" } else { Join-Path $WorkPath "briefing-$IssueNum.txt" }
    # Redirect this session's stream to logs/issue-<n>.log so the -Sessions dashboard can
    # tail it (Start-Transcript, wired inside the launch script).
    $logPath = Get-SessionLogPath $IssueNum
    # GitHub identity the session keeps after the secret scrub (#769): a brake-armed run gets the
    # agent identity only (never the owner's token the main rule exempts); an unarmed run keeps
    # the GH_TOKEN it inherited, as before.
    $ghVar = if ($StopAtPR) { 'GITHUB_TOKEN_AGENT' } else { 'GH_TOKEN' }
    $plan  = Build-WorktreeLaunch $IssueNum $WorkPath $briefingFile "abios-parallel" $ClaudeAuthVar $Cli $FleetSession $logPath ([bool]$AllowPermissionBypass) $ghVar
    # The CLI that will actually start (#773: a refused low-trust choice became claude above).
    $plan | Add-Member -NotePropertyName cli -NotePropertyValue $Cli -Force

    if ($Preview) {
        Write-Host ("  [preview] #{0}: {1} {2}" -f $IssueNum, $plan.launcher, ($plan.args -join ' ')) -ForegroundColor Gray
        Write-Host ("  [preview] #{0} launch script ({1}):" -f $IssueNum, $plan.launchScriptFile) -ForegroundColor DarkGray
        foreach ($ln in ($plan.launchScript -split "`r?`n")) { Write-Host ("             $ln") -ForegroundColor DarkGray }
        return $plan
    }

    if (-not $WorkPath -or -not (Test-Path $WorkPath)) {
        Write-Host "  WARN #${IssueNum}: worktree '$WorkPath' does not exist - no session launched." -ForegroundColor DarkYellow
        return $null
    }
    # Checkpoint the run ledger BEFORE anything is armed or spawned (#771). A launched session can
    # end without ever saving a handoff; the checkpoint is what tells the next session it was
    # started. When a run is active and the checkpoint cannot be written, do not launch - same
    # refusal shape as the brake below (FAIL + $null), so the batch carries on to the next issue.
    try {
        $null = Write-RunLedgerCheckpoint -Step 'launch' -Issue $IssueNum -Detail $Branch
    } catch {
        Write-Host "  FAIL #${IssueNum}: $($_.Exception.Message) The session is not launched." -ForegroundColor Red
        return $null
    }
    # ARM THE BRAKE (#516). The briefing below still ASKS the session to stop at a reviewed PR;
    # this marker is what makes the refusal mechanical. The PreToolUse hook
    # (Brake-PreToolUseHook.ps1) finds it by walking up from the session's cwd and denies the
    # irreversible call before it runs. Written only for a real launch: a -Preview must not leave
    # a live control behind, and an unarmed run must not find a stale marker from an armed one.
    try {
        . (Join-Path $PSScriptRoot 'Brake-Guard.ps1')
        $armedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        # A positive budget arms the marker on its own (#564, external review round 2): the hook
        # can only enforce what the marker records, and a launch whose contract does not brake on
        # merge still deserves its time limit. -StopAtPR without a budget arms exactly as before.
        $armIntent = ([bool]$StopAtPR) -or ($SessionBudgetMinutes -gt 0)
        # A marker armed ONLY for the budget declares it (#565 round 6), so an intentionally
        # empty irreversible list stays empty instead of inheriting the anti-tamper full
        # vocabulary - the contract said this run may merge, and the budget must not unsay it.
        # Only when the list is ACTUALLY empty (round 7): with any verb present (say deploy),
        # the declaration would later excuse a hand-emptied list from the anti-tamper fallback.
        $irrClean = @($Irreversible | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $budgetOnly = (-not [bool]$StopAtPR) -and ($SessionBudgetMinutes -gt 0) -and ($irrClean.Count -eq 0)
        $state = Set-BrakeArmedState -WorkPath $WorkPath -Armed $armIntent -Issue $IssueNum `
                    -Irreversible $Irreversible -Branch $Branch -HostName ([Environment]::MachineName) -ArmedAt $armedAt `
                    -EndToEnd ([bool]$EndToEnd) -BudgetMinutes $SessionBudgetMinutes -Repo $Repo -BudgetOnly $budgetOnly
        if ($state -eq 'armed') {
            Write-Host ("  OK  #{0}: brake ARMED (a real control, not just an instruction) -> {1}" -f $IssueNum, (Get-BrakeMarkerPath -WorkPath $WorkPath)) -ForegroundColor Green
            if ($SessionBudgetMinutes -gt 0) {
                Write-Host ("      budget: {0} min - once spent, the hook only lets the wrap-up through (handoff/commit/report)" -f $SessionBudgetMinutes) -ForegroundColor DarkGray
            }
        } elseif ($state -eq 'disarmed') {
            Write-Host ("  OK  #{0}: brake DISARMED (marker from a previous run removed)" -f $IssueNum) -ForegroundColor DarkGray
        }
    } catch {
        if ($StopAtPR -or $SessionBudgetMinutes -gt 0) {
            # An unarmed run that believes it is armed is the #440 failure. Say so and refuse to
            # launch rather than spawn a session with a brake that exists only on paper.
            Write-Host "  FAIL #${IssueNum}: could not arm the brake ($_). The session is not launched." -ForegroundColor Red
            return $null
        }
        # A marker we failed to CLEAR only ever over-blocks, so that direction warns and continues.
        Write-Host "  WARN #${IssueNum}: could not remove the previous brake marker ($_). Merging stays blocked in that worktree." -ForegroundColor DarkYellow
    }
    # Persist the briefing so the spawned session reads it without command-line quoting.
    # Cross-repo facts were recorded in the session registry when the issue was started (#487), so a
    # relaunch briefs the same way without every call site having to carry them.
    $xrEntry = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq $IssueNum }) | Select-Object -First 1
    $xrRepos = @(); $xrFlag = $false
    if ($xrEntry) {
        if ($xrEntry.PSObject.Properties['targetRepos']) { $xrRepos = @($xrEntry.targetRepos | Where-Object { $_ }) }
        if ($xrEntry.PSObject.Properties['crossRepo'])   { $xrFlag  = [bool]$xrEntry.crossRepo }
    }
    # A low-trust CLI (dsh, #773) runs in a container with no gh, no pwsh, no GitHub token and no
    # plugin scripts: the fleet briefing (gh issue view, Fleet-* scripts, commit, PR) would order it
    # to do what it cannot and must not. It gets the issue text and one job - edit the files.
    $briefingText = if ($lowTrust) { Get-ContainerEditBriefing -IssueNum $IssueNum -Repo $Repo -Title $IssueFacts.title -Body $IssueFacts.body }
                    else { Get-SessionBriefing $IssueNum $Repo $Branch $WorkPath $Cli -StopAtPR:$StopAtPR -BriefFile $BriefFile -TargetRepos $xrRepos -CrossRepo:$xrFlag }
    Set-Content -LiteralPath $briefingFile -Value $briefingText -Encoding UTF8
    # Persist the launch script so wt/pwsh runs it via -File (no ';' on wt's command
    # line -> no stray tab-splitting). See Build-WorktreeLaunch header for the why.
    Set-Content -LiteralPath $plan.launchScriptFile -Value $plan.launchScript -Encoding UTF8
    $proc = $null
    $launchedAt = Get-Date   # lets the caller tell THIS launch's wt tab shell from an older one (#557)
    try {
        $detached = [bool]($plan.PSObject.Properties['detached'] -and $plan.detached)
        if ($plan.usesWt) { $proc = Start-Process $plan.launcher -ArgumentList $plan.args -PassThru }
        elseif ($detached) {
            $proc = Start-Process $plan.launcher -ArgumentList $plan.args -WorkingDirectory $WorkPath -PassThru `
                        -RedirectStandardOutput $plan.consoleLog -RedirectStandardError "$($plan.consoleLog).err"
        }
        else              { $proc = Start-Process $plan.launcher -ArgumentList $plan.args -WorkingDirectory $WorkPath -PassThru }
        $how = if ($plan.usesWt) { "WT tab 'issue-$IssueNum'" } elseif ($detached) { "background pwsh, output in $($plan.consoleLog)" } else { "pwsh window" }
        Write-Host ("  OK  #{0}: Claude session launched ({1}) in {2}" -f $IssueNum, $how, $WorkPath) -ForegroundColor Green
    } catch {
        Write-Host "  FAIL #${IssueNum}: could not launch the session: $_" -ForegroundColor Red
    }
    # Attach the spawned process so the caller can track its real PID in the registry.
    # NOTE: a 'wt' process forks the terminal host and exits fast, so its PID is not a
    # reliable liveness signal - only the standalone pwsh window's PID is tracked.
    $plan | Add-Member -NotePropertyName process -NotePropertyValue $proc -Force
    $plan | Add-Member -NotePropertyName launchedAt -NotePropertyValue $launchedAt -Force
    return $plan
}

# -- Dashboard helpers (Phase 2 monitor) ---------------------------------------
# Where a spawned session's stream is redirected (log redirection wired in #198).
# Pure given the state dir -> the dashboard reads the tail if the file exists.
function Get-SessionLogPath([int]$Issue) {
    $dir = Get-AbiosDir
    if (-not $dir) { return $null }
    return (Join-Path (Join-Path $dir "logs") "issue-$Issue.log")
}

# Last $Count non-blank lines of a log, oldest-first. Returns @() when the file does
# not exist yet (a session may not have produced output). Reads the whole file - fleet
# logs are small and this stays simple + testable.
function Get-LogTailLines([string]$Path, [int]$Count = 3) {
    # Emits 0..N lines. NOTE: PowerShell unwraps a single-element result on capture
    # ($r = Get-LogTailLines ...), so a caller that indexes must wrap it: @($tail)[0].
    # Show-SessionFleet iterates with foreach, which is safe for a scalar or an array.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    # Drop trailing blank lines so the tail shows real output, not padding.
    $end = $lines.Count - 1
    while ($end -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$end])) { $end-- }
    if ($end -lt 0) { return @() }
    $start = [math]::Max(0, $end - $Count + 1)
    return @($lines[$start..$end])
}

# Live RAM (MB working set) + CPU (cumulative processor seconds) for a session PID.
# Alive=$false when the process is gone. Get-Process is the only reading -> mockable.
function Get-SessionMetrics([int]$SessionPid) {
    $p = Get-Process -Id $SessionPid -ErrorAction SilentlyContinue
    if (-not $p) { return [PSCustomObject]@{ Alive = $false; RamMB = 0; CpuSec = 0 } }
    [PSCustomObject]@{
        Alive  = $true
        RamMB  = [int][math]::Round(($p.WorkingSet64 / 1MB), 0)
        CpuSec = [int][math]::Round(([double]$p.CPU), 0)
    }
}

# One-line CPU/RAM cell for the dashboard. Pure -> unit-testable.
function Format-SessionMetric([object]$Metrics) {
    if (-not $Metrics -or -not $Metrics.Alive) { return "PID dead" }
    return ("RAM {0} MB | CPU {1}s" -f $Metrics.RamMB, $Metrics.CpuSec)
}

# Monitor the local parallel-session fleet: list every LIVE registered session
# (Read-SessionRegistry prunes dead-PID entries on the way in) with its branch,
# worktree, launch method, CLI, live PID CPU/RAM, log tail and - best-effort - the
# PR opened for its branch.
function Show-SessionFleet {
    $sessions = @(Read-SessionRegistry)
    Write-Host "=== Active session fleet (this machine) ===" -ForegroundColor Cyan
    Write-Host ""
    if ($sessions.Count -eq 0) {
        Write-Host "No live sessions recorded in .agentic-board/sessions.json." -ForegroundColor DarkGray
        return
    }
    foreach ($s in ($sessions | Sort-Object issue)) {
        $via = if ($s.via) { $s.via } else { "-" }
        $cli = if ($s.cli) { $s.cli } else { "claude" }
        Write-Host ("  #{0,-4} {1}  [{2}]" -f $s.issue, $s.branch, $cli) -ForegroundColor Yellow
        $hostSessionId = "$($s.hostSessionId)".Trim()
        if (Test-HostManagedSession $s) {
            if (-not $hostSessionId) { $hostSessionId = "(not registered yet)" }
            # Host-managed surface (#710 P1): sessionPid here is Get-HostManagedPidMarker, NOT a
            # real Windows process - never hand it to Get-Process (Get-SessionMetrics would just
            # report it dead, which is exactly the false "PID dead" this branch exists to avoid).
            Write-Host ("        host-session {0} [{1}] | host {2} | since {3}" -f $hostSessionId, "$($s.surface)", $s.host, $s.started) -ForegroundColor DarkGray
        } else {
            # Live CPU/RAM for the tracked PID (mockable Get-Process behind Get-SessionMetrics).
            # Best-effort: a provider exception or a bad pid must never crash the dashboard loop.
            $metric = "metrics n/a"
            try { $metric = Format-SessionMetric (Get-SessionMetrics ([int]$s.sessionPid)) } catch { }
            Write-Host ("        PID {0} via {1} | {2} | host {3} | since {4}" -f $s.sessionPid, $via, $metric, $s.host, $s.started) -ForegroundColor DarkGray
        }
        if ($s.workPath) { Write-Host ("        {0}" -f $s.workPath) -ForegroundColor DarkGray }
        # Cross-repo (#487): the row says where the work goes and which PRs the session really has
        # live, in as many repos as it opened them. The by-branch lookup below only ever finds a PR
        # in the issue's own repo, which is exactly the one a cross-repo session never opens.
        $xrTargets = @(); $xrPrs = @()
        if ($s.PSObject.Properties['targetRepos']) { $xrTargets = @($s.targetRepos | Where-Object { $_ }) }
        if ($s.PSObject.Properties['prs'])         { $xrPrs     = @($s.prs | Where-Object { $_ -and $_.repo }) }
        $xrFlag = ($s.PSObject.Properties['crossRepo'] -and [bool]$s.crossRepo)
        if ($xrTargets.Count -gt 0) {
            Write-Host ("        CROSS-REPO -> {0}" -f ($xrTargets -join ', ')) -ForegroundColor Magenta
        } elseif ($xrFlag) {
            Write-Host "        CROSS-REPO (the target repos are listed in the issue)" -ForegroundColor Magenta
        }
        if ($xrPrs.Count -gt 0) {
            $xrStates = Get-SessionPrStates -Prs $xrPrs
            foreach ($ln in (Format-SessionPrLines -Prs $xrPrs -States $xrStates)) { Write-Host ("        {0}" -f $ln) -ForegroundColor DarkCyan }
            # Closure (#487): say whether the issue may be closed - only when EVERY recorded PR is merged.
            $xrVerdict = Get-IssueClosureVerdict -Prs $xrPrs -States $xrStates -TargetRepos $xrTargets
            if ($xrVerdict.CanClose) { Write-Host "        READY TO CLOSE: all its PRs are merged (the issue closes when you ask)." -ForegroundColor Green }
            else                     { Write-Host ("        Not closable yet: {0}." -f $xrVerdict.Reason) -ForegroundColor DarkYellow }
        } elseif ($xrFlag -or $xrTargets.Count -gt 0) {
            Write-Host "        (no PRs recorded for this session yet)" -ForegroundColor DarkGray
        } elseif ($s.repo -and $s.branch) {
            try {
                $pr = @(gh pr list --repo $s.repo --head $s.branch --state all --json number,state,url --limit 1 2>$null | ConvertFrom-Json)
                if ($pr.Count -gt 0) {
                    Write-Host ("        PR #{0} [{1}] {2}" -f $pr[0].number, $pr[0].state, $pr[0].url) -ForegroundColor DarkCyan
                }
            } catch { }
        }
        # Tail of the session's redirected stream, when it has produced output (best-effort).
        try {
            $tail = Get-LogTailLines (Get-SessionLogPath ([int]$s.issue)) 3
            foreach ($ln in $tail) { Write-Host ("        | {0}" -f $ln) -ForegroundColor DarkGray }
        } catch { }
    }
    Write-Host ""
    Write-Host ("Total: {0} live session(s). Sessions with a dead PID were pruned automatically." -f $sessions.Count) -ForegroundColor Cyan
}
