<#  Get-BoardVocabulary.ps1 - the single source of truth for the board's option
    vocabulary: the CANONICAL option names (presets/fields.en.json) plus the
    LEGACY names that mean the same thing (GitHub's default Projects template,
    older hand-made boards).

    Why this exists (issue #278): the tool used to resolve options by one literal
    name per call site, and the call sites disagreed - Board-Work looked for
    'Backlog' (canonical) while Board-Fill looked for 'P2 Medium' (GitHub's
    template). No board could satisfy both. Every option lookup now goes through
    this map, so a board is understood whichever vocabulary it was born with, and
    Apply-FieldPreset -Migrate can rename the legacy names onto the canonical ones.

    Pure: dot-source it, it defines functions and data only (no gh, no output).
      . (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

    All name comparisons are case-insensitive (PowerShell -eq / hashtable default).
#>

# Canonical option names per field, in preset order. Keep in sync with presets/fields.en.json.
$script:AbiosCanonicalOptions = @{
    Status   = @('Backlog', 'In Progress', 'In Review', 'Blocked', 'Done')
    Priority = @('P0', 'P1', 'P2', 'P3')
    Size     = @('XS', 'S', 'M', 'L', 'XL')
}

# Legacy names accepted as the same option. Key = canonical name, value = the
# aliases seen in the wild. Only add a name here when it unambiguously means the
# canonical one - an alias makes the tool ACT on the option (and -Migrate rename it).
$script:AbiosOptionAliases = @{
    Status   = @{
        'Backlog'   = @('Todo', 'To Do', 'To do', 'ToDo')
        'In Review' = @('Review', 'In review')
    }
    Priority = @{
        'P0' = @('P0 Critical', 'Critical')
        'P1' = @('P1 High', 'High')
        'P2' = @('P2 Medium', 'Medium')
        'P3' = @('P3 Low', 'Low')
    }
    Size     = @{}
}

# The canonical option names of a field ('Status', 'Priority', 'Size'), or an
# empty array for a field this tool has no opinion about (e.g. Type, or the ES
# preset's 'Estado' - a different field name, deliberately not migrated).
function Get-CanonicalOptionNames([string]$Field) {
    if ($Field -and $script:AbiosCanonicalOptions.ContainsKey($Field)) { @($script:AbiosCanonicalOptions[$Field]) } else { @() }
}

# $true only when $Name is EXACTLY a canonical option of $Field.
function Test-CanonicalOptionName([string]$Field, [string]$Name) {
    if (-not $Name) { return $false }
    (Get-CanonicalOptionNames $Field) -contains $Name
}

# Resolve any known name (canonical OR legacy alias) to its canonical name.
# Returns $null for a name this tool does not recognize - the caller must then
# treat the board's vocabulary as unknown rather than guess.
function Get-CanonicalOptionName([string]$Field, [string]$Name) {
    if (-not $Name) { return $null }
    if (Test-CanonicalOptionName $Field $Name) { return ((Get-CanonicalOptionNames $Field) | Where-Object { $_ -eq $Name } | Select-Object -First 1) }
    if (-not $script:AbiosOptionAliases.ContainsKey($Field)) { return $null }
    foreach ($canon in $script:AbiosOptionAliases[$Field].Keys) {
        if (@($script:AbiosOptionAliases[$Field][$canon]) -contains $Name) { return $canon }
    }
    return $null
}

# Every name that may carry a canonical option's value, canonical FIRST then its
# legacy aliases. Callers resolve an option id by walking this list in order, so a
# canonical board always wins over a legacy match.
function Get-OptionAliases([string]$Field, [string]$Canonical) {
    $names = @($Canonical)
    if ($script:AbiosOptionAliases.ContainsKey($Field) -and $script:AbiosOptionAliases[$Field].ContainsKey($Canonical)) {
        $names += @($script:AbiosOptionAliases[$Field][$Canonical])
    }
    @($names)
}

# The rename plan that puts a field's LEGACY options onto the canonical names.
# $Options = the field's existing options (objects with .id / .name).
#
# Renaming is done by option ID, so item assignments survive (see Apply-FieldPreset).
# An option is only planned when it is a known legacy alias; unknown names are left
# alone (never guess). A rename is flagged Conflict - reported, never executed - when
# the canonical name cannot actually be taken, because GitHub rejects two options with
# the same name. That happens two ways:
#   - the canonical name ALREADY exists on the field (e.g. both 'Todo' and 'Backlog'), or
#   - two legacy aliases claim the SAME canonical name (e.g. both 'Todo' and 'To Do'):
#     only the first can take it, so the rest are conflicts. Without this the plan
#     promised two safe renames to 'Backlog' and only one ever happened - a plan that
#     lies about what it will do (Codex review, PR #279).
function Get-LegacyOptionRenames {
    param([string]$Field, [object[]]$Options)
    $existing = @($Options | ForEach-Object { $_.name })
    $claimed  = @()   # canonical names already spoken for by an earlier rename in this plan
    foreach ($o in @($Options)) {
        $canon = Get-CanonicalOptionName $Field $o.name
        if (-not $canon)         { continue }   # unknown vocabulary - not ours to rename
        if ($canon -eq $o.name)  { continue }   # already canonical
        $taken = (@($existing | Where-Object { $_ -eq $canon }).Count -gt 0) -or
                 (@($claimed  | Where-Object { $_ -eq $canon }).Count -gt 0)
        if (-not $taken) { $claimed += $canon }
        [pscustomobject]@{
            Id       = $o.id
            From     = $o.name
            To       = $canon
            Conflict = $taken
        }
    }
}

# The merge plan that RESOLVES the conflicts Get-LegacyOptionRenames can only report.
# A rename cannot take a canonical name that already exists, so 'Todo' stays beside
# 'Backlog' forever - and that is the exact state a plain `apply` (no -Migrate) leaves
# behind, since it adds 'Backlog' next to the template's 'Todo'. Merging collapses them:
# the legacy option's items move to the canonical option, then the legacy option is
# deleted (updateProjectV2Field, re-sending every other option by id).
#
# $Options = the field's existing options (objects with .id / .name).
# Returns one entry per legacy option that can be collapsed onto an EXISTING canonical
# one. Unknown names are never touched (same rule as the renames: never guess).
#
# Reasons about the field as it will look AFTER the renames, because that is when the
# merges run: a successful rename ('Todo' -> 'Backlog') is what makes a SECOND alias
# ('To Do' beside it) a merge rather than a conflict. Planning on the raw options would
# under-report those - and a plan that lies about what it will do is the bug PR #279
# already fixed once.
#
# EXECUTION ORDER IS NOT OPTIONAL: move the items FIRST, verify the move, and only then
# delete the legacy option. Deleting first strands every item on it with an empty field -
# GitHub does not reassign them.
function Get-LegacyOptionMerges {
    param([string]$Field, [object[]]$Options)
    $renames = @(Get-LegacyOptionRenames -Field $Field -Options $Options)
    $projected = foreach ($o in @($Options)) {
        $r = $renames | Where-Object { $_.Id -eq $o.id -and -not $_.Conflict } | Select-Object -First 1
        [pscustomobject]@{ id = $o.id; name = $(if ($r) { $r.To } else { $o.name }) }
    }
    foreach ($o in @($projected)) {
        $canon = Get-CanonicalOptionName $Field $o.name
        if (-not $canon)        { continue }   # unknown vocabulary - not ours to touch
        if ($canon -eq $o.name) { continue }   # already canonical (incl. just renamed)
        $target = @($projected | Where-Object { $_.name -eq $canon }) | Select-Object -First 1
        if (-not $target) { continue }         # canonical name is free - a rename handles it
        [pscustomobject]@{
            Field    = $Field
            FromId   = $o.id
            FromName = $o.name
            ToId     = $target.id
            ToName   = $canon
        }
    }
}
