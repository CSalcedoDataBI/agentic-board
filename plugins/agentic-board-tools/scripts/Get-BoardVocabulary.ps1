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

# ── Field NAMES (#671) ────────────────────────────────────────────────────────
# The option map above answers "what does this OPTION mean". This answers the question one level up,
# which had no single answer: "what is this FIELD called on THIS board". Every script spelled the
# name by hand ('Type' in five of them), so:
#   - GitHub now RESERVES the field name 'Type' ("Name cannot have a reserved value"): the English
#     preset could not create it on a fresh board, and the preset alone cannot be renamed without
#     the five scripts losing the field;
#   - a board made with the Spanish preset (Estado/Prioridad/Tamano/Tipo/Area/Estimado/Objetivo) was
#     invisible to Board-Fill and Board-Triage, which then "succeeded" over blank columns (#509);
#   - a board created before the reservation still has a working 'Type' field that must keep working.
# So callers ask for a KEY ('Type') and the board answers with whatever it calls it. Names are listed
# in PREFERENCE order: when a board carries two, the first wins, and an existing 'Type' outranks the
# 'Task Type' the English preset now creates. Accented names are built from code points so this file
# parses the same on Windows PowerShell 5.1 whatever its encoding.
$script:AbiosFieldNames = [ordered]@{
    Status   = @('Status', 'Estado')
    Priority = @('Priority', 'Prioridad')
    Size     = @('Size', ('Tama' + [char]0x00F1 + 'o'), 'Tamano')
    Type     = @('Type', 'Task Type', 'Tipo')
    Area     = @('Area', ([string][char]0x00C1 + 'rea'))
    Estimate = @('Estimate', 'Estimado')
    Target   = @('Target', 'Objetivo')
}

# The field-name KEYS the suite knows, in a stable order.
function Get-BoardFieldKeys { @($script:AbiosFieldNames.Keys) }

# Every name a key may carry on a board, in preference order; @() for a key this tool has no opinion about.
function Get-BoardFieldNames([string]$Key) {
    if ($Key -and $script:AbiosFieldNames.Contains($Key)) { @($script:AbiosFieldNames[$Key]) } else { @() }
}

# The key a field NAME belongs to ('Tipo' -> 'Type'), or $null for a name that is not part of the
# vocabulary. Case-insensitive.
function Get-BoardFieldKey([string]$Name) {
    if (-not $Name) { return $null }
    foreach ($k in $script:AbiosFieldNames.Keys) {
        if (@($script:AbiosFieldNames[$k]) -contains $Name) { return $k }
    }
    return $null
}

# The name THIS board uses for a key: the first accepted name present in $Available (the board's field
# names), or $null when it has none of them. A key outside the vocabulary is looked up by its own name.
function Resolve-BoardFieldName {
    param([string]$Key, [string[]]$Available)
    $names = @(Get-BoardFieldNames $Key)
    if ($names.Count -eq 0) { $names = @($Key) }
    foreach ($n in $names) {
        if (@($Available) -contains $n) { return @($Available) | Where-Object { $_ -eq $n } | Select-Object -First 1 }
    }
    return $null
}

# The live field OBJECT (anything with a .name) that carries a key on this board, or $null.
function Find-BoardField {
    param([string]$Key, [object[]]$Fields)
    $live = Resolve-BoardFieldName -Key $Key -Available @(@($Fields) | Where-Object { $_ } | ForEach-Object { $_.name })
    if (-not $live) { return $null }
    return @($Fields) | Where-Object { $_ -and $_.name -eq $live } | Select-Object -First 1
}

# Which of the given keys resolve on this board, and which do not. Callers use the second list to
# WARN: a script that silently finds none of its fields and reports a clean run is the #509 failure.
function Get-BoardFieldCoverage {
    param([string[]]$Keys, [object[]]$Fields)
    $found = @(); $missing = @()
    foreach ($k in $Keys) { if (Find-BoardField -Key $k -Fields $Fields) { $found += $k } else { $missing += $k } }
    [pscustomobject]@{ Found = @($found); Missing = @($missing); NoneFound = ($found.Count -eq 0 -and @($Keys).Count -gt 0) }
}

# A comparison key that survives every way a field name gets rewritten on its way to a JSON property:
# accents folded, everything but letters and digits dropped, lower-cased. 'Task Type', 'task type' and
# 'taskType' all become 'tasktype'; 'Area' with an accent becomes 'area'.
function ConvertTo-FieldMatchKey([string]$Name) {
    if (-not $Name) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return ($sb.ToString() -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

# Read one field's value off a `gh project item-list` row. gh keys the row by a rewrite of the field
# name (lower-cased, spaces kept: 'linked pull requests'), and the old lookup assumed a different
# rewrite (spaces stripped), which would have missed 'Task Type'. Comparing by ConvertTo-FieldMatchKey
# makes the read independent of the rewrite. $null when the item has no such property.
# The fold also makes two DIFFERENT fields collide ('Area' / the accented 'Area', 'Tamano' / 'Tamano'
# with a tilde), which a legacy board can carry side by side while the vocabulary deliberately picks
# one of them. So an EXACT property name (case-insensitive, accents kept) always wins, and the fold
# is only a fallback: when it would have to choose between several different properties it answers
# $null instead of guessing which field the caller meant.
function Get-ItemFieldValue {
    param([object]$Item, [string]$FieldName)
    if (-not $Item -or -not $FieldName) { return $null }
    foreach ($p in $Item.PSObject.Properties) {
        if ($p.Name -eq $FieldName) { return $p.Value }
    }
    # Fallback: a property that is EXACTLY another accepted name of the same field is that other
    # field's value, never this one's - the fold must not turn one into the other.
    $key    = Get-BoardFieldKey $FieldName
    $others = @(Get-BoardFieldNames $key | Where-Object { $_ -ne $FieldName })
    $want   = ConvertTo-FieldMatchKey $FieldName
    $hits   = @($Item.PSObject.Properties | Where-Object { ($others -notcontains $_.Name) -and ((ConvertTo-FieldMatchKey $_.Name) -eq $want) })
    if ($hits.Count -eq 1) { return $hits[0].Value }
    return $null
}

# The value of a KEY out of a { field name -> value } table (what Fleet-Plan builds from an item's
# field values), whatever the board calls the field.
function Get-ValueByFieldKey {
    param([hashtable]$ByName, [string]$Key)
    $live = Resolve-BoardFieldName -Key $Key -Available @($ByName.Keys)
    if ($live) { return $ByName[$live] }
    return $null
}

# Option SYNONYMS for lookups only (Fill/Triage/Changelog resolving a name to an option). Deliberately a
# separate table from $script:AbiosOptionAliases: those aliases drive RENAMES and MERGES, and nothing
# here may make Apply-FieldPreset rewrite a Spanish board's options into English ones.
$script:AbiosOptionSynonyms = @{
    Type = @{
        Feature     = @('Funcionalidad')
        Improvement = @('Mejora')
        Chore       = @('Tarea')
    }
}

# The names a canonical option may carry on a board: the canonical name first, then its synonyms.
function Get-OptionSynonymNames([string]$Key, [string]$Canonical) {
    $names = @($Canonical)
    if ($script:AbiosOptionSynonyms.ContainsKey($Key) -and $script:AbiosOptionSynonyms[$Key].ContainsKey($Canonical)) {
        $names += @($script:AbiosOptionSynonyms[$Key][$Canonical])
    }
    @($names)
}

# The canonical name an option name stands for ('Funcionalidad' -> 'Feature'); the name itself when it
# is not a known synonym, so an unknown option passes through unchanged rather than being guessed at.
function Get-CanonicalSynonym([string]$Key, [string]$Name) {
    if ($Key -and $Name -and $script:AbiosOptionSynonyms.ContainsKey($Key)) {
        foreach ($canon in $script:AbiosOptionSynonyms[$Key].Keys) {
            if ($canon -eq $Name -or @($script:AbiosOptionSynonyms[$Key][$canon]) -contains $Name) { return $canon }
        }
    }
    return $Name
}

# Find the option of a single-select field that a value stands for: the exact name first, then any
# synonym of its canonical name. $Options = objects with .id / .name. $null when none fits.
function Find-FieldOption {
    param([object[]]$Options, [string]$Key, [string]$Value)
    if (-not $Value) { return $null }
    $exact = @($Options) | Where-Object { $_ -and $_.name -eq $Value } | Select-Object -First 1
    if ($exact) { return $exact }
    foreach ($n in (Get-OptionSynonymNames $Key (Get-CanonicalSynonym $Key $Value))) {
        $o = @($Options) | Where-Object { $_ -and $_.name -eq $n } | Select-Object -First 1
        if ($o) { return $o }
    }
    return $null
}

# The name a PRESET field already has on a board, or $null when it has to be created. The exact name
# counts, and so does any other name of the same key: a preset that asks for 'Task Type' is satisfied
# by a board's existing 'Type' (creating a second type field beside it is the duplicate this exists to
# prevent), and the Spanish preset's 'Estado' by the 'Status' every board is born with.
function Resolve-PresetFieldName {
    param([string]$PresetName, [string[]]$Existing)
    if (@($Existing) -contains $PresetName) { return @($Existing) | Where-Object { $_ -eq $PresetName } | Select-Object -First 1 }
    $key = Get-BoardFieldKey $PresetName
    if (-not $key) { return $null }
    return Resolve-BoardFieldName -Key $key -Available @($Existing)
}
