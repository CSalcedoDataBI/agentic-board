<#  Get-InstalledPlugins.ps1 — installed Claude Code plugins as match keys.

    Parses `claude plugin list` into a flat, de-duplicated list of lowercase identifiers a
    catalog's `detect`/`name` can be matched against. For each installed `<plugin>@<marketplace>`
    it emits BOTH `<plugin>` and `<marketplace>`, so a plugin catalog entry can key on either
    the plugin name or its marketplace (a marketplace often publishes several plugins).

    Best-effort by design: if the `claude` CLI is absent or errors, it returns an EMPTY array
    and never throws — the caller then reports the plugin as a gap and the SKILL.md emits its
    (idempotent) install command. -Raw injects `claude plugin list` output for tests.

    EXAMPLE
      .\Get-InstalledPlugins.ps1
#>
[CmdletBinding()]
param([string]$Raw)

if (-not $PSBoundParameters.ContainsKey('Raw')) {
    try   { $Raw = (& claude plugin list 2>$null | Out-String) }
    catch { $Raw = '' }
}
if (-not $Raw) { return @() }

$ids = [System.Collections.Generic.List[string]]::new()
foreach ($line in ($Raw -split "`r?`n")) {
    if ($line -match '([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)') {
        $ids.Add($matches[1].ToLower())
        $ids.Add($matches[2].ToLower())
    }
}
,(@($ids | Select-Object -Unique))
