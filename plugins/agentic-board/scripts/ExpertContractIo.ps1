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

function New-ExpertContract {
    # The default contract. Autonomy brakes ONLY on the irreversible; everything else the
    # auto-expert does on its own and records.
    @{
        role     = ""
        autonomy = @{ irreversible = @('merge','deploy','refresh','publish','delete') }
        # WHAT the change produces, not which action performs it (#529). The owner's rule is
        # "código lo cierra el agente; lo que se juzga mirándolo lo apruebo yo", and a flat action
        # list cannot say that. Empty lists here mean "use the defaults" (Expert-WorkClass), so a
        # project only writes the patterns that are actually special about it.
        workClass = @{ visualPatterns = @(); humanApproves = @('visual') }
        dod      = @{ ci = $true; build = $true; lint = $true; tests = $true; bpa = $true; tmdlBreaking = $true }
        evidence = @{ pr = $true; issueComment = $true; file = $true }
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
    param([string]$Path)
    if (-not $Path) { $Path = Get-ExpertContractPath }
    $defaults = New-ExpertContract
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
