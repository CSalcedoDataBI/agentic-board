<#
.SYNOPSIS
    Read/write the /board expert contract — the settings `config` writes and `auto` reads.

.DESCRIPTION
    The contract is a small JSON document under the internal state dir
    (Get-AbiosStateDir -> .agentic-board/expert.json) describing HOW the auto-expert runs:
    the expert role, the autonomy boundary (what is irreversible), the definition of done,
    where evidence goes, the board self-drive policy, the budget, and which agentic-board
    capabilities are enabled. A partial on-disk contract is deep-merged over the defaults on
    read, so `auto` never encounters a missing setting.

    Pure filesystem IO (no gh) behind a dot-source guard ($env:ABIOS_EXPERTCONTRACT_DOTSOURCE)
    so Pester can unit-test New/Read/Write without touching the network.

.EXAMPLE
    . .\ExpertContractIo.ps1 ; $c = New-ExpertContract ; Write-ExpertContract -Contract $c
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# Does this repo have a semantic model (a .tmdl / .bim / .pbism file)? (#475)
#
# `bpa` (Best Practice Analyzer) and `tmdlBreaking` are semantic-model gates; in a repo with no
# model they have nothing to run against and every evidence block listed them anyway - a
# checklist with permanently inapplicable rows is one people stop reading. The default DoD is
# therefore derived from what the repo contains instead of being one fixed set.
#
# FAIL DIRECTION: "I could not look" answers YES (keep the gates). A model repo that lost its
# BPA gate to a failed scan would be a silent waiver; a non-model repo that keeps two inert
# rows is only noise, and Get-ApplicableDodGates still skips them per diff.
function Test-RepoHasSemanticModel {
    param([string]$Root = '')
    $haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $Root) {
        $top = if ($haveGit) { & git rev-parse --show-toplevel 2>$null } else { $null }
        $Root = if ($haveGit -and $LASTEXITCODE -eq 0 -and $top) { "$top".Trim() } else { (Get-Location).Path }
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $true }
    # git first: tracked AND untracked-but-not-ignored, so a model added this session counts and
    # node_modules (ignored) is never walked. Exit 128 = not a repo -> fall through to the walk.
    if ($haveGit) {
        $found = @(& git -C $Root ls-files --cached --others --exclude-standard -- '*.tmdl' '*.bim' '*.pbism' 2>$null)
        if ($LASTEXITCODE -eq 0) { return [bool](@($found | Where-Object { "$_".Trim() }).Count) }
    }
    try {
        $hit = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.tmdl', '.bim', '.pbism') -and $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' } |
            Select-Object -First 1
        return [bool]$hit
    } catch {
        return $true
    }
}

function New-ExpertContract {
    # The default contract. Autonomy brakes ONLY on the irreversible; everything else the
    # auto-expert does on its own and records.
    #
    # $HasSemanticModel gates the two model-only DoD gates (#475). It defaults to $true so a
    # caller that never looked keeps the full set: the safe direction (see Test-RepoHasSemanticModel).
    param([bool]$HasSemanticModel = $true)
    $dod = @{ ci = $true; build = $true; lint = $true; tests = $true }
    if ($HasSemanticModel) { $dod.bpa = $true; $dod.tmdlBreaking = $true }
    @{
        role     = ""
        autonomy = @{ irreversible = @('merge','deploy','refresh','publish','delete') }
        # WHAT the change produces, not which action performs it (#529). The owner's rule is
        # "código lo cierra el agente; lo que se juzga mirándolo lo apruebo yo", and a flat action
        # list cannot say that. Empty lists here mean "use the defaults" (Expert-WorkClass), so a
        # project only writes the patterns that are actually special about it.
        workClass = @{ visualPatterns = @(); humanApproves = @('visual') }
        dod      = $dod
        evidence = @{ pr = $true; issueComment = $true; file = $true }
        # (#646) Off by default: an unsupervised run uses the CI-bot fallback unless the human
        # opted into the stricter codex-rescue path in `config` (see Board-ReviewGate.ps1's
        # -PreferCodexRescue, #637/#644). Keyed under its own object so a future review setting
        # has somewhere to live without another top-level contract key.
        review   = @{ preferCodexRescue = $false }
        boardSelfDrive = @{ createIssues = $true; label = 'discovered'; cap = 10 }
        budget   = @{ maxIterations = 8; maxMinutes = 120 }
        capabilities = @{ knowledge = $true; skillsBootstrap = $true; toolsInstall = $false; scan = $true }
    }
}

function Merge-ContractDefaults {
    # Recursively fill any key missing from $Over using $Base (defaults win only where $Over is silent).
    param([hashtable]$Base, [hashtable]$Over)
    if ($null -eq $Over) { return $Base }
    $out = @{}
    foreach ($k in $Base.Keys) {
        if ($Over.ContainsKey($k) -and $Over[$k] -ne $null) {
            if (($Base[$k] -is [hashtable]) -and ($Over[$k] -is [hashtable])) {
                $out[$k] = Merge-ContractDefaults -Base $Base[$k] -Over $Over[$k]
            } else {
                $out[$k] = $Over[$k]
            }
        } else {
            $out[$k] = $Base[$k]
        }
    }
    # Carry over any extra keys the caller added that defaults do not know about.
    foreach ($k in $Over.Keys) { if (-not $out.ContainsKey($k)) { $out[$k] = $Over[$k] } }
    $out
}

function Read-ExpertContract {
    param([string]$Path, [string]$Root = '')
    if (-not $Path) { $Path = Get-ExpertContractPath }
    # The defaults a missing key falls back to are repo-derived (#475): without this, a contract
    # that omitted bpa/tmdlBreaking had them silently re-added on every read.
    $defaults = New-ExpertContract -HasSemanticModel (Test-RepoHasSemanticModel -Root $Root)
    if (-not $Path -or -not (Test-Path $Path)) { return $defaults }
    try {
        $onDisk = Get-Content -Raw -Path $Path | ConvertFrom-Json -AsHashtable
    } catch {
        return $defaults
    }
    Merge-ContractDefaults -Base $defaults -Over $onDisk
}

function Write-ExpertContract {
    param([Parameter(Mandatory)][hashtable]$Contract, [string]$Path)
    if (-not $Path) { $Path = Get-ExpertContractPath }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Contract | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
    $Path
}

# ── Path resolver (touches the filesystem via Get-AbiosStateDir; kept out of the pure core) ──
function Get-ExpertContractPath {
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir
    if (-not $dir) { return $null }
    Join-Path $dir 'expert.json'
}

# Dot-source guard: tests set $env:ABIOS_EXPERTCONTRACT_DOTSOURCE to load the functions only.
if ($env:ABIOS_EXPERTCONTRACT_DOTSOURCE) { return }

# CLI: print the resolved (merged) contract as JSON.
(Read-ExpertContract) | ConvertTo-Json -Depth 8
