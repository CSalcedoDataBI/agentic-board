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

function Get-RolesGitContext {
    # Where does this roles file sit relative to the git repository that contains it? $null when it
    # is not inside one (or git is unavailable). `--show-prefix` (not string surgery on paths) so
    # Windows 8.3 short names and symlinks cannot make the relative path wrong.
    param([string]$RolesPath)
    if (-not $RolesPath) { return $null }
    # No git on PATH: `& git` would throw under $ErrorActionPreference = 'Stop' (and never update
    # $LASTEXITCODE), and persisting a role must not fail because the repair cannot run.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $dir = Split-Path -Path $RolesPath -Parent
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $top = & git -C $dir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
    $prefix = & git -C $dir rev-parse --show-prefix 2>$null
    $rel = ([string]$prefix).TrimEnd() + (Split-Path -Path $RolesPath -Leaf)
    [pscustomobject]@{ Top = ([string]$top).Trim(); Rel = $rel }
}

function Test-GitPathIgnored {
    # Asks git itself. `check-ignore -q` exits 0 = ignored, 1 = not ignored, anything else = could
    # not tell. NOT `-v`: `-v` also exits 0 and prints the rule when that rule is a `!` negation
    # that UN-ignores the path, so it cannot answer "would git accept this file".
    param([string]$Top, [string]$Rel)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    & git -C $Top check-ignore -q -- $Rel 2>$null
    switch ($LASTEXITCODE) { 0 { $true } 1 { $false } default { $null } }
}

function Test-RolesFileTrackable {
    # True when git would accept the file, $null when git cannot say (not a repo).
    param([string]$RolesPath)
    $ctx = Get-RolesGitContext -RolesPath $RolesPath
    if (-not $ctx) { return $null }
    $ignored = Test-GitPathIgnored -Top $ctx.Top -Rel $ctx.Rel
    if ($null -eq $ignored) { return $null }
    -not $ignored
}

function Restore-GitignoreBytes {
    # Puts the original bytes back and reports whether the file now REALLY holds them. Both steps
    # can fail (read-only file, a lock, a full disk), so "restored" is read back, never assumed.
    param([string]$Path, [byte[]]$Bytes)
    try { [System.IO.File]::WriteAllBytes($Path, $Bytes) } catch { }
    try { $now = [System.IO.File]::ReadAllBytes($Path) } catch { return $false }
    [System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$Bytes)
}

