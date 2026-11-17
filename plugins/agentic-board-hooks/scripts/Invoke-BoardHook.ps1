<#  Invoke-BoardHook.ps1 - run one agentic-board hook from the companion plugin (#768).

    WHY THIS PLUGIN EXISTS. agentic-board is listed in the Anthropic plugin directory, and a plugin
    whose hooks start pwsh or sh is held for a human reviewer on every version. The hooks are
    opt-in behaviour (a welcome banner, handoff and compaction notes, the worktree sweep, the
    stale-plugin notice and the autonomy brake), so they live here, in agentic-board-hooks, which
    is installed from this repo's own marketplace. agentic-board itself ships no hooks.

    WHAT THIS FILE DOES. It holds no hook logic. It finds the installed agentic-board plugin and
    runs that plugin's own hook script in this process, so stdin (the hook payload), stdout and the
    exit code pass through unchanged and the logic has one copy: the one agentic-board's tests
    cover. Where it looks, in order:
      1. Claude's installed_plugins.json: every `agentic-board@<marketplace>` entry whose scope
         applies here (user scope, or a project/local install whose project contains the working
         directory), newest first.
      2. A sibling `agentic-board` folder next to this plugin's folder: a repo checkout loaded with
         `claude --plugin-dir`.
    A candidate counts only if its .claude-plugin/plugin.json names `agentic-board` and the hook
    script exists in its scripts folder.

    FAIL DIRECTION. Every hook but the brake is advisory: not finding agentic-board, or any error,
    exits 0 silently. The brake is reached only when Brake-PreCheck.sh already found a brake marker,
    so for it "not found" or an error DENIES the tool call (an armed run must never fail open).

    Dot-source guard: set $env:ABIOS_HOOKDISPATCH_DOTSOURCE=1 to load the pure helpers for Pester.
#>
[CmdletBinding()]
param(
    [string]$Hook = '',
    [string]$SessionId = ''
)

$script:HookTargets = @{
    Welcome     = 'Welcome-SessionStartHook.ps1'
    Handoff     = 'Handoff-SessionStartHook.ps1'
    Worktree    = 'Worktree-SessionStartHook.ps1'
    Compact     = 'Compact-PreCompactHook.ps1'
    Brake       = 'Brake-PreToolUseHook.ps1'
    PluginStale = 'PluginStale-NoticeHook.ps1'
}

$script:BrakeDeny = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BRAKE: this run is brake-armed but the agentic-board plugin that holds the brake could not be found or failed to load, so the brake cannot decide. Refusing."}}'

# Claude's config folder: CLAUDE_CONFIG_DIR when set, else ~/.claude.
function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    $home_ = if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path $home_ '.claude')
}

# Is $Child the folder $Parent or inside it? Case-insensitive on Windows only.
function Test-PathWithin([string]$Child, [string]$Parent) {
    if (-not $Child -or -not $Parent) { return $false }
    $sep = [IO.Path]::DirectorySeparatorChar
    $c = ([IO.Path]::GetFullPath($Child)).TrimEnd('\', '/') + $sep
    $p = ([IO.Path]::GetFullPath($Parent)).TrimEnd('\', '/') + $sep
    $cmp = if ($IsWindows -or $env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $c.StartsWith($p, $cmp)
}

# Is $Root an agentic-board plugin folder that has $ScriptName? Reads only its plugin.json.
function Test-AgenticBoardRoot([string]$Root, [string]$ScriptName) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $manifest = Join-Path (Join-Path $Root '.claude-plugin') 'plugin.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    try { $name = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).name } catch { return $false }
    if ($name -cne 'agentic-board') { return $false }
    return (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'scripts') $ScriptName) -PathType Leaf)
}

# The installed agentic-board folders that apply in $Cwd, newest first. Pure apart from reading
# installed_plugins.json.
function Get-InstalledBoardRoots([string]$ConfigDir, [string]$Cwd) {
    $file = Join-Path (Join-Path $ConfigDir 'plugins') 'installed_plugins.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    try { $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return @() }
    if (-not $doc -or -not $doc.plugins) { return @() }
    $found = @()
    foreach ($p in $doc.plugins.PSObject.Properties) {
        if ($p.Name -notmatch '^agentic-board@') { continue }
        foreach ($e in @($p.Value)) {
            if (-not $e -or -not $e.installPath) { continue }
            $scope = "$($e.scope)"
            $applies = ($scope -eq 'user') -or ($scope -eq 'managed') -or
                       (($scope -in @('project', 'local')) -and (Test-PathWithin $Cwd "$($e.projectPath)"))
            if (-not $applies) { continue }
            $when = [datetime]::MinValue
            foreach ($f in @('lastUpdated', 'installedAt')) {
                if ($e.$f) { try { $when = [datetime]::Parse("$($e.$f)", [cultureinfo]::InvariantCulture); break } catch { } }
            }
            $found += [pscustomobject]@{ Path = "$($e.installPath)"; When = $when }
        }
    }
    return @($found | Sort-Object When -Descending | ForEach-Object { $_.Path })
}

# The agentic-board folder whose hook script to run, or '' when none qualifies.
function Find-AgenticBoardRoot {
    param([string]$ScriptName, [string]$ConfigDir = (Get-ClaudeConfigDir), [string]$Cwd = (Get-Location).Path,
          [string]$SelfRoot = (Split-Path $PSScriptRoot -Parent))
    foreach ($r in (Get-InstalledBoardRoots -ConfigDir $ConfigDir -Cwd $Cwd)) {
        if (Test-AgenticBoardRoot $r $ScriptName) { return $r }
    }
    if ($SelfRoot) {
        $sibling = Join-Path (Split-Path $SelfRoot -Parent) 'agentic-board'
        if (Test-AgenticBoardRoot $sibling $ScriptName) { return $sibling }
    }
    return ''
}

if ($env:ABIOS_HOOKDISPATCH_DOTSOURCE) { return }

$isBrake = ($Hook -eq 'Brake')
try {
    $target = $script:HookTargets[$Hook]
    if (-not $target) {
        if ($isBrake) { Write-Output $script:BrakeDeny }
        exit 0
    }
    $root = Find-AgenticBoardRoot -ScriptName $target
    if (-not $root) {
        if ($isBrake) { Write-Output $script:BrakeDeny }
        exit 0
    }
    $script = Join-Path (Join-Path $root 'scripts') $target
    $global:LASTEXITCODE = 0
    if ($Hook -eq 'PluginStale') { & $script -SessionId $SessionId } else { & $script }
    exit $LASTEXITCODE
} catch {
    if ($isBrake) { Write-Output $script:BrakeDeny }
    exit 0
}
