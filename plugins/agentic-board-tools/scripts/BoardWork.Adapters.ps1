# BoardWork.Adapters.ps1 - the CLI adapter registry, probes and per-issue CLI picker,
# extracted VERBATIM from Board-Work.ps1 (#759). Function definitions only; Board-Work
# dot-sources this file before its own dot-source guard, so tests see the same surface.
# Get-ReviewerRoster.ps1 dot-sources it too, for the probe classifier (#770), and so does
# Fleet-Plan.ps1: since #772 the adapter DATA lives in presets/adapters.json, and both derive
# their tables (the reviewer roster, the routing) from that one registry.

# =======================================================================
# Probe codes (#770): a CLOSED set. Every probe result is exactly one of these six.
#
# Before #770 one Get-CliProbeStatus ran a single regex list over every CLI's output, returned
# free-form words ('ok', 'no-quota', ...), and called anything that tripped no failure regex on
# exit 0 'ok'. "Nothing looked wrong" is not "it works": that is the same false-pass shape that
# let a refusal pass for a review in #651. Now:
#   * each adapter declares how ITS output reads (ProbeRules, an ordered list), so a Copilot
#     quota message and a jules session listing are handled where they are known;
#   * OK needs POSITIVE evidence - an adapter's OK rule matching on exit 0. A quota or limit
#     message on exit 0 therefore never reads as OK;
#   * output no rule recognises fails CLOSED to ERROR, never to OK.
# =======================================================================
function Get-CliProbeCodes { @('OK', 'AUTH', 'RATE_LIMIT', 'QUOTA', 'CONTEXT_WINDOW', 'ERROR') }

# Availability states that are NOT probe results, kept outside the probe set on purpose:
#   NOT_INSTALLED  the command is not on PATH - the probe never ran. Folding it into ERROR would
#                  hide the one state the fleet can fix (it offers the install).
#   NEEDS_BYPASS   the probe said OK, but the CLI cannot run unattended without a permission
#                  bypass the human did not opt in to (#761).
function Get-CliAvailabilityStates { @(Get-CliProbeCodes) + @('NOT_INSTALLED', 'NEEDS_BYPASS') }

# Pin a value to the closed set. Case-SENSITIVE on purpose: a leftover 'ok' from an old-style
# probe is not 'OK', and anything outside the set fails closed to ERROR. Pure.
function Confirm-CliProbeCode([string]$Code) {
    if ((Get-CliProbeCodes) -ccontains $Code) { return $Code }
    return 'ERROR'
}

# One classification rule: when Pattern matches the probe output, the result is Code. An OK rule
# only counts on exit 0; every other rule counts on any exit code (some CLIs print a quota or auth
# error and still exit 0). Reason is the human sentence a caller may print.
function New-CliProbeRule([string]$Code, [string]$Pattern, [string]$Reason) {
    [PSCustomObject]@{ Code = (Confirm-CliProbeCode $Code); Pattern = $Pattern; Reason = $Reason }
}

# Map one probe run to { Code; Reason }. Walks the adapter's ProbeRules IN ORDER and the first
# match wins; with no match the result is ERROR (fails closed). -Rules overrides the lookup so
# the classifier can be exercised without the registry. Pure.
function Resolve-CliProbeOutcome {
    param(
        [string]$Cli,
        [int]$ExitCode,
        [AllowEmptyString()][AllowNull()][string]$Output,
        [object[]]$Rules
    )
    if (-not $PSBoundParameters.ContainsKey('Rules')) {
        $adapter = Get-CliAdapters | Where-Object Name -eq $Cli | Select-Object -First 1
        $Rules   = if ($adapter) { @($adapter.ProbeRules) } else { @() }
    }
    $text = "$Output"
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        if ($r.Code -ceq 'OK' -and $ExitCode -ne 0) { continue }
        if ($text -match $r.Pattern) {
            return [PSCustomObject]@{ Code = (Confirm-CliProbeCode $r.Code); Reason = $r.Reason }
        }
    }
    $reason = if ($ExitCode -ne 0) { "exited $ExitCode with output no rule recognises" }
              elseif (-not $text.Trim()) { 'exited 0 but printed nothing - that is no evidence the CLI works' }
              else { 'exited 0 but the output is not the expected answer (unrecognised output fails closed)' }
    return [PSCustomObject]@{ Code = 'ERROR'; Reason = $reason }
}

# Just the code. Pure.
function ConvertTo-CliProbeCode([string]$Cli, [int]$ExitCode, [string]$Output) {
    (Resolve-CliProbeOutcome -Cli $Cli -ExitCode $ExitCode -Output $Output).Code
}

# A CLI that is out of quota or rate limited is skipped for the rest of a fleet run (the runtime
# backoff of Invoke-FleetDispatch); any other non-OK state is handled by the claude fallback. Pure.
function Test-CliProbeExhausted([string]$Code) { @('QUOTA', 'RATE_LIMIT') -ccontains $Code }

# =======================================================================
# CLI adapter registry (#772): one record per launchable AI CLI, read from DATA.
#
# Before #772 the adapters were PowerShell literals here, and the same knowledge was repeated in
# the routing table of Fleet-Plan.ps1 and the reviewer list of Get-ReviewerRoster.ps1 - adding a
# backend meant editing three files and keeping a copy honest with a test. Now the data lives in
# presets/adapters.json, with the same three tiers as presets/roles.json (ExpertRolesIo.ps1):
#
#   presets/adapters.json            factory, ships with the plugin (a broken one THROWS)
#   ~/.agentic-board/adapters.json   this user, every project, not versioned
#   .agentic-board/adapters.json     this project, versioned - routing / reviewer ONLY: it comes
#                                    with a clone, and a clone must not get code execution
#
# Merge rule: an override entry names an adapter; every field it states replaces that field
# wholesale (arrays and objects included), fields it omits are inherited, and the later tier wins.
# A name the earlier tiers do not know ADDS an adapter. An override file that does not parse or
# declares another schema version is ignored with a warning (as roles.json is); an override
# ENTRY that fails validation costs only itself - it is rejected with a warning and the previous
# tier's definition stays. Validation is security, not tidiness (Test-CliAdapterSpec):
#   * install argv is exactly `npm i -g <pkg>@x.y.z` - an override cannot smuggle in an unpinned
#     or arbitrary install (#765); no argv means an https page instead;
#   * every probe rule's code is in the closed set (#770);
#   * command, bypass flags and launch arguments are restricted so the generated launch script
#     can never be broken out of (see Format-CliTemplateLaunch).
#
# The returned objects keep the pre-#772 shape (Name, Command, Kind, IsDefault, InstallArgs,
# InstallUrl, Probe, ProbeRules, BypassArgs, RequiresBypass, KeepEnv, BuildLaunch) plus ProbeArgs,
# Routing, Reviewer and Source, so every existing caller keeps working.
# Kind: 'repl' = live tab in the worktree; 'async' = dispatches a cloud task.
# =======================================================================
$script:CliAdapterSchemaVersion = 1
$script:CliAdapterCache         = $null
$script:CliAdapterRepoPathCache = @{}