function Repair-RolesGitignore {
    # A project that git-ignores `.agentic-board/` can never version roles.json, and the obvious
    # one-line fix (`!.agentic-board/roles.json` after `.agentic-board/`) does nothing: git cannot
    # re-include a file whose PARENT DIRECTORY is excluded (#470). The working form excludes the
    # directory's CONTENTS instead:   .agentic-board/*   +   !.agentic-board/roles.json
    #
    # This applies that form itself and PROVES it by asking git (check-ignore), rather than
    # emitting a snippet for a human to paste. If git still refuses afterwards - the rule lives in
    # a file this cannot edit, say the global ignore - the original .gitignore is put back byte for
    # byte and the outcome is CannotRepair.
    #
    # Status: NotARepo | AlreadyTrackable | Repaired | CannotRepair. Message lines stay short so
    # they cannot wrap in a standard terminal, and never ask the reader to run anything.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RolesPath)
    $res = [pscustomobject]@{ Status = 'NotARepo'; Changed = $false; Message = '' }
    $ctx = Get-RolesGitContext -RolesPath $RolesPath
    if (-not $ctx) { return $res }

    if ((Test-RolesFileTrackable -RolesPath $RolesPath) -eq $true) { $res.Status = 'AlreadyTrackable'; return $res }

    $rel      = $ctx.Rel
    $stateDir = ($rel -replace '/[^/]+$', '')          # e.g. .agentic-board
    $giPath   = Join-Path $ctx.Top '.gitignore'
    # Only claims "Nothing was changed" when that was VERIFIED (the file read back equal to the
    # original); otherwise it says it could not confirm, so the reader knows to look.
    $cannot = {
        param([string]$Why, [bool]$Unchanged = $true)
        $res.Status  = 'CannotRepair'
        $res.Message = @("Note: git ignores the shared role file ($rel),",
                         'so it stays on this machine only.',
                         $Why,
                         $(if ($Unchanged) { 'Nothing was changed.' }
                           else { 'I could not confirm .gitignore is back as it was - please check it.' })) -join "`n"
        $res
    }
    if (-not (Test-Path -LiteralPath $giPath -PathType Leaf)) {
        return (& $cannot 'The rule is not in a .gitignore of this repository.')
    }

    # File I/O throws real exceptions whatever $ErrorActionPreference says (read-only file, a lock
    # held by an editor or antivirus, a full disk). The role is already saved by the time this runs,
    # so a failure here must degrade to a message, never abort persisting the role.
    try { $origBytes = [System.IO.File]::ReadAllBytes($giPath) }
    catch { return (& $cannot 'I could not read .gitignore.') }
    $skip      = if ($origBytes.Length -ge 3 -and $origBytes[0] -eq 0xEF -and $origBytes[1] -eq 0xBB -and $origBytes[2] -eq 0xBF) { 3 } else { 0 }
    $text      = [System.Text.UTF8Encoding]::new($false).GetString($origBytes, $skip, $origBytes.Length - $skip)
    $eol       = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines     = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }


    $dirRule = '^(/?)' + [regex]::Escape($stateDir) + '/?\s*$'
    $lead    = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], $dirRule)
        if ($m.Success) {
            $lead = $m.Groups[1].Value
            # An unanchored rule (`.agentic-board/`) matches at ANY depth; a rule that contains a
            # slash in the middle (`.agentic-board/*`) is anchored to this .gitignore's directory.
            # Keep the reach: `**/` keeps ignoring nested state dirs (a monorepo sub-project's own
            # .agentic-board/), and the negation below re-includes only this repository's file.
            # A state dir that is itself a nested path (`sub/.agentic-board`) was already anchored.
            $lines[$i] = if ($lead -or $stateDir.Contains('/')) { "$lead$stateDir/*" } else { "**/$stateDir/*" }
        }
    }
    # Drop any earlier negation of this file (it may sit before the rewritten rule and lose to it,
    # or be the dead directory-level form), then state it once, last: the last matching rule wins.
    $negRule = '^!/?' + [regex]::Escape($rel) + '\s*$'
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $negRule) { $lines.RemoveAt($i) } }
    $lines.Add('# Versioned on purpose: the shared expert role catalog (agentic-board)')
    $lines.Add("!$lead$rel")

    try { [System.IO.File]::WriteAllText($giPath, (($lines -join $eol) + $eol), [System.Text.UTF8Encoding]::new($skip -eq 3)) }
    catch {
        # A failed write can leave the file half written: put the original back if it will let us.
        $back = Restore-GitignoreBytes -Path $giPath -Bytes $origBytes
        return (& $cannot 'I could not write .gitignore (it may be read-only or in use).' $back)
    }

    if ((Test-RolesFileTrackable -RolesPath $RolesPath) -eq $true) {
        $res.Status  = 'Repaired'; $res.Changed = $true
        $res.Message = @("Fixed: git was ignoring the shared role file ($rel),",
                         'so it would never have reached your team. I adjusted .gitignore',
                         'and checked with git that it now accepts the file.',
                         "The rest of $stateDir/ stays ignored. Nothing for you to run.") -join "`n"
        return $res
    }
    $back = Restore-GitignoreBytes -Path $giPath -Bytes $origBytes   # exact restore, read back
    & $cannot 'Git still refuses it after the change: the rule is somewhere I cannot edit.' $back
}

function Add-ExpertRole {
    # Writing a role changes how every future plan is classified, so callers must confirm first.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Role, [string]$Path)
    $usedDefaultPath = -not $Path
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
    # (#470) The project-local catalog is team knowledge meant to be versioned. If the project's
    # .gitignore excludes the state directory, the role just written would silently never be shared
    # (and the obvious one-line fix does nothing). Repair it here, verified against git, so nobody
    # has to be asked about git or told to paste a command. Only for the default local path: an
    # explicit -Path is the caller's business, and the global file lives outside any project.
    if ($usedDefaultPath) {
        $fix = Repair-RolesGitignore -RolesPath $Path
        if ($fix.Status -in 'Repaired', 'CannotRepair') { Write-Host $fix.Message }
    }
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
