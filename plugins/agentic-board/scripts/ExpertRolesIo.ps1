<#
.SYNOPSIS
    Load and merge the /board expert role catalog — shipped preset + optional global + project-local file.

.DESCRIPTION
    Roles are data, not code. presets/roles.json ships the factory catalog; ~/.agentic-board/roles.json
    (NOT versioned - it is per machine/user) adds roles across every one of your projects; a project may
    additionally add .agentic-board/roles.json (versioned in git) to add, extend or override roles for
    just that repo. This script is the single place that knows roles live in files.

    Precedence: local overrides global overrides factory. It is the same union/replace merge
    (Merge-ExpertRoles) applied twice - factory+global first, then that result+local - rather than a
    bespoke three-way merge.

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

function Select-ValidExpertRoles {
    # A structurally broken role costs only itself. The rest of the file still loads.
    # CmdletBinding makes this an advanced function, so callers can capture or silence its
    # warnings with -WarningVariable / -WarningAction. Without it those are silently inert.
    [CmdletBinding()]
    param([object[]]$Roles)
    $out = [System.Collections.Specialized.OrderedDictionary]::new()
    foreach ($r in @($Roles)) {
        if (-not $r.name) {
            Write-Warning "roles: a role without a 'name' was skipped."
            continue
        }
        if ($null -eq $r.keywords -or $null -eq $r.skills) {
            Write-Warning "roles: role '$($r.name)' is missing 'keywords' or 'skills' - skipped."
            continue
        }
        if ($out.Contains($r.name)) {
            Write-Warning "roles: role '$($r.name)' is declared more than once - the last declaration wins."
        }
        $out[$r.name] = $r
    }
    @($out.Values)
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

function Add-ExpertRole {
    # Writing a role changes how every future plan is classified, so callers must confirm first.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Role, [string]$Path)
    if (-not $Path) { $Path = Get-ExpertRoleLocalPath }
    if (-not $Path) { throw "roles: could not resolve a local catalog path." }
    $doc = Read-ExpertRoleFile -Path $Path
    if (-not $doc) { $doc = @{ version = $script:ExpertRolesSchemaVersion; roles = @() } }
    $kept = @(@($doc.roles) | Where-Object { $_.name -ne $Role.name })
    $doc.roles = @($kept + @($Role))
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
    Clear-ExpertRolesCache
    $Path
}

function Get-ExpertRoleLocalPath {
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir
    if (-not $dir) { return $null }
    Join-Path $dir 'roles.json'
}

function Get-ExpertRoleGlobalPath {
    # Same state-dir convention Backup-Board.ps1 and the welcome-banner marker already use for
    # machine-wide state: Get-AbiosStateDir -Root $HOME -> ~/.agentic-board. Roles placed there
    # apply across every one of this user's projects, not just the current repo.
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir -Root $HOME
    if (-not $dir) { return $null }
    Join-Path $dir 'roles.json'
}

function Import-ValidatedExpertRoleFile {
    # An overlay file (global or local) must declare the schema version it was written against;
    # a mismatch means an old or future build wrote it, so ignoring it is safer than misreading it.
    param([string]$Path)
    $doc = Read-ExpertRoleFile -Path $Path
    if (-not $doc) { return $null }
    $v = if ($doc.ContainsKey('version')) { [int]$doc.version } else { 0 }
    if ($v -ne $script:ExpertRolesSchemaVersion) {
        Write-Warning "roles: '$Path' declares version '$v'; this build understands version $($script:ExpertRolesSchemaVersion) - ignoring the file."
        return $null
    }
    $doc.roles = Select-ValidExpertRoles -Roles @($doc.roles)
    $doc
}

function Get-ExpertRoles {
    param([string]$PresetPath, [string]$GlobalPath, [string]$LocalPath, [switch]$NoCache)
    $usingDefaults = -not $PresetPath -and -not $PSBoundParameters.ContainsKey('GlobalPath') -and -not $PSBoundParameters.ContainsKey('LocalPath')
    if ($script:ExpertRolesCache -and -not $NoCache -and $usingDefaults) {
        return $script:ExpertRolesCache
    }
    if (-not $PresetPath) { $PresetPath = Get-ExpertRolePresetPath }

    $factory = Read-ExpertRoleFile -Path $PresetPath
    if (-not $factory) { throw "roles: the shipped preset is missing or unreadable at '$PresetPath' - this is a broken install." }

    if (-not $PSBoundParameters.ContainsKey('GlobalPath')) { $GlobalPath = Get-ExpertRoleGlobalPath }
    $global = Import-ValidatedExpertRoleFile -Path $GlobalPath
    $base   = Merge-ExpertRoles -Factory $factory -Local $global

    if (-not $PSBoundParameters.ContainsKey('LocalPath')) { $LocalPath = Get-ExpertRoleLocalPath }
    $local = Import-ValidatedExpertRoleFile -Path $LocalPath

    $catalog = Merge-ExpertRoles -Factory $base -Local $local
    if ($usingDefaults) { $script:ExpertRolesCache = $catalog }
    $catalog
}

# Dot-source guard: tests set $env:ABIOS_EXPERTROLES_DOTSOURCE to load the functions only.
if ($env:ABIOS_EXPERTROLES_DOTSOURCE) { return }

# CLI: print the effective catalog as JSON.
(Get-ExpertRoles) | ConvertTo-Json -Depth 8