# Launch construction that is genuinely CODE, keyed by adapter name. claude's launch sets up the
# auth variable before the CLI starts (several statements, one per line) - not expressible as an
# argument template without inventing a scripting language in JSON. Every other adapter's launch
# is a template in the registry (launch.args).
$script:CliBuiltinLaunchers = @{ claude = 'Build-ClaudeLaunch' }

# Override files may set these fields on an adapter. 'note' is free text the loader ignores (JSON
# has no comments; it keeps the WHY next to the data).
$script:CliAdapterFields = @('name', 'note', 'command', 'kind', 'isDefault', 'lowTrust', 'installArgs', 'installUrl',
    'probeArgs', 'probeRules', 'bypassArgs', 'requiresBypass', 'keepEnv', 'launch', 'routing', 'reviewer')

# A LOW-TRUST adapter (#773, the dsh pilot): a backend we run sandboxed and only on work whose
# content is already public. Enforced in code, not left to the docs:
#   * it may rank only these routes, and is never a reviewer nor the default (Test-CliAdapterSpec);
#   * the planner offers it only for an issue whose repo visibility is known to be PUBLIC, and the
#     fleet launch re-checks that visibility - unknown fails closed (Test-CliLowTrustAllowed);
#   * a later tier cannot clear the flag on an adapter an earlier tier marked low-trust.
$script:CliLowTrustRoutes = @('docs', 'chore')
# The only fields the REPO tier may set, on existing adapters (see Import-CliAdapterRegistry).
$script:CliAdapterRepoFields = @('name', 'note', 'routing', 'reviewer')

function Clear-CliAdapterCache { $script:CliAdapterCache = $null; $script:CliAdapterRepoPathCache = @{} }

function Get-CliAdapterPresetPath { Join-Path (Split-Path $PSScriptRoot -Parent) 'presets/adapters.json' }

# The user tier. $env:ABIOS_ADAPTERS_USER_FILE overrides it (tests point it at $TestDrive so the
# real ~/.agentic-board is never read). Same state dir as the global roles.json; -NoCreate because
# a lookup must not create a directory.
function Get-CliAdapterUserPath {
    if ($env:ABIOS_ADAPTERS_USER_FILE) { return $env:ABIOS_ADAPTERS_USER_FILE }
    $home_ = if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
    if (-not $home_) { return $null }
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir -Root $home_ -NoCreate
    if (-not $dir) { return $null }
    Join-Path $dir 'adapters.json'
}

# The project tier, in the main clone's state dir (shared by every worktree). $env:ABIOS_ADAPTERS_
# REPO_FILE overrides it. Resolving it costs a `git rev-parse`, and the classifier looks the
# registry up per probe, so the answer is remembered per working directory.
function Get-CliAdapterRepoPath {
    if ($env:ABIOS_ADAPTERS_REPO_FILE) { return $env:ABIOS_ADAPTERS_REPO_FILE }
    $here = "$PWD"
    if ($script:CliAdapterRepoPathCache.ContainsKey($here)) { return $script:CliAdapterRepoPathCache[$here] }
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir  = Get-AbiosStateDir -NoCreate
    $path = if ($dir) { Join-Path $dir 'adapters.json' } else { $null }
    $script:CliAdapterRepoPathCache[$here] = $path
    $path
}

# Parse one registry file into a hashtable; $null when absent. An unreadable OVERRIDE is ignored
# with a warning (the roles.json behaviour); an unreadable PRESET is a broken install and throws.
function Read-CliAdapterFile {
    [CmdletBinding()]
    param([string]$Path, [switch]$Required)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) { throw "adapters: the shipped preset is missing at '$Path' - this is a broken install." }
        return $null
    }
    try {
        # -NoEnumerate: a top-level array of ONE object would otherwise unwrap into that object and
        # pass for a document.
        $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
        if ($doc -isnot [hashtable]) { throw 'the top level is not a JSON object' }
        $doc
    } catch {
        if ($Required) { throw "adapters: the shipped preset '$Path' is unreadable ($($_.Exception.Message)) - this is a broken install." }
        Write-Warning "adapters: could not parse '$Path' ($($_.Exception.Message)) - ignoring it."
        $null
    }
}

# One probe rule -> its validation errors. Pure.
function Test-CliProbeRuleSpec([object]$Rule) {
    if ($Rule -isnot [System.Collections.IDictionary]) { return @('a probe rule is not an object') }
    if ($Rule.Contains('include')) {
        if ($Rule.include -cne 'common') { return @("unknown probe rule include '$($Rule.include)' (only 'common')") }
        return @()
    }
    $errs = @()
    # The closed set (#770), case-SENSITIVE: an override cannot invent a seventh code or slip in
    # a lower-case 'ok' that Confirm-CliProbeCode would later have to pin to ERROR.
    if ((Get-CliProbeCodes) -cnotcontains [string]$Rule.code) {
        $errs += "unknown probe code '$($Rule.code)' (allowed: $((Get-CliProbeCodes) -join ', '))"
    }
    if (-not ($Rule.pattern -is [string]) -or -not $Rule.pattern) { $errs += 'a probe rule has no pattern' }
    else { try { $null = [regex]::new($Rule.pattern) } catch { $errs += "probe pattern '$($Rule.pattern)' is not a valid regex" } }
    if ($null -ne $Rule.reason -and $Rule.reason -isnot [string]) { $errs += 'a probe rule reason is not a string' }
    $errs
}

# One merged adapter definition -> its validation errors (empty = valid). Pure. Applied to the
# RESULT of a merge, so an override is judged by what it would produce, not by its fragment.
function Test-CliAdapterSpec {
    param([System.Collections.IDictionary]$Spec, [string[]]$RouteNames = @())
    $errs = [System.Collections.Generic.List[string]]::new()
    $name = [string]$Spec.name
    if ($name -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { $errs.Add("name '$name' must be lower-case letters, digits and '-'") }
    # The command is written UNQUOTED into the launch script and looked up on PATH: a bare
    # executable name only - no path, no space, nothing PowerShell would parse.
    if ([string]$Spec.command -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $errs.Add("command '$($Spec.command)' must be a bare executable name") }
    if (@('repl', 'async') -cnotcontains [string]$Spec.kind) { $errs.Add("kind '$($Spec.kind)' must be repl or async") }
    foreach ($b in 'isDefault', 'requiresBypass', 'reviewer') {
        if ($Spec[$b] -isnot [bool]) { $errs.Add("$b must be true or false") }
    }
    # Resolve-LaunchCli falls back to 'claude' by name, so the default is claude and only claude.
    if ($Spec.isDefault -is [bool] -and $Spec.isDefault -ne ($name -ceq 'claude')) {
        $errs.Add("isDefault must be true for claude and false for every other adapter (the fallback is hard-wired to claude)")
    }
    # #773: optional (absent = false). A low-trust adapter is confined to the low-risk routes and
    # can never judge another CLI's work.
    if ($Spec.Contains('lowTrust') -and $Spec.lowTrust -isnot [bool]) { $errs.Add('lowTrust must be true or false') }
    if ($Spec.lowTrust -eq $true) {
        if ($Spec.isDefault -eq $true) { $errs.Add('a lowTrust adapter cannot be the default') }
        if ($Spec.reviewer -eq $true)  { $errs.Add('a lowTrust adapter cannot be a reviewer (#773)') }
        if ($Spec.routing -is [System.Collections.IDictionary]) {
            $bad = @($Spec.routing.Keys | Where-Object { $script:CliLowTrustRoutes -cnotcontains $_ })
            if ($bad.Count) { $errs.Add("a lowTrust adapter may only rank the routes $($script:CliLowTrustRoutes -join ', ') (#773); got $($bad -join ', ')") }
        }
    }

    # #765: a pinned argv or nothing. The shape is EXACT - npm, i|install, -g, <pkg>@x.y.z - so an
    # override can neither drop the version nor swap the installer for another program.
    if ($null -ne $Spec.installArgs) {
        $ia = @($Spec.installArgs)
        $shapeOk = $ia.Count -eq 4 -and ($ia | Where-Object { $_ -isnot [string] }).Count -eq 0 -and
                   $ia[0] -ceq 'npm' -and @('i', 'install') -ccontains $ia[1] -and $ia[2] -ceq '-g' -and
                   $ia[3] -cmatch '^@?[\w.-]+(/[\w.-]+)?@\d+\.\d+\.\d+$'
        if (-not $shapeOk) { $errs.Add("installArgs must be exactly ['npm','i','-g','<package>@x.y.z'] - an exact pinned version (#765); got '$($ia -join ' ')'") }
    }
    if ($null -ne $Spec.installUrl -and [string]$Spec.installUrl -cnotmatch '^https://\S+$') {
        $errs.Add("installUrl must be an https:// URL")
    }

    # Flags only (letters, digits, . _ = -), separated by single spaces: written unquoted after
    # the command, so nothing here may be a PowerShell metacharacter ($ ; | & ` ' " ( ) { } @ # %).
    $bypass = if ($null -eq $Spec.bypassArgs) { '' } else { $Spec.bypassArgs }
    if ($bypass -isnot [string] -or $bypass -cnotmatch '^([A-Za-z0-9._=-]+( [A-Za-z0-9._=-]+)*)?$') {
        $errs.Add("bypassArgs '$bypass' may only hold flags (letters, digits, . _ = -) separated by spaces")
    }

    # Probe: the argv of an auth check, starting with the command. $null only for the host CLI
    # (claude runs these scripts, so it is always available and probes nothing).
    if ($null -eq $Spec.probeArgs) {
        if ($Spec.isDefault -ne $true) { $errs.Add('probeArgs is required (only the host CLI, claude, may omit it)') }
    } else {
        $pa = @($Spec.probeArgs)
        if ($pa.Count -lt 1 -or ($pa | Where-Object { $_ -isnot [string] -or $_ -match "[\r\n\0]" }).Count -gt 0) {
            $errs.Add('probeArgs must be a list of single-line strings')
        } elseif ($pa[0] -cne [string]$Spec.command) {
            $errs.Add("probeArgs must start with the command '$($Spec.command)'")
        }
        # #761: a probe never carries the permission bypass - a one-token reply calls no tool.
        $flags = @("$bypass" -split ' ' | Where-Object { $_ -like '-*' })
        if ($flags.Count -and @($pa | Where-Object { $flags -ccontains $_ }).Count) { $errs.Add('probeArgs must not carry the permission bypass flag (#761)') }
    }
    if ($Spec.reviewer -eq $true -and $null -eq $Spec.probeArgs) { $errs.Add('a reviewer needs probeArgs (the gate probes it)') }

    $rules = @($Spec.probeRules)
    if ($null -eq $Spec.probeRules -or $rules.Count -eq 0) { $errs.Add('probeRules must list at least one rule') }
    else {
        foreach ($r in $rules) { foreach ($e in (Test-CliProbeRuleSpec $r)) { $errs.Add($e) } }
        # OK needs positive evidence, from exactly one rule (#770).
        $ok = @($rules | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['code'] -ceq 'OK' }).Count
        if ($ok -ne 1) { $errs.Add("probeRules must have exactly one OK rule (found $ok)") }
    }

    foreach ($k in @($Spec.keepEnv)) {
        if ($null -ne $k -and [string]$k -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errs.Add("keepEnv entry '$k' is not an environment variable name") }
    }

    if ($null -ne $Spec.routing) {
        if ($Spec.routing -isnot [System.Collections.IDictionary]) { $errs.Add('routing must be an object of route -> rank') }
        else {
            foreach ($rk in $Spec.routing.Keys) {
                if ($RouteNames -cnotcontains $rk) { $errs.Add("routing names unknown route '$rk' (routes: $($RouteNames -join ', '))") }
                $rv = $Spec.routing[$rk]
                if (-not ($rv -is [int] -or $rv -is [long]) -or $rv -le 0) { $errs.Add("routing rank for '$rk' must be a positive integer") }
            }
        }
    }

    if ($null -ne $Spec.launch) {
        $l = $Spec.launch
        if ($l -isnot [System.Collections.IDictionary]) { $errs.Add('launch must be an object { args, stdinNull }') }
        else {
            foreach ($lk in $l.Keys) { if (@('args', 'stdinNull') -cnotcontains $lk) { $errs.Add("launch has unknown key '$lk'") } }
            $la = @($l.args)
            if ($null -eq $l.args -or ($la | Where-Object { $_ -isnot [string] -or $_ -match "[\r\n\0]" }).Count -gt 0) {
                $errs.Add('launch.args must be a list of single-line strings')
            }
            if ($l.Contains('stdinNull') -and $l.stdinNull -isnot [bool]) { $errs.Add('launch.stdinNull must be true or false') }
        }
    } elseif (-not $script:CliBuiltinLaunchers.ContainsKey($name)) {
        $errs.Add('launch is required (only claude has a built-in launch)')
    }
    $errs.ToArray()
}

