<#  Welcome-SessionStartHook.ps1 - first-run welcome banner, shown exactly once.

    Wired as an AUTO-REGISTERED Claude Code SessionStart hook (hooks/hooks.json) - not
    opt-in: the whole point is that it "just works" right after `/plugin install`, so the
    real tool greets the user with the same banner the README GIF shows.

    The `/plugin install` screen itself is Claude Code's own UI and cannot be restyled by a
    plugin. A hook also cannot paint the TUI directly - so the banner is surfaced through
    the SessionStart `additionalContext` channel and rendered by the assistant as its first
    output (the emitted context instructs it to print the banner verbatim).

    ONCE semantics: a GLOBAL marker at <HOME>/.agentic-board/.welcomed (resolved via
    Get-AbiosStateDir -Root $HOME) - once per machine/install, not once per repo. Gated to
    source == "startup" (skip resume/clear/compact) so it never re-announces on a resumed or
    compacted session.

    Read-only except for writing the one marker file. It NEVER blocks and NEVER throws - a
    failing SessionStart hook would disrupt startup, so everything is wrapped and the script
    always exits 0.

    Dot-source guard: set $env:ABIOS_WELCOME_HOOK_DOTSOURCE=1 to load the pure helpers for
    Pester without reading stdin or touching the filesystem.
#>
[CmdletBinding()]
param()

# The banner body, verbatim. Monochrome (additionalContext carries no color); the block
# glyphs match .github/assets/board-demo.ps1 so the real first run mirrors the demo GIF.
function Get-WelcomeBanner {
    @'
   ▄▀█ █▀▀ █▀▀ █▄░█ ▀█▀ █ █▀▀   █▄▄ █▀█ ▄▀█ █▀█ █▀▄
   █▀█ █▄█ ██▄ █░▀█ ░█░ █ █▄▄   █▄█ █▄█ █▀█ █▀▄ █▄▀

   Run coding agents off your real GitHub Projects board.
   ✓ installed  ·  type /board to begin

   /board   pick the next issue → branch → PR → review gate → merge
   /scan    find untracked work in this repo → issues + plan
   /skills  Agent Skills lifecycle (organize / audit / bootstrap)
'@
}

# The message the USER sees on first run (#764). It goes out as `systemMessage`, shown directly,
# not as `additionalContext` telling the model to print it first: an instruction to override the
# user's first request is what a reviewer reads as prompt injection. Pure + testable.
function Get-WelcomeMessage {
    $banner = Get-WelcomeBanner
    @"
$banner

Type /board to start.
"@
}

# Should we welcome? Pure: startup source AND no prior marker. Testable without side effects.
function Test-ShouldWelcome([string]$source, [bool]$markerExists) {
    return ($source -eq 'startup') -and (-not $markerExists)
}

# ==============================================================================
# Main. Dot-source guard for tests.
# ==============================================================================
if ($env:ABIOS_WELCOME_HOOK_DOTSOURCE) { return }

try {
    # No redirected stdin (script run by hand) -> no hook payload; bail before ReadToEnd blocks.
    if (-not [Console]::IsInputRedirected) { exit 0 }

    $raw = ""
    try { $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false)).ReadToEnd() } catch { $raw = "" }
    $in = $null
    if ($raw) { try { $in = $raw | ConvertFrom-Json } catch { $in = $null } }

    $source = if ($in -and $in.source) { [string]$in.source } else { "" }

    # Global once-marker under $HOME (machine-wide install, not per-repo).
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir -Root $HOME
    if (-not $dir) { exit 0 }
    $marker = Join-Path $dir '.welcomed'

    if (-not (Test-ShouldWelcome $source (Test-Path $marker))) { exit 0 }

    # Write the marker FIRST so a mid-flight failure never re-welcomes on the next startup.
    $version = try {
        (Get-Content (Join-Path $PSScriptRoot '..' '.claude-plugin' 'plugin.json') -Raw |
            ConvertFrom-Json).version
    } catch { '' }
    $stamp = @{ welcomedAt = (Get-Date).ToString('s'); version = $version } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $marker -Value $stamp -Encoding utf8

    $out = @{ systemMessage = (Get-WelcomeMessage) } | ConvertTo-Json -Compress
    Write-Output $out
}
catch {
    # A SessionStart hook must never fail the session - swallow everything.
}
exit 0
