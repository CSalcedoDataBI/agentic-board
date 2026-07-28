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

function Merge-ExpertRoles {
    param([hashtable]$Factory, [hashtable]$Local)
    $factoryRoles = @($Factory.roles)
    $quality      = @($Factory.qualityProfile)
    if (-not $Local) { return @{ roles = $factoryRoles; qualityProfile = $quality } }

    if ($Local.ContainsKey('qualityProfile') -and $null -ne $Local.qualityProfile) {
        $quality = @($Local.qualityProfile)
    }

    $merged  = [System.Collections.Generic.List[object]]::new()
    $claimed = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($l in @($Local.roles)) {
        $f = $factoryRoles | Where-Object { $_.name -eq $l.name } | Select-Object -First 1
        if ($f -and -not $l.replace) {
            # Union the list fields; the pointer fields replace wholesale.
            $role = @{
                name     = $l.name
                keywords = @(@(@($f.keywords) + @($l.keywords)) | Where-Object { $_ } | Select-Object -Unique)
                skills   = @(@(@($f.skills)   + @($l.skills))   | Where-Object { $_ } | Select-Object -Unique)
            }
            foreach ($k in 'agent','standards','knowledgeDomain') {
                if ($l.ContainsKey($k) -and $null -ne $l[$k]) { $role[$k] = $l[$k] }
                elseif ($f.ContainsKey($k) -and $null -ne $f[$k]) { $role[$k] = $f[$k] }
            }
            # An explicit agent supersedes inherited prose, so the two never both apply.
            if ($l.ContainsKey('agent') -and $l.agent) { $role.Remove('standards') }
        } else {
            $role = @{}
            foreach ($k in $l.Keys) { if ($k -ne 'replace') { $role[$k] = $l[$k] } }
        }
        $merged.Add($role) | Out-Null
        $claimed.Add($l.name) | Out-Null
    }
    foreach ($f in $factoryRoles) {
        if (-not $claimed.Contains($f.name)) { $merged.Add($f) | Out-Null }
    }
    @{ roles = $merged.ToArray(); qualityProfile = $quality }
}

function Get-ExpertRoleLocalPath {
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir
    if (-not $dir) { return $null }
    Join-Path $dir 'roles.json'
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

    if (-not $PSBoundParameters.ContainsKey('LocalPath')) { $LocalPath = Get-ExpertRoleLocalPath }
    $local = Read-ExpertRoleFile -Path $LocalPath
    $catalog = Merge-ExpertRoles -Factory $factory -Local $local
    if ($usingDefaults) { $script:ExpertRolesCache = $catalog }
    $catalog
}

# Dot-source guard: tests set $env:ABIOS_EXPERTROLES_DOTSOURCE to load the functions only.
if ($env:ABIOS_EXPERTROLES_DOTSOURCE) { return }

# CLI: print the effective catalog as JSON.
(Get-ExpertRoles) | ConvertTo-Json -Depth 8
