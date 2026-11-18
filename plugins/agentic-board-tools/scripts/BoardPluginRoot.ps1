<#  BoardPluginRoot.ps1 - find the agentic-board plugin folder from a script of agentic-board-tools (#768).

    agentic-board, the plugin listed in the directory, ships Markdown only (skills, commands, its
    manifest). Its scripts live here, in agentic-board-tools. A few scripts read files of the
    Markdown plugin - the commands and the manifest (Update-Docs, New-Release), a skill's theme.json
    (Diagram-Theme) - so they need its folder. Where it looks, in order:
      1. a sibling `agentic-board` folder next to this plugin's folder: a repository checkout;
      2. Claude's installed_plugins.json: every `agentic-board@<marketplace>` entry whose scope
         applies (user, or a project/local install whose project contains -Cwd), newest first.
    A candidate counts only when its .claude-plugin/plugin.json names `agentic-board`. '' when none.

    Function definitions only; safe to dot-source.  #>

function Test-BoardPluginRoot([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $manifest = Join-Path (Join-Path $Root '.claude-plugin') 'plugin.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    try { $name = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).name } catch { return $false }
    return ($name -ceq 'agentic-board')
}

function Get-BoardPluginRoot {
    param(
        [string]$ToolsRoot = (Split-Path $PSScriptRoot -Parent),
        [string]$ClaudeHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' }),
        [string]$Cwd = (Get-Location).Path
    )
    if ($ToolsRoot) {
        $sibling = Join-Path (Split-Path $ToolsRoot -Parent) 'agentic-board'
        if (Test-BoardPluginRoot $sibling) { return (Resolve-Path -LiteralPath $sibling).Path }
    }
    $file = Join-Path (Join-Path $ClaudeHome 'plugins') 'installed_plugins.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    try { $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return '' }
    if (-not $doc -or -not $doc.plugins) { return '' }
    $cmp = if ($IsWindows -or $env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $full = { param($p) ([IO.Path]::GetFullPath($p)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar }
    $here = & $full $Cwd
    $found = @()
    foreach ($p in $doc.plugins.PSObject.Properties) {
        if ($p.Name -notmatch '^agentic-board@') { continue }
        foreach ($e in @($p.Value)) {
            if (-not $e -or -not $e.installPath) { continue }
            $scope = "$($e.scope)"
            $applies = ($scope -in @('user', 'managed')) -or
                       (($scope -in @('project', 'local')) -and $e.projectPath -and $here.StartsWith((& $full "$($e.projectPath)"), $cmp))
            if (-not $applies) { continue }
            $when = [datetime]::MinValue
            foreach ($f in @('lastUpdated', 'installedAt')) {
                if ($e.$f) { try { $when = [datetime]::Parse("$($e.$f)", [cultureinfo]::InvariantCulture); break } catch { } }
            }
            $found += [pscustomobject]@{ Path = "$($e.installPath)"; When = $when }
        }
    }
    foreach ($c in @($found | Sort-Object When -Descending)) {
        if (Test-BoardPluginRoot $c.Path) { return $c.Path }
    }
    return ''
}