<#
.SYNOPSIS
    Load and merge the /board expert role catalog — shipped preset + optional project-local file.

.DESCRIPTION
    Roles are data, not code. presets/roles.json ships the factory catalog; a project may add
    .agentic-board/roles.json (versioned in git) to add, extend or override roles. This script is
    the single place that knows roles live in files.

    Pure filesystem IO (no gh) behind a dot-source guard ($env:ABIOS_EXPERTROLES_DOTSOURCE).

.EXAMPLE
    . .\ExpertRolesIo.ps1 ; (Get-ExpertRoles).roles.name
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$script:ExpertRolesSchemaVersion = 1
$script:ExpertRolesCache = $null

function Clear-ExpertRolesCache { $script:ExpertRolesCache = $null }

function Get-ExpertRolePresetPath {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'presets/roles.json'
}

function Read-ExpertRoleFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "roles: could not parse '$Path' ($($_.Exception.Message)) - ignoring it."
        $null
    }
}

function Get-ExpertRoles {
    param([string]$PresetPath, [string]$LocalPath, [switch]$NoCache)
    $usingDefaults = -not $PresetPath -and -not $PSBoundParameters.ContainsKey('LocalPath')
    if ($script:ExpertRolesCache -and -not $NoCache -and $usingDefaults) {
        return $script:ExpertRolesCache
    }
    if (-not $PresetPath) { $PresetPath = Get-ExpertRolePresetPath }

    $factory = Read-ExpertRoleFile -Path $PresetPath
    if (-not $factory) { throw "roles: the shipped preset is missing or unreadable at '$PresetPath' - this is a broken install." }

    $catalog = @{
        roles          = @($factory.roles)
        qualityProfile = @($factory.qualityProfile)
    }
    if ($usingDefaults) { $script:ExpertRolesCache = $catalog }
    $catalog
}

# Dot-source guard: tests set $env:ABIOS_EXPERTROLES_DOTSOURCE to load the functions only.
if ($env:ABIOS_EXPERTROLES_DOTSOURCE) { return }

# CLI: print the effective catalog as JSON.
(Get-ExpertRoles) | ConvertTo-Json -Depth 8
