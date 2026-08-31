<#  Get-ToolkitFreshness.ps1 — is each installed toolkit skill still current with upstream?

    REPORT-ONLY. Scans the skills dir for `<skill>/.abios-provenance.json` markers written by
    Install-SkillFromRepo.ps1, and for each compares the installed commit SHA against the latest
    upstream commit that touched that skill's path. It NEVER installs, reinstalls, or files
    anything — it just tells you what has drifted, so you can decide to re-run bootstrap.

    Status per skill:
      fresh    — installed SHA == latest upstream SHA for its path
      behind   — upstream moved on (a newer commit touches the path)
      unknown  — upstream could not be resolved (offline / gh error / no SHA recorded)

    Only skill-clone installs carry provenance; plugin-kind tools are provisioned by their own
    installer and are out of scope here (best-effort by design — see presets/toolkits/README.md).

    -SkillsDir overrides where to scan (default ~/.claude/skills). -LatestShaMap injects the
    upstream lookup for tests: a hashtable keyed "<repo>|<path>" -> sha (a present key with a
    $null value simulates an unresolved upstream). Without it, upstream is read live via gh.

    EXAMPLES
      .\Get-ToolkitFreshness.ps1
      .\Get-ToolkitFreshness.ps1 -Json
#>
[CmdletBinding()]
param(
    [string]$SkillsDir,
    [hashtable]$LatestShaMap,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $SkillsDir) {
    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    $SkillsDir = Join-Path $userHome '.claude/skills'
}

function Get-LatestUpstreamSha([string]$Repo, [string]$Path) {
    # Test injection wins; a present key (even with a $null value) is authoritative.
    if ($LatestShaMap) {
        $key = "$Repo|$Path"
        if ($LatestShaMap.ContainsKey($key)) { return $LatestShaMap[$key] }
    }
    try {
        $q = if ($Path) { "repos/$Repo/commits?per_page=1&path=$Path" } else { "repos/$Repo/commits?per_page=1" }
        $out = gh api $q 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $commits = $out | ConvertFrom-Json
        return @($commits)[0].sha
    } catch { return $null }
}

$rows = [System.Collections.Generic.List[object]]::new()
if (Test-Path $SkillsDir) {
    foreach ($provFile in Get-ChildItem -Path $SkillsDir -Recurse -Filter '.abios-provenance.json' -ErrorAction SilentlyContinue) {
        $p = $null
        try { $p = Get-Content -LiteralPath $provFile.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $p.repo) { continue }

        $latest = Get-LatestUpstreamSha $p.repo $p.path
        $status =
            if (-not $latest -or -not $p.sha) { 'unknown' }
            elseif ($latest -eq $p.sha)       { 'fresh' }
            else                              { 'behind' }

        $short = { param($s) if ($s) { [string]$s -replace '^(.{7}).*','$1' } else { '-' } }
        $rows.Add([pscustomobject]@{
            name      = $p.name
            owner     = $p.owner
            repo      = $p.repo
            installed = (& $short $p.sha)
            latest    = (& $short $latest)
            status    = $status
        })
    }
}

$result = [pscustomobject]@{
    summary = [pscustomobject]@{
        total   = $rows.Count
        fresh   = @($rows | Where-Object status -eq 'fresh').Count
        behind  = @($rows | Where-Object status -eq 'behind').Count
        unknown = @($rows | Where-Object status -eq 'unknown').Count
    }
    tools = $rows
}

if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }
