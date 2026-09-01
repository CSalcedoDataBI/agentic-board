<#  Apply-FieldPreset.ps1 — idempotently create the fields of a preset on a Projects
    board AND apply the preset's canonical single-select option colors.

    `gh project field-create` cannot set option colors (GitHub auto-assigns random
    ones) — so after ensuring a single-select field exists, this script reconciles
    its option colors via GraphQL, preserving existing option IDs (item assignments
    survive) and adding any missing options from the preset.

    Preset single-select options may be a plain string OR {name,color}. Colors are
    applied only for fields whose options carry a color (Status, Priority); plain
    string options (e.g. Type) are left with GitHub's default colors.

    STANDARDIZING IS THE DEFAULT (issue #300). A legacy option (see Get-BoardVocabulary.ps1)
    is RENAMED IN PLACE onto its canonical name: the mutation is sent with the option's
    EXISTING id and the canonical name, so every item already assigned to it keeps its
    assignment — no bulk item rewrite, no orphaned items. Renaming touches every item at once,
    so the plan is printed and confirmed first (-DryRun previews, -Yes skips the prompt for
    CI); answering `n` skips the standardizing but still applies the rest of the preset.
    This used to be opt-in behind -Migrate (issue #278), and that default WAS the bug: matching
    options by NAME only, the documented command left a template-born board's `Todo` alone and
    merely added `Backlog` NEXT TO it. Every item stayed on `Todo` and the board ended up with
    two options meaning the same thing — the one state a rename can never repair, since GitHub
    forbids two options with the same name. The tool's own happy path manufactured it.
    -NoMigrate opts out, and opting out does NOT fall back to the old behavior: the canonical
    option is then simply NOT created beside the legacy one. This script no longer has any path
    that produces a duplicate. -Migrate is still accepted, as a no-op, so older calls work.

    -MergeConflicts — resolve what -Migrate alone can only report (issue #300). A rename
    cannot take a canonical name that ALREADY exists, so a board carrying both `Todo` and
    `Backlog` is a conflict: reported, never executed. That board is not exotic — it is
    exactly what a plain `apply` (no -Migrate) produces, since it adds `Backlog` NEXT TO the
    template's `Todo`. This flag collapses the pair: the legacy option's items are MOVED to
    the canonical option, and only then is the legacy option DELETED (via the same
    updateProjectV2Field mutation used for colors, re-sending every other option by id —
    the API can do this; it never needed the UI).
    Merging is strictly more destructive than renaming — a rename keeps every option and
    every assignment, a merge destroys an option and collapses two into one — so it is opt-in
    on its own flag rather than riding along with -Migrate (-Yes must not silently delete
    options in CI).
    ORDER IS NOT OPTIONAL: move first, verify, then delete. Deleting first strands the items
    with an empty field — GitHub does not reassign them.

    Requires $env:GH_TOKEN already set (via the gh-account skill).
    Usage:
      $env:GH_TOKEN = <token>
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -Lang en             # estandariza (default)
      ./Apply-FieldPreset.ps1 -ProjectNum 13 -Owner CSalcedoDataBI -Preset en       # mismos: -ProjectNum=-Number, -Preset=-Lang
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -DryRun              # previsualiza el plan
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -Yes                 # CI / ya aprobado
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -MergeConflicts      # + resuelve duplicados viejos
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -NoMigrate           # no toca las opciones legacy
      ./Apply-FieldPreset.ps1 -Number 13 -Owner CSalcedoDataBI -PresetPath custom.json  #>
[CmdletBinding()]
param(
  # -ProjectNum is accepted as an alias so this script is invoked like the rest of the suite
  # (Board-Fill/Board-Work/Post-BoardStatusUpdate/Board-Changelog all take -ProjectNum). #297
  [Parameter(Mandatory)][Alias('ProjectNum')][int]$Number,
  [Parameter(Mandatory)][string]$Owner,
  # -Preset is accepted as an alias of -Lang: the docs and the "Preset not found" message call
  # the value (en/es) a "preset", so `-Preset en` is the intuitive spelling. #297
  [ValidateSet('en','es')][Alias('Preset')][string]$Lang = 'en',
  [string]$PresetPath,
  # Deprecated: standardizing is now the DEFAULT. Accepted so existing calls/docs keep working.
  [switch]$Migrate,
  # Opt OUT of standardizing: leave legacy option names as they are. The preset's canonical
  # option is then NOT created either — adding it beside the legacy one is what produced the
  # duplicate this script now refuses to make (#300).
  [switch]$NoMigrate,
  # Also resolve the rename CONFLICTS: move the legacy option's items onto the canonical
  # one and delete the legacy option. Destroys an option — stays opt-in.
  [switch]$MergeConflicts,
  # Print the plan (creations + renames) and exit without mutating anything.
  [switch]$DryRun,
  # Skip the migration confirmation prompt (CI / already-approved).
  [switch]$Yes
)
$ErrorActionPreference = 'Stop'

# Standardizing is the DEFAULT (#300): a board born from GitHub's template is migrated onto
# the canonical vocabulary unless you explicitly opt out. It used to be opt-in, which meant
# the documented command silently added `Backlog` NEXT TO `Todo` and left the board in the
# one state the tool could not then repair. -Migrate is kept as an accepted no-op so existing
# calls and docs do not break.
$Migrate = -not $NoMigrate
# Merging only ever resolves conflicts left over by the migration.
if ($MergeConflicts -and $NoMigrate) { Write-Error "-MergeConflicts y -NoMigrate se contradicen: el merge ES la estandarizacion."; exit 1 }

# The canonical/legacy option vocabulary — the map that says `Todo` MEANS `Backlog`.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

# A gh failure on the field-list read below must THROW, not read as "the board has no fields":
# that empty result is exactly the premise this script would then CREATE every field from (#303).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# ...and a CAPPED item read must not read as "the option is empty" - that empty result is the
# premise --merge-conflicts DELETES an option from, losing those items' field value (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

if (-not $PresetPath) { $PresetPath = Join-Path $PSScriptRoot "..\presets\fields.$Lang.json" }
# Show the RESOLVED file path, not the raw -Lang/-Preset value: "Preset not found: en" reads as
# if the preset name were wrong, when the language is fine and only the file is missing. #297
if (-not (Test-Path $PresetPath)) { Write-Error "Preset file not found: $PresetPath (use -Lang en|es, or -PresetPath for a custom file)"; exit 1 }

# read as UTF-8 explicitly so accented names (ES preset: Área, revisión…) survive on Windows PowerShell 5.1
$preset   = Get-Content $PresetPath -Raw -Encoding UTF8 | ConvertFrom-Json
$existing = (Invoke-Gh -GhArgs @('project','field-list',"$Number",'--owner',$Owner,'--format','json') `
                       -What "leer los campos del board #$Number" -Json).fields.name

function Get-OptName($o)  { if ($o -is [string]) { $o } else { $o.name } }
function Get-OptColor($o) { if ($o -is [string]) { $null } else { $o.color } }

# Read a single-select field's live id + options. Cached: the migration plan and the
# reconcile pass both need it, and it cannot change in between (we hold the only writer).
$script:FieldCache = @{}
function Get-SingleSelectField($fieldName) {
  if ($script:FieldCache.ContainsKey($fieldName)) { return $script:FieldCache[$fieldName] }
  # -Graphql fails closed on BOTH gh's exit code and a graphql errors[] body: a failed read
  # here would otherwise return a $null field and silently SKIP the color/rename it drives (#303).
  # A genuinely-absent field still comes back as $null (no errors[]), so callers' `-not $field.id`
  # guard keeps working — only a real failure now throws instead of passing as "field not found".
  $ssfQuery = '
query($owner:String!,$num:Int!,$field:String!){
  user(login:$owner){ projectV2(number:$num){
    field(name:$field){ ... on ProjectV2SingleSelectField { id options { id name color description } } }
  }}
}'
  $q = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$ssfQuery",'-F',"owner=$Owner",'-F',"num=$Number",'-f',"field=$fieldName") `
                 -What "leer el campo '$fieldName' del board #$Number" -Graphql
  $script:FieldCache[$fieldName] = $q.data.user.projectV2.field
  return $script:FieldCache[$fieldName]
}

# The board's node id — needed by `item-edit`. Read once, on demand (only merges need it).
$script:ProjectId = $null
function Get-ProjectId {
  if (-not $script:ProjectId) {
    $json = gh project view $Number --owner $Owner --format json
    # gh signals failure ONLY through the exit code here — it does not throw, even under
    # $ErrorActionPreference='Stop'. Unchecked, a 401 reads as "the board has no id".
    if ($LASTEXITCODE -ne 0) { throw "no pude leer el project #$Number (gh exit $LASTEXITCODE)" }
    $script:ProjectId = ($json | ConvertFrom-Json).id
    if (-not $script:ProjectId) { throw "el project #$Number no devolvio un id" }
  }
  return $script:ProjectId
}

# The items currently assigned to $optionName on $fieldName. Always read fresh: this is
# both the pre-move list and the post-move verification, and a stale answer here is what
# would let the delete run over items that never moved.
#
# Returns { Items; Truncated } rather than a bare array, because the caller uses an EMPTY result
# as proof that nothing is left before deleting the option - and a capped read cannot prove that
# (#484). It used to read with a bare `gh ... --limit 800`: on a board whose matching items sit
# past the cap, "0 left" was a false all-clear licensing a destructive delete.
function Get-ItemsOnOption($fieldName, $optionName) {
  $key  = ($fieldName -replace '[^A-Za-z0-9]','').ToLower()   # item-list lowercases/strips field names
  $read = Get-BoardItems -Number $Number -Owner $Owner `
                         -What "listar los items del project #$Number"
  [pscustomobject]@{
    Items     = @($read.Items | Where-Object { $_.$key -eq $optionName })
    Truncated = $read.Truncated
  }
}

# Collapse a legacy option onto its canonical one: move the items, verify, delete the option.
# Returns $true only when the option is actually gone.
function Invoke-OptionMerge($merge) {
  $proj  = Get-ProjectId
  $field = Get-SingleSelectField $merge.Field
  if (-not $field.id) { Write-Host "  (no pude leer '$($merge.Field)' para fusionar)" -ForegroundColor DarkYellow; return $false }
  $preRead = Get-ItemsOnOption $merge.Field $merge.FromName
  $items   = @($preRead.Items)
  Write-Host ("  merge: {0} '{1}' -> '{2}' ({3} item(s))" -f $merge.Field, $merge.FromName, $merge.ToName, $items.Count) -ForegroundColor Cyan

  # 1. MOVE. This must happen before the delete: GitHub does not reassign the items of a
  #    deleted option, it just leaves them with an empty field.
  $moved = 0
  foreach ($it in $items) {
    $ok = $false
    for ($i = 0; $i -lt 4; $i++) {
      # "$($it.id)" — NOT $it.id: `gh api`/`gh` do not interpolate a property off an object,
      # they receive the whole object and read it as a file path.
      $null = gh project item-edit --project-id "$proj" --id "$($it.id)" --field-id "$($field.id)" --single-select-option-id "$($merge.ToId)" 2>&1
      if ($LASTEXITCODE -eq 0) { $ok = $true; break }
      Start-Sleep -Milliseconds (500 * ($i + 1))   # backoff for transient 5xx
    }
    if ($ok) { $moved++ } else { Write-Host ("    WARN no pude mover '{0}'" -f $it.title) -ForegroundColor DarkYellow }
  }

  # 2. VERIFY before destroying anything. One un-moved item is enough to abort: the option
  #    staying is a cosmetic annoyance, an item silently losing its Status is data loss.
  $postRead = Get-ItemsOnOption $merge.Field $merge.FromName
  $left     = @($postRead.Items)
  if ($left.Count -gt 0) {
    Write-Host ("    ABORT: quedan {0} item(s) en '{1}' - NO borro la opcion (se quedarian sin {2})." -f $left.Count, $merge.FromName, $merge.Field) -ForegroundColor Red
    return $false
  }
  # An EMPTY result only proves "nothing left" when the read saw the whole board. If it stopped at
  # the cap, the items that would lose their $($merge.Field) could be exactly the ones past it - so
  # a truncated verification aborts on the same grounds as a found item, and for the same stake (#484).
  if ($postRead.Truncated) {
    Write-Host ("    ABORT: la verificacion se corto en el tope de lectura - no puedo probar que '{0}' quedo vacia, asi que NO borro la opcion." -f $merge.FromName) -ForegroundColor Red
    return $false
  }

  # 3. DELETE: re-send every OTHER option by id. Omitting one from the list IS the delete;
  #    passing the rest by id is what keeps them (and their items) intact.
  $script:FieldCache.Remove($merge.Field) | Out-Null
  $live = Get-SingleSelectField $merge.Field
  $keep = @($live.options | Where-Object { $_.id -ne $merge.FromId } | ForEach-Object {
    @{ id = $_.id; name = $_.name; color = $_.color; description = $(if ($_.description) { $_.description } else { '' }) }
  })
  $mutation = 'mutation($fieldId:ID!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!){ updateProjectV2Field(input:{ fieldId:$fieldId, singleSelectOptions:$opts }){ projectV2Field { ... on ProjectV2SingleSelectField { id } } } }'
  $body = @{ query = $mutation; variables = @{ fieldId = $live.id; opts = $keep } } | ConvertTo-Json -Depth 10
  $resp = $body | gh api graphql --input - | ConvertFrom-Json
  if ($resp.errors) {
    Write-Host ("    WARN no pude borrar la opcion '{0}': {1}" -f $merge.FromName, $resp.errors[0].message) -ForegroundColor DarkYellow
    Write-Host ("          (los {0} item(s) YA estan en '{1}' - re-corre para reintentar el borrado)" -f $moved, $merge.ToName) -ForegroundColor DarkGray
    return $false
  }
  $script:FieldCache.Remove($merge.Field) | Out-Null
  Write-Host ("    borrada '{0}' - {1} item(s) ahora en '{2}'" -f $merge.FromName, $moved, $merge.ToName) -ForegroundColor Green
  return $true
}

# Reconcile a single-select field's option colors from the preset. Preserves
# existing option IDs (so item assignments survive) and appends missing options.
# With -Migrate, a preset option with no exact name match also adopts a LEGACY
# option's id (renaming it in place) instead of being added beside it.
function Set-OptionColors($fieldName, $presetOptions) {
  $field = Get-SingleSelectField $fieldName
  if (-not $field.id) { Write-Host "  (no pude leer '$fieldName' para colorear)"; return }

  $current = @($field.options)
  $desired = @()
  $usedIds = @()   # ids already claimed by a preset option — never emit one twice (GitHub rejects it)

  # Preset options first, in preset order — preserve id by name, apply preset color.
  foreach ($po in $presetOptions) {
    $name  = Get-OptName $po
    $color = Get-OptColor $po
    $match = $current | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $match) {
      # No option carries the canonical name. Is there a LEGACY one that MEANS it?
      $legacy = $current | Where-Object {
        ($usedIds -notcontains $_.id) -and ((Get-CanonicalOptionName $fieldName $_.name) -eq $name)
      } | Select-Object -First 1
      if ($legacy -and $Migrate) {
        # Adopt it: same id + new name = rename in place; assignments survive.
        $match = $legacy
        Write-Host "  rename: $fieldName '$($legacy.name)' -> '$name' (conserva las asignaciones)" -ForegroundColor Cyan
      } elseif ($legacy) {
        # Not migrating. Emitting '$name' here would put it NEXT TO the legacy option that
        # already means it — two options for one meaning, which GitHub then forbids merging
        # by rename. That is the whole bug of #300, and this is where it was born. Refuse to
        # create it: leave the legacy option alone (the pass below re-sends it untouched).
        Write-Host "  skip: $fieldName '$name' - ya existe '$($legacy.name)' con el mismo significado; no creo una opcion duplicada." -ForegroundColor DarkYellow
        Write-Host "        (corre sin -NoMigrate para renombrar '$($legacy.name)' -> '$name' y estandarizar)" -ForegroundColor DarkGray
        continue
      }
    }
    # The mutation replaces the option list wholesale, so anything not re-sent is dropped:
    # carry the live description through or this reconcile silently wipes it.
    $entry = @{ name = $name; color = ($(if ($color) { $color } elseif ($match) { $match.color } else { 'GRAY' })); description = ($(if ($match -and $match.description) { $match.description } else { '' })) }
    if ($match) { $entry.id = $match.id; $usedIds += $match.id; if (-not $color) { $entry.color = $match.color } }
    $desired += $entry
  }
  # Any existing option NOT claimed above — keep it untouched (id + current color).
  foreach ($co in $current) {
    if ($usedIds -notcontains $co.id -and -not ($presetOptions | Where-Object { (Get-OptName $_) -eq $co.name })) {
      $desired += @{ id = $co.id; name = $co.name; color = $co.color; description = $(if ($co.description) { $co.description } else { '' }) }
    }
  }

  $mutation = 'mutation($fieldId:ID!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!){ updateProjectV2Field(input:{ fieldId:$fieldId, singleSelectOptions:$opts }){ projectV2Field { ... on ProjectV2SingleSelectField { id } } } }'
  $body = @{ query = $mutation; variables = @{ fieldId = $field.id; opts = $desired } } | ConvertTo-Json -Depth 10
  $resp = $body | gh api graphql --input - | ConvertFrom-Json
  if ($resp.errors) { Write-Host "  WARN no pude colorear '$fieldName': $($resp.errors[0].message)" -ForegroundColor DarkYellow }
  else { Write-Host "  colors: $fieldName -> $(( $desired | ForEach-Object { $_.name } ) -join ', ')" -ForegroundColor DarkCyan }
}

# ── Plan ──────────────────────────────────────────────────────────────────────
# Show what would change BEFORE touching anything: field creations, plus (with
# -Migrate) the in-place renames. Renames hit every item assigned to the option at
# once, so they are never executed without the user seeing this list.
$toCreate = @($preset.fields | Where-Object { $existing -notcontains $_.name })
$renames  = @()
$merges   = @()
if ($Migrate) {
  foreach ($f in ($preset.fields | Where-Object { $_.type -eq 'SINGLE_SELECT' -and $existing -contains $_.name })) {
    $live = Get-SingleSelectField $f.name
    if (-not $live.id) { continue }
    $renames += @(Get-LegacyOptionRenames -Field $f.name -Options @($live.options) |
                  ForEach-Object { $_ | Add-Member -NotePropertyName Field -NotePropertyValue $f.name -PassThru })
    $merges  += @(Get-LegacyOptionMerges -Field $f.name -Options @($live.options))
  }
}

if ($DryRun -or ($Migrate -and ($renames.Count -gt 0 -or $merges.Count -gt 0))) {
  Write-Host "=== Plan: preset '$Lang' sobre el board #$Number de $Owner ===" -ForegroundColor Cyan
  if ($toCreate.Count -gt 0) {
    Write-Host "  Campos a crear: $(($toCreate | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor DarkCyan
  } else {
    Write-Host "  Campos a crear: ninguno (todos existen)" -ForegroundColor DarkGray
  }
  if ($Migrate) {
    $doable = @($renames | Where-Object { -not $_.Conflict })
    $stuck  = @($renames | Where-Object { $_.Conflict })
    if ($doable.Count -eq 0 -and $merges.Count -eq 0) {
      Write-Host "  Renombres: ninguno (el board ya usa el vocabulario canonico)" -ForegroundColor DarkGray
    }
    foreach ($r in $doable) {
      Write-Host ("  rename: {0} '{1}' -> '{2}'  (los items asignados se conservan)" -f $r.Field, $r.From, $r.To) -ForegroundColor Yellow
    }
    if ($MergeConflicts) {
      # Show the blast radius BEFORE the prompt: a merge moves every item off the legacy
      # option and then destroys it, so "how many items" is the whole decision.
      foreach ($m in $merges) {
        # .Items, not the whole object: Get-ItemsOnOption returns { Items; Truncated }, and
        # @(<object>).Count is 1 - which would report "1 item(s)" for EVERY merge, on the one
        # line whose entire job is telling the user how big the destructive move is.
        $n = try {
          $r = Get-ItemsOnOption $m.Field $m.FromName
          "$(@($r.Items).Count)$(if ($r.Truncated) { '+ (lectura truncada - puede haber mas)' } else { '' })"
        } catch { '?' }
        Write-Host ("  merge:  {0} '{1}' -> '{2}'  ({3} item(s) se mueven, luego se borra '{1}')" -f $m.Field, $m.FromName, $m.ToName, $n) -ForegroundColor Yellow
      }
    } else {
      foreach ($r in $stuck) {
        # ASCII only inside the string: this file is UTF-8 with no BOM, Windows PowerShell 5.1
        # reads it as cp1252, and an em dash decodes to a `"` smart quote that closes the
        # string early — a parse error for the whole script, not just this line.
        Write-Host ("  SKIP:   {0} '{1}' -> '{2}' - '{2}' ya existe en el campo; GitHub no admite dos opciones con el mismo nombre." -f $r.Field, $r.From, $r.To) -ForegroundColor DarkYellow
      }
      if ($merges.Count -gt 0) {
        Write-Host "          Se resuelve solo: corre con -MergeConflicts para mover los items a la opcion canonica y borrar la legacy." -ForegroundColor DarkGray
        Write-Host ("          -> /board field -Number {0} -Owner {1} -MergeConflicts -DryRun" -f $Number, $Owner) -ForegroundColor DarkGray
      }
    }
  }
  Write-Host ""
}

if ($DryRun) {
  Write-Host "DRY-RUN: no se ejecuto ningun cambio." -ForegroundColor Cyan
  Write-Host "Board: https://github.com/users/$Owner/projects/$Number" -ForegroundColor Cyan

  exit 0
}

$willRename = @($renames | Where-Object { -not $_.Conflict }).Count -gt 0
$willMerge  = $MergeConflicts -and $merges.Count -gt 0
if ($Migrate -and ($willRename -or $willMerge) -and -not $Yes) {
  $what = if ($willMerge) { "cambios (incluye BORRAR opcion(es) legacy)" } else { "renombres" }
  $answer = Read-Host "Aplicar estos $what al board #$Number? (s/n)"
  if ($answer -notmatch '^(s|si|sí|y|yes)$') {
    # 'no' means "do not STANDARDIZE" — not "do nothing". The rest of the preset still applies
    # (missing fields, colors). Crucially this does NOT fall back to adding the canonical
    # option beside the legacy one: declining leaves the field exactly as it is.
    Write-Host "Sin estandarizar: dejo las opciones legacy como estan (no se crea ninguna duplicada). Sigo con el resto del preset." -ForegroundColor Yellow
    $Migrate = $false; $MergeConflicts = $false; $willMerge = $false
  }
}

# ── Apply ─────────────────────────────────────────────────────────────────────
$failedFields = @()
foreach ($f in $preset.fields) {
  if ($existing -contains $f.name) {
    Write-Host "skip (exists): $($f.name)"
  } else {
    # Through Invoke-Gh, not bare gh. `field-create` signals a refusal ONLY through its exit
    # code, and the unchecked call printed `created:` for a field GitHub had rejected — the
    # run read clean while the board came out missing the field. That is the defect reported
    # four separate times (#649, #654, #658, #667): GitHub now reserves the field name "Type",
    # so it fires on every fresh English board.
    #
    # Caught PER FIELD rather than left to propagate: one refused name must not strand the
    # fields after it. The run still ends in a hard error below, so a caller cannot mistake a
    # half-applied preset for a clean one — Resolve-Board already warns instead of claiming
    # success when this throws.
    $createArgs = if ($f.type -eq 'SINGLE_SELECT') {
      @('project','field-create',"$Number",'--owner',$Owner,'--name',$f.name,
        '--data-type','SINGLE_SELECT','--single-select-options',
        (@($f.options | ForEach-Object { Get-OptName $_ }) -join ','))
    } else {
      @('project','field-create',"$Number",'--owner',$Owner,'--name',$f.name,'--data-type',$f.type)
    }

    try {
      $null = Invoke-Gh -GhArgs $createArgs -What "crear el campo '$($f.name)' en el board #$Number"
      $script:FieldCache.Remove($f.name) | Out-Null   # it exists now — re-read its live options
      Write-Host "created: $($f.name) ($($f.type))"
    } catch {
      $reason = ($_.Exception.Message -replace '\s+', ' ').Trim()
      Write-Host "FAILED: $($f.name) ($($f.type)) — $reason" -ForegroundColor Red
      if ($reason -match 'reserved value') {
        Write-Host ("        GitHub reserva ese nombre de campo, asi que NINGUN reintento lo va a crear. " +
                    "Renombralo en el preset ($PresetPath) y vuelve a correr.") -ForegroundColor DarkYellow
      }
      $failedFields += $f.name
      continue   # no colors for a field that does not exist
    }
  }

  # Apply canonical colors when the preset provides any (idempotent; also upgrades
  # boards whose fields were created before colors were part of the preset), and
  # perform the -Migrate renames planned above.
  if ($f.type -eq 'SINGLE_SELECT' -and (@($f.options | Where-Object { Get-OptColor $_ }).Count -gt 0)) {
    Set-OptionColors $f.name $f.options
  }
}
# ── Merge ─────────────────────────────────────────────────────────────────────
# AFTER the renames above, never before: a rename frees a legacy name and takes the
# canonical one, which is what turns a second alias into a merge. Recomputed from the
# live field for the same reason — the plan was drawn on the pre-rename options.
$mergedOk = 0; $mergedFail = 0
if ($willMerge) {
  foreach ($f in ($preset.fields | Where-Object { $_.type -eq 'SINGLE_SELECT' -and $existing -contains $_.name })) {
    $script:FieldCache.Remove($f.name) | Out-Null
    $live = Get-SingleSelectField $f.name
    if (-not $live.id) { continue }
    foreach ($m in @(Get-LegacyOptionMerges -Field $f.name -Options @($live.options))) {
      if (Invoke-OptionMerge $m) { $mergedOk++ } else { $mergedFail++ }
    }
  }
}

$how = if ($MergeConflicts) { "canonical colors reconciled; legacy option names migrated in place; $mergedOk conflict(s) merged" }
       elseif ($Migrate)    { "canonical colors reconciled; legacy option names migrated in place" }
       else                 { "NOT standardized (-NoMigrate); legacy option names left as they are" }
Write-Host "Preset '$Lang' applied to project #$Number ($how)."
if ($mergedFail -gt 0) {
  Write-Host "$mergedFail merge(s) no se completaron - revisa los WARN de arriba (los items movidos YA estan en su opcion canonica; re-correr es seguro)." -ForegroundColor DarkYellow
}
if (-not $Migrate) {
  Write-Host "(Corre sin -NoMigrate para renombrar las opciones legacy -> canonicas y estandarizar el board.)" -ForegroundColor DarkGray
}
Write-Host "Board: https://github.com/users/$Owner/projects/$Number" -ForegroundColor Cyan

# A half-applied preset must never read as a clean run. Last, so the report above is complete
# and every field that COULD be created has been.
if ($failedFields.Count -gt 0) {
  Write-Error ("{0} campo(s) del preset NO se crearon: {1}. El board quedo incompleto — mira las lineas FAILED de arriba." -f `
               $failedFields.Count, ($failedFields -join ', '))
}