# Field defaults for an adapter an override ADDS (the preset states every field explicitly).
function New-CliAdapterSpecDefaults([string]$Name) {
    @{ name = $Name; isDefault = $false; installArgs = $null; installUrl = $null; bypassArgs = '';
       requiresBypass = $false; keepEnv = @(); routing = @{}; reviewer = $false; launch = $null }
}

# Read the three tiers and merge them. Returns { Routes; Common; Adapters (ordered name -> spec);
# Sources (name -> tier) }. Pure filesystem IO; warnings for rejected overrides.
function Import-CliAdapterRegistry {
    [CmdletBinding()]
    param([string]$PresetPath, [string]$UserPath, [string]$RepoPath)
    $preset = Read-CliAdapterFile -Path $PresetPath -Required
    if ([int]$preset.version -ne $script:CliAdapterSchemaVersion) {
        throw "adapters: the shipped preset declares version '$($preset.version)'; this build understands $($script:CliAdapterSchemaVersion) - broken install."
    }
    $routes     = @($preset.routes)
    $routeNames = @($routes | ForEach-Object { [string]$_.name })
    foreach ($r in @($preset.commonProbeRules)) {
        $e = @(Test-CliProbeRuleSpec $r)
        if ($e.Count) { throw "adapters: the shipped preset's commonProbeRules are invalid ($($e -join '; '))." }
    }
    $adapters = [ordered]@{}
    $sources  = @{}
    foreach ($a in @($preset.adapters)) {
        $e = @(Test-CliAdapterSpec -Spec $a -RouteNames $routeNames)
        if ($e.Count) { throw "adapters: the shipped adapter '$($a.name)' is invalid ($($e -join '; ')) - broken install." }
        $adapters[$a.name] = $a
        $sources[$a.name]  = 'preset'
    }

    foreach ($tier in @(@{ Name = 'user'; Path = $UserPath }, @{ Name = 'repo'; Path = $RepoPath })) {
        $doc = Read-CliAdapterFile -Path $tier.Path
        if (-not $doc) { continue }
        $v = if ($doc.ContainsKey('version')) { $doc.version } else { 0 }
        if ($v -ne $script:CliAdapterSchemaVersion) {
            Write-Warning "adapters: '$($tier.Path)' declares version '$v'; this build understands version $($script:CliAdapterSchemaVersion) - ignoring the file."
            continue
        }
        # Routes and the shared probe rules are the factory's vocabulary: an override adds and
        # tunes adapters, it does not redefine what the tiers mean.
        foreach ($k in @($doc.Keys | Where-Object { $_ -notin 'version', 'adapters' })) {
            Write-Warning "adapters: '$($tier.Path)' sets '$k', which only presets/adapters.json may define - ignored."
        }
        foreach ($o in @($doc.adapters)) {
            if ($o -isnot [System.Collections.IDictionary] -or -not $o.name) {
                Write-Warning "adapters: '$($tier.Path)' has an adapter without a 'name' - skipped."
                continue
            }
            $name = [string]$o.name
            # The repo tier travels with a CLONE: a third-party repository must not get code
            # execution on this machine (a new command or probe argv runs on the next fleet probe)
            # nor widen keepEnv to hand secrets to a launched agent. So it may only re-rank routing
            # and toggle reviewer on adapters that already exist; the user tier (the machine
            # owner's own file) keeps full power (#772).
            if ($tier.Name -eq 'repo' -and -not $adapters.Contains($name)) {
                Write-Warning "adapters: '$($tier.Path)' adds adapter '$name' - rejected: a project file may not add a CLI (it would run a program on this machine). Add it in your user file instead."
                continue
            }
            $candidate = if ($adapters.Contains($name)) { @{} + $adapters[$name] } else { New-CliAdapterSpecDefaults $name }
            foreach ($k in $o.Keys) {
                if ($script:CliAdapterFields -cnotcontains $k) {
                    Write-Warning "adapters: '$($tier.Path)' adapter '$name' has unknown field '$k' - ignored."
                    continue
                }
                if ($tier.Name -eq 'repo' -and $script:CliAdapterRepoFields -cnotcontains $k) {
                    Write-Warning "adapters: '$($tier.Path)' adapter '$name' sets '$k' - rejected: a project file may only set routing and reviewer (a clone must not change what runs on this machine). Field ignored."
                    continue
                }
                $candidate[$k] = $o[$k]
            }
            $e = @(Test-CliAdapterSpec -Spec $candidate -RouteNames $routeNames)
            # #773: low-trust is sticky - an override may tighten an adapter, never un-sandbox one.
            if ($adapters.Contains($name) -and $adapters[$name].lowTrust -eq $true -and $candidate.lowTrust -ne $true) {
                $e += "it clears lowTrust on '$name', which an earlier tier marked low-trust (#773)"
            }
            if ($e.Count) {
                $kept = if ($adapters.Contains($name)) { "keeping the $($sources[$name]) definition" } else { 'it is not added' }
                Write-Warning "adapters: '$($tier.Path)' adapter '$name' rejected - $($e -join '; '). $kept."
                continue
            }
            $adapters[$name] = $candidate
            $sources[$name]  = $tier.Name
        }
    }
    [pscustomobject]@{ Routes = $routes; Common = @($preset.commonProbeRules); Adapters = $adapters; Sources = $sources }
}

# The merged registry, cached. The cache key holds every tier's path, size and write time, so an
# edited override is picked up on the next call while a probe loop does not re-read three files.
function Get-CliAdapterRegistry {
    [CmdletBinding()]
    param([string]$PresetPath, [string]$UserPath, [string]$RepoPath)
    if (-not $PSBoundParameters.ContainsKey('PresetPath') -or -not $PresetPath) { $PresetPath = Get-CliAdapterPresetPath }
    if (-not $PSBoundParameters.ContainsKey('UserPath')) { $UserPath = Get-CliAdapterUserPath }
    if (-not $PSBoundParameters.ContainsKey('RepoPath')) { $RepoPath = Get-CliAdapterRepoPath }
    $key = (@($PresetPath, $UserPath, $RepoPath) | ForEach-Object {
        $f = if ($_) { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        if ($f -and -not $f.PSIsContainer) { "$_|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" } else { "$_|-" }
    }) -join '?'
    if ($script:CliAdapterCache -and $script:CliAdapterCache.Key -ceq $key) { return $script:CliAdapterCache.Registry }
    $reg = Import-CliAdapterRegistry -PresetPath $PresetPath -UserPath $UserPath -RepoPath $RepoPath
    $script:CliAdapterCache = @{ Key = $key; Registry = $reg }
    $reg
}

# The shared failure phrases (presets/adapters.json commonProbeRules) as rule objects. An adapter
# places them in its own ProbeRules with { "include": "common" }, where they belong in ITS order.
function Get-CliCommonProbeRules {
    foreach ($r in @((Get-CliAdapterRegistry).Common)) { New-CliProbeRule $r.code $r.pattern $r.reason }
}

# Expand an adapter's rule list (splicing in the common rules) into rule objects. Pure.
function ConvertTo-CliProbeRules([object[]]$Rules, [object[]]$Common) {
    foreach ($r in @($Rules)) {
        if ($r.Contains('include')) { foreach ($c in @($Common)) { New-CliProbeRule $c.code $c.pattern $c.reason } }
        else { New-CliProbeRule $r.code $r.pattern $r.reason }
    }
}

# A string as the content of a PowerShell single-quoted literal. CodeGeneration doubles every
# single-quote character PowerShell honours (including the typographic ones), so an O'Brien-style
# path or a stray quote in a template cannot close the literal.
function ConvertTo-CliQuotedLiteral([string]$Text) {
    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

# Render a template launch (registry `launch`) into the launch-script line. Pure.
#   args              each argument, in order, after the command
#   {briefingContent} as a WHOLE argument: the briefing file's text, read at run time
#   {briefingFile}    inside an argument: the briefing path (the argument is then quoted)
#   stdinNull         pipe $null in, for CLIs that read stdin even with a prompt argument
# Safety: the command and the bypass flags are validated to bare tokens on load; an argument is
# written bare only when it is a plain token (no PowerShell metacharacter can be in it), else as a
# single-quoted literal with its quotes doubled - so no registry string reaches the script as code.
function Format-CliTemplateLaunch {
    param([hashtable]$Ctx, [string]$SpecJson)
    $spec  = $SpecJson | ConvertFrom-Json -AsHashtable
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($spec.command)
    foreach ($a in @($spec.args)) {
        if ($a -ceq '{briefingContent}') {
            $parts.Add('(Get-Content -Raw -LiteralPath {0})' -f (ConvertTo-CliQuotedLiteral $Ctx.BriefingFile))
            continue
        }
        $v = $a.Replace('{briefingFile}', [string]$Ctx.BriefingFile)
        # {workPath} (#773): the worktree, for a CLI that runs in a container and mounts it. It lands
        # inside a docker --mount spec, where ',' separates options - a path holding one (or a quote
        # or a line break) could smuggle in another mount option, so it fails closed.
        if ($v.Contains('{workPath}')) {
            $wp = [string]$Ctx.WorkPath
            if (-not $wp -or $wp -match '[,"\r\n\0]') { throw "launch: the worktree path '$wp' cannot be passed to a container mount (empty, or holds , `" or a line break)." }
            $v = $v.Replace('{workPath}', $wp)
        }
        if ($v -cmatch '^-{0,2}[A-Za-z0-9][A-Za-z0-9_.:=/-]*$') { $parts.Add($v) } else { $parts.Add((ConvertTo-CliQuotedLiteral $v)) }
    }
    $line = $parts -join ' '
    if ($Ctx.AllowBypass -and $spec.bypassArgs) { $line += ' ' + $spec.bypassArgs }
    if ($spec.stdinNull) { $line = '$null | ' + $line }
    $line
}

# Build the per-worktree claude launch script. $ctx carries at least BriefingFile + AuthVar. This
# is the SAME construction Build-WorktreeLaunch used inline before the adapter refactor - kept
# byte-identical on purpose (see the O'Brien single-quote escaping + the -join "`r`n" below).
function Build-ClaudeLaunch {
    param([hashtable]$Ctx, [string]$BypassArgs)
    # Double any single quote so a briefing path containing ' (valid on Windows, e.g. an
    # O'Brien user folder) can't break out of the single-quoted literal it is embedded in
    # inside the generated launch script (the Get-Content -LiteralPath '...' arg below).
    $safeBrief  = $Ctx.BriefingFile -replace "'", "''"
    # Each step on its OWN line (a .ps1 file), so no ';' is ever needed - which is the
    # whole point: ';' on wt's command line would split the tab (see the header note).
    # The chosen credential is captured FIRST - the Windows user scope, else the process
    # (#767: there is no user scope off Windows) - then every competing one is cleared,
    # then it is set. One step per line; no value ever reaches the script text.
    $getAuth    = '$abiosAuth=[Environment]::GetEnvironmentVariable(''{0}'',''User'')' -f $Ctx.AuthVar
    $getAuth2   = 'if (-not $abiosAuth) {{ $abiosAuth=[Environment]::GetEnvironmentVariable(''{0}'') }}' -f $Ctx.AuthVar
    $clearAuth  = 'Remove-Item Env:ANTHROPIC_API_KEY,Env:ANTHROPIC_AUTH_TOKEN,Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue'
    $setAuth    = '$env:{0}=$abiosAuth' -f $Ctx.AuthVar
    $clean      = 'Remove-Item Env:CLAUDECODE,Env:CLAUDE_CODE_SESSION_ID,Env:CLAUDE_CODE_CHILD_SESSION,Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue'
    # Permission bypass is an explicit opt-in (#761): appended only when the launch context
    # carries AllowBypass (Board-Work -AllowPermissionBypass).
    $bypass     = if ($Ctx.AllowBypass -and $BypassArgs) { ' ' + $BypassArgs } else { '' }
    $run        = 'claude -p (Get-Content -Raw -LiteralPath ''{0}''){1} --no-session-persistence --verbose' -f $safeBrief, $bypass
    ($getAuth, $getAuth2, $clearAuth, $setAuth, $clean, $run) -join "`r`n"
}

# The registry as adapter objects. Probe and BuildLaunch stay scriptblocks invoked with & (the
# callers' contract), generated here with every registry value embedded as a quoted literal -
# not closures: a GetNewClosure() block is bound to a module whose parent is the GLOBAL scope, so
# it could not see Invoke-CliProbe when this file is dot-sourced into a script or a test.
function Get-CliAdapters {
    [CmdletBinding()]
    param([string]$PresetPath, [string]$UserPath, [string]$RepoPath)
    # Only the three paths are passed on (not common parameters such as -WarningVariable).
    $paths = @{}
    foreach ($k in 'PresetPath', 'UserPath', 'RepoPath') { if ($PSBoundParameters.ContainsKey($k)) { $paths[$k] = $PSBoundParameters[$k] } }
    $reg = Get-CliAdapterRegistry @paths
    foreach ($name in $reg.Adapters.Keys) {
        $s = $reg.Adapters[$name]
        $bypass = if ($s.bypassArgs) { [string]$s.bypassArgs } else { '' }
        $probe = if ($null -eq $s.probeArgs) {
            # The host CLI: it is running this very script, so it is available by construction.
            { param($ctx) 'OK' }
        } else {
            $argv = (@($s.probeArgs) | ForEach-Object { ConvertTo-CliQuotedLiteral $_ }) -join ', '
            [scriptblock]::Create("param(`$ctx) Invoke-CliProbe @($argv) -Cli $(ConvertTo-CliQuotedLiteral $name)")
        }
        $build = if ($null -ne $s.launch) {
            $json = [ordered]@{ command = $s.command; args = @($s.launch.args); stdinNull = [bool]$s.launch.stdinNull; bypassArgs = $bypass } | ConvertTo-Json -Compress -Depth 4
            [scriptblock]::Create("param(`$ctx) Format-CliTemplateLaunch -Ctx `$ctx -SpecJson $(ConvertTo-CliQuotedLiteral $json)")
        } else {
            [scriptblock]::Create("param(`$ctx) $($script:CliBuiltinLaunchers[$name]) -Ctx `$ctx -BypassArgs $(ConvertTo-CliQuotedLiteral $bypass)")
        }
        $routing = @{}
        if ($s.routing) { foreach ($rk in $s.routing.Keys) { $routing[$rk] = [int]$s.routing[$rk] } }
        [PSCustomObject]@{
            Name           = $name
            Command        = [string]$s.command
            Kind           = [string]$s.kind
            IsDefault      = [bool]$s.isDefault
            InstallArgs    = $(if ($null -ne $s.installArgs) { [string[]]@($s.installArgs) } else { $null })
            InstallUrl     = $s.installUrl
            ProbeArgs      = $(if ($null -ne $s.probeArgs) { [string[]]@($s.probeArgs) } else { $null })
            Probe          = $probe
            ProbeRules     = @(ConvertTo-CliProbeRules -Rules @($s.probeRules) -Common $reg.Common)
            BypassArgs     = $bypass
            RequiresBypass = [bool]$s.requiresBypass
            LowTrust       = ($s.lowTrust -eq $true)
            # Credentials this CLI may read from the environment, kept by the secret scrub (#769).
            # claude's own is the -ClaudeAuthVar, which Build-WorktreeLaunch always keeps.
            KeepEnv        = @($s.keepEnv | Where-Object { $_ })
            BuildLaunch    = $build
            Routing        = $routing
            Reviewer       = [bool]$s.reviewer
            Source         = $reg.Sources[$name]
        }
    }
}

# --- Routing (#772): Fleet-Plan's "which CLI suits this issue", derived from the registry. -----
# presets/adapters.json lists ROUTES in order (criteria: labels / types / sizes; a route with no
# criteria matches everything), and each adapter ranks the routes it suits in `routing` (lower
# rank = preferred). Adding a backend that should take docs work is one JSON entry.

# The first route an issue matches. Labels and type compare case-insensitively, size upper-case.
function Select-CliRoute {
    param([object]$Issue, [object[]]$Routes)
    if (-not $PSBoundParameters.ContainsKey('Routes')) { $Routes = @((Get-CliAdapterRegistry).Routes) }
    $labels = @($Issue.labels | ForEach-Object { "$_".ToLower() })
    $type   = "$($Issue.type)".ToLower()
    $size   = "$($Issue.size)".ToUpper()
    foreach ($r in @($Routes)) {
        # Filter out $null: a route without 'labels' would otherwise count @($null) as one criterion.
        $rl = @($r.labels | Where-Object { $_ }); $rt = @($r.types | Where-Object { $_ }); $rs = @($r.sizes | Where-Object { $_ })
        if (($rl.Count + $rt.Count + $rs.Count) -eq 0) { return [string]$r.name }
        if (@($rl | Where-Object { $labels -contains "$_".ToLower() }).Count) { return [string]$r.name }
        if ($type -and @($rt | Where-Object { "$_".ToLower() -eq $type }).Count) { return [string]$r.name }
        if ($size -and @($rs | Where-Object { "$_".ToUpper() -eq $size }).Count) { return [string]$r.name }
    }
    return $null
}

# May a low-trust adapter (#773) work an issue of a repo with this visibility? Only PUBLIC, compared
# case-sensitively after the caller normalises it (GraphQL already says 'PUBLIC'): private,
# internal, empty or anything unrecognised is NO - unknown fails closed. Any other adapter: yes. Pure.
function Test-CliLowTrustAllowed([object]$Adapter, [AllowNull()][AllowEmptyString()][string]$Visibility) {
    if (-not $Adapter.LowTrust) { return $true }
    return ("$Visibility".Trim().ToUpperInvariant() -ceq 'PUBLIC')
}

# The adapters that suit a route, best first (rank, then name for a stable tie-break). -Visibility
# is the issue repo's visibility; without it (unknown) a low-trust adapter is never offered (#773).
function Get-CliRoutePreference {
    param([string]$Route, [object[]]$Adapters, [string]$Visibility = '')
    if (-not $PSBoundParameters.ContainsKey('Adapters')) { $Adapters = @(Get-CliAdapters) }
    if (-not $Route) { return @() }
    @($Adapters | Where-Object { $_.Routing -and $_.Routing.ContainsKey($Route) -and (Test-CliLowTrustAllowed $_ $Visibility) } |
        Sort-Object @{ Expression = { $_.Routing[$Route] } }, Name | ForEach-Object Name)
}

# The visibility of owner/repo as PUBLIC / PRIVATE / INTERNAL, or $null when it cannot be read (no
# gh, no access, a bad name) - and $null keeps a low-trust adapter away (#773). Impure (gh).
function Get-CliRepoVisibility([string]$Repo) {
    if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return $null }
    try {
        # Through Invoke-Gh (#303, RawGh lint): a bare gh turns a 401 into an empty answer. Here a
        # failure throws, and the catch turns it into $null - which keeps a low-trust adapter away.
        if (-not (Get-Command Invoke-Gh -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Invoke-Gh.ps1') }
        $v = ((Invoke-Gh -GhArgs @('api', "repos/$Repo", '--jq', '.visibility') -What "read the visibility of $Repo") | Out-String).Trim()
        if (-not $v) { return $null }
        return $v.ToUpperInvariant()
    } catch { return $null }
}

# Why a low-trust adapter may NOT work this issue, or $null when it may (#773). The planner already
# routes it only to Docs/Chore issues of public repos, but the launch has other doors - the fleet's
# interactive picker, an explicit per-issue choice, a relaunch - so this is checked again at launch,
# on the issue's own facts { labels; type; size; visibility }:
#   * the route the issue takes (Select-CliRoute, the planner's own rule) must be docs or chore;
#   * the repo visibility must be PUBLIC.
# No facts, or a fact that is missing, is a refusal: unknown fails closed. -Routes overrides the
# registry routes for tests. Pure.
function Get-CliLowTrustRefusal {
    param([object]$Adapter, [object]$Facts, [object[]]$Routes)
    if (-not $Adapter.LowTrust) { return $null }
    if ($null -eq $Facts) { return "the issue's route and repository visibility are unknown" }
    $routeArgs = @{ Issue = $Facts }
    if ($PSBoundParameters.ContainsKey('Routes')) { $routeArgs.Routes = $Routes }
    $route = Select-CliRoute @routeArgs
    if ($script:CliLowTrustRoutes -cnotcontains $route) {
        $shown = if ($route) { $route } else { 'none' }
        return "the issue takes the '$shown' route, and $($Adapter.Name) works only $($script:CliLowTrustRoutes -join '/') issues"
    }
    if (-not (Test-CliLowTrustAllowed $Adapter "$($Facts.visibility)")) {
        $v = if ("$($Facts.visibility)".Trim()) { "$($Facts.visibility)".Trim().ToUpperInvariant() } else { 'unknown' }
        return "the repository visibility is $v, and $($Adapter.Name) works only PUBLIC repositories"
    }
    return $null
}

# Launch-time guard (#773): the CLI to launch for a chosen one, and the one-line warning when a
# low-trust choice is refused and degraded to claude (the same fallback as an unavailable CLI).
# Returns { Cli; Warning } - Warning is $null when nothing changed. Pure.
function Resolve-CliLowTrustLaunch {
    param([string]$Chosen, [object[]]$Adapters, [object]$Facts, [int]$IssueNum = 0, [object[]]$Routes)
    $a = @($Adapters | Where-Object Name -ceq $Chosen | Select-Object -First 1)
    $refArgs = @{ Facts = $Facts }
    if ($PSBoundParameters.ContainsKey('Routes')) { $refArgs.Routes = $Routes }
    $why = if ($a.Count) { Get-CliLowTrustRefusal -Adapter $a[0] @refArgs } else { $null }
    if (-not $why) { return [pscustomobject]@{ Cli = $Chosen; Warning = $null } }
    $who = if ($IssueNum) { "#${IssueNum}: " } else { '' }
    [pscustomobject]@{ Cli = 'claude'; Warning = "${who}not launching $Chosen - $why. Launching claude instead (#773)." }
}


# Shared probe runner: run the adapter's probe command, capture exit code + output, and
# classify it with THAT adapter's ProbeRules (-Cli names it; #770). Each adapter's Probe
# scriptblock calls this with its own argument list. Kept separate so Test-CliAvailability
# can be tested with a mock Probe.
# Runs the command in a background job with a timeout so a slow/hung CLI (e.g.
# codex exec waiting on stdin) can never block the fleet launch indefinitely - a timeout is
# ERROR, never a guess.
function Invoke-CliProbe([string[]]$CommandLine, [int]$TimeoutSec = 30, [string]$Cli) {
    $exe  = $CommandLine[0]
    $rest = @($CommandLine[1..($CommandLine.Count-1)])
    $j = Start-Job { param($e,$a) $o = & $e @a 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o } } -ArgumentList $exe, $rest
    if (Wait-Job $j -Timeout $TimeoutSec) {
        $r = Receive-Job $j; Remove-Job $j -Force
        return ConvertTo-CliProbeCode -Cli $Cli -ExitCode $r.Exit -Output $r.Out
    }
    Stop-Job $j; Remove-Job $j -Force
    return 'ERROR'
}

# Availability = installed on PATH AND (for repl CLIs) a live probe. Returns
# { Cli, Status, Detail }. Status is a probe code (Get-CliProbeCodes), or NOT_INSTALLED when
# the probe never ran. Whatever the Probe returns is pinned to the closed set (#770): a probe
# that answers anything else - including an old lower-case 'ok' - is ERROR.
function Test-CliAvailability {
    param([Parameter(Mandatory)][object]$Adapter)
    if (-not (Get-Command $Adapter.Command -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Cli=$Adapter.Name; Status='NOT_INSTALLED'; Detail="$($Adapter.Command) is not on PATH" }
    }
    $status = Confirm-CliProbeCode (& $Adapter.Probe $null)
    return [PSCustomObject]@{ Cli=$Adapter.Name; Status=$status; Detail='' }
}

# A CLI that cannot work unattended without its permission bypass (RequiresBypass) is
# reported NEEDS_BYPASS unless the human opted in with -AllowPermissionBypass (#761), so
# the picker never offers it and Resolve-LaunchCli degrades its issue to claude. Pure.
function Resolve-BypassAvailability([object]$Adapter, [string]$Status, [bool]$AllowBypass) {
    if ($Status -ceq 'OK' -and $Adapter.RequiresBypass -and -not $AllowBypass) { return 'NEEDS_BYPASS' }
    return $Status
}

# One visible line stating the permission mode the launched sessions will run under (#761).
# Returns the text so it can be asserted; prints it in red when the bypass is on.
function Write-PermissionModeNotice([bool]$AllowBypass) {
    if ($AllowBypass) {
        $msg = "  WARNING: -AllowPermissionBypass - launched sessions run with each CLI's permission BYPASS flag: they can edit files and run commands without asking. Only the PreToolUse brake still applies."
        Write-Host $msg -ForegroundColor Red
    } else {
        $msg = "  Permissions: each session uses its CLI's own permission mode and your allow-list (a headless session is denied, not asked, for anything outside it). Opt in to the bypass with -AllowPermissionBypass."
        Write-Host $msg -ForegroundColor DarkGray
    }
    return $msg
}

# The v1 safety net: an unavailable chosen CLI silently degrades to claude (the
# always-present default), never aborting the batch. Pure -> unit-testable.
function Resolve-LaunchCli([string]$Chosen, [hashtable]$Availability) {
    if ($Chosen -and $Availability[$Chosen] -ceq 'OK') { return $Chosen }
    return 'claude'
}

# Pure core of the picker: given issues + raw choices + live availability, resolve each
# issue to an available CLI (Resolve-LaunchCli enforces fallback). Unit-testable.
function Resolve-IssueCliMap([int[]]$Issues, [hashtable]$Choices, [hashtable]$Availability) {
    $map = @{}
    foreach ($i in $Issues) {
        $chosen = if ($Choices.ContainsKey($i)) { $Choices[$i] } else { 'claude' }
        $map[$i] = Resolve-LaunchCli -Chosen $chosen -Availability $Availability
    }
    return $map
}

# Render the availability table: one colored line per CLI on the console, and the
# same plain line emitted to the pipeline so callers (and tests, via Out-String) can
# capture the rendered text. Green OK / yellow otherwise.
function Show-CliAvailability([hashtable]$Availability) {
    foreach ($cli in ($Availability.Keys | Sort-Object)) {
        $st = $Availability[$cli]
        $color = if ($st -ceq 'OK') { 'Green' } else { 'DarkYellow' }
        $line = "  {0,-11} {1}" -f $cli, $st
        Write-Host $line -ForegroundColor $color
        $line
    }
}

# The install command as text, for display. Pure.
function Get-CliInstallText([object]$Adapter) {
    if ($Adapter.InstallArgs) { return (@($Adapter.InstallArgs) -join ' ') }
    if ($Adapter.InstallUrl)  { return "see $($Adapter.InstallUrl)" }
    return ''
}

# Install a not-installed CLI after explicit user approval, then re-probe. Impure.
# Runs a PINNED argv (#765), never a string through Invoke-Expression; a CLI with no pinnable
# package (InstallArgs = $null) is never installed by the tool - the user gets the page instead.
function Install-CliOnApproval([object]$Adapter) {
    if (-not $Adapter.InstallArgs) {
        Write-Host ("  {0} is not installed. Install it yourself: {1}" -f $Adapter.Name, $Adapter.InstallUrl) -ForegroundColor Yellow
        return $false
    }
    Write-Host ("  {0} is not installed. Command: {1}" -f $Adapter.Name, (Get-CliInstallText $Adapter)) -ForegroundColor Yellow
    $ans = Read-Host "  Install now? (y/N)"
    if ($ans -notmatch '^[sSyY]') { Write-Host "  Skipped." -ForegroundColor DarkGray; return $false }
    $argv = @($Adapter.InstallArgs)
    & $argv[0] @($argv | Select-Object -Skip 1)
    return ($LASTEXITCODE -eq 0)
}

# Interactive per-issue picker: prints availability, prompts a CLI per issue, then
# resolves through the pure core. Returns the issue->cli map.
function Select-CliPerIssue([int[]]$Issues, [hashtable]$Availability) {
    Show-CliAvailability $Availability | Out-Null
    $available = @($Availability.Keys | Where-Object { $Availability[$_] -ceq 'OK' })
    $choices = @{}
    foreach ($i in $Issues) {
        $ans = Read-Host ("  Which assistant works issue #{0}? [{1}] (Enter = claude)" -f $i, ($available -join '/'))
        if ($ans) { $choices[$i] = $ans.Trim().ToLower() }
    }
    return Resolve-IssueCliMap -Issues $Issues -Choices $choices -Availability $Availability
}

# Pair each started worktree with the CLI the picker resolved for it. Pure.
function Build-FleetPlan([object[]]$Started, [hashtable]$CliMap) {
    foreach ($r in $Started) {
        $cli = if ($CliMap.ContainsKey($r.issue)) { $CliMap[$r.issue] } else { 'claude' }
        # facts (#773): the issue's route + visibility facts and its text, which the launch needs to
        # judge a low-trust CLI and to brief one that has no gh. $null when the start did not record them.
        $facts = if ($r.PSObject.Properties['facts']) { $r.facts } else { $null }
        [PSCustomObject]@{ issue=$r.issue; repo=$r.repo; branch=$r.branch; workPath=$r.workPath; cli=$cli; facts=$facts }
    }
}
