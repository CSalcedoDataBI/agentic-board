<#  Install-SkillFromRepo.ps1 — clean-clone a single skill from a GitHub repo.

    Shallow-clones the source repo to a temp dir, copies ONLY the requested skill folder
    into the personal skills dir (~/.claude/skills/<name>), preserves the source LICENSE
    next to it (required for CC BY-SA and friends), and deletes the temp clone. Idempotent:
    refuses to overwrite an existing skill unless -Force.

    This is the install half of skills-bootstrap. Pair it with Get-SkillGaps.ps1 (which
    decides WHAT is missing) — never install something already present (no duplicates).

    On success it records provenance in `<skill>/.abios-provenance.json` (repo, path, the
    exact commit SHA cloned, owner, license, installedAt) so Get-ToolkitFreshness.ps1 can
    later tell whether the installed copy still matches upstream. -Owner/-License come from
    the catalog entry (attribution); omit them and they are recorded empty.

    EXAMPLE
      .\Install-SkillFromRepo.ps1 -Repo trailofbits/skills -Path skill-improver -Name skill-improver
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name,
    [string]$Owner = "",
    [string]$License = "",
    [string]$Dest,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Dest) {
    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    $Dest = Join-Path $userHome '.claude/skills'
}
$target = Join-Path $Dest $Name
if ((Test-Path $target) -and -not $Force) {
    Write-Host "  SKIP  $Name already installed at $target (use -Force to overwrite)." -ForegroundColor DarkYellow
    return [pscustomobject]@{ name=$Name; installed=$false; reason='already-present'; path=$target }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("skillclone-" + [guid]::NewGuid().ToString('N'))
try {
    Write-Host "  Cloning $Repo (depth 1)..." -ForegroundColor Cyan
    git clone --depth 1 "https://github.com/$Repo.git" $tmp 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Repo" }
    $sha = (git -C $tmp rev-parse HEAD 2>$null)

    $src = Join-Path $tmp $Path
    if (-not (Test-Path $src)) { throw "Skill path '$Path' not found in $Repo." }

    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item (Join-Path $src '*') $target -Recurse -Force

    # Preserve attribution: copy the repo LICENSE if the skill folder lacks one.
    if (-not (Get-ChildItem $target -Filter 'LICENSE*' -ErrorAction SilentlyContinue)) {
        $lic = Get-ChildItem $tmp -Filter 'LICENSE*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lic) { Copy-Item $lic.FullName (Join-Path $target 'LICENSE') -Force }
    }

    # Record provenance so Get-ToolkitFreshness.ps1 can compare against upstream later.
    $prov = [ordered]@{
        name        = $Name
        repo        = $Repo
        path        = $Path
        sha         = $sha
        owner       = $Owner
        license     = $License
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $prov | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.abios-provenance.json') -Encoding utf8

    Write-Host "  OK  installed $Name -> $target" -ForegroundColor Green
    [pscustomobject]@{ name=$Name; installed=$true; source="$Repo/$Path"; sha=$sha; path=$target }
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
