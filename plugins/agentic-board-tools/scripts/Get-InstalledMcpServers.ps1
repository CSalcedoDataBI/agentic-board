<#  Get-InstalledMcpServers.ps1 — installed Claude Code MCP servers as match keys.

    Parses `claude mcp list` output into a flat, de-duplicated list of lowercase server
    names a catalog's `detect`/`name` can be matched against. Each line is expected in the
    form "name (...)" or just "name".

    Best-effort by design: if the `claude` CLI is absent or errors, it returns an EMPTY
    array and never throws — the caller then reports the MCP server as a gap and the
    tools-catalog skill emits its (idempotent) install command.

    -Raw injects `claude mcp list` output for tests.

    EXAMPLE
      .\Get-InstalledMcpServers.ps1
#>
[CmdletBinding()]
param([string]$Raw)

if (-not $PSBoundParameters.ContainsKey('Raw')) {
    try   { $Raw = (& claude mcp list 2>$null | Out-String) }
    catch { $Raw = '' }
}
if (-not $Raw) { return @() }

$ids = [System.Collections.Generic.List[string]]::new()
foreach ($line in ($Raw -split "`r?`n")) {
    # Match the server name at the start of a line (before any parenthetical detail)
    if ($line -match '^\s*([A-Za-z0-9._-]+)') {
        $ids.Add($Matches[1].ToLower())
    }
}
,(@($ids | Select-Object -Unique))
