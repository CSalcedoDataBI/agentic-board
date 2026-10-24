<#  Get-BoardConfig.ps1 - the SINGLE reader/writer of the per-repo preference file.

    Dot-source it (never invoke it): `. (Join-Path $PSScriptRoot 'Get-BoardConfig.ps1')`

    Why this exists (#662). Preferences about HOW to work a board - today: whether several
    related issues should share one PR - lived only in the operator's head, so every session
    started from the tool's default and the user had to restate the preference. A preference
    that has to be repeated is not a preference; it is a chore. This file is where a repo
    records the answer once.

    It is deliberately NOT the state dir's other files. `sessions.json` and `active-run.json`
    are live per-machine state and are gitignored; `config.json` is a per-REPO decision that
    belongs to everyone who clones it, so it is un-ignored alongside `roles.json` and travels
    with the repo.

    Failure posture: a missing file is not an error - it means "no decision recorded", which is
    a real and common answer. A CORRUPT file is different: it is a decision the tool cannot read,
    and silently substituting the default would be the tool answering a question the user already
    answered. Read-BoardConfig reports it (`.ok = $false`, `.error` set) and the caller says so
    out loud instead of pretending the repo has no preference.

    Pure at load: defines functions only - no filesystem access, no output.  #>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# Every recognised key, with the value that applies when the repo has recorded no decision.
# $null is a real, distinct value here - see Resolve-GroupingPosture: "not decided" is not the
# same answer as "decided: no", and collapsing them is how the tool would lose the user's "no".
function Get-BoardConfigDefaults {
    @{
        preferGroupedPRs = $null
        mergeAuthority   = $null
    }
}

# Is this parsed JSON an OBJECT, as opposed to a scalar or an array?
#
# `$x -is [pscustomobject]` cannot answer that: PowerShell wraps EVERY value in a PSObject, so a
# bare JSON string passes it. Reading past that check then enumerates the STRING's own properties
# - `Length` - which is how a config file that said `"just a string"` came back out of the writer
# as `{"Length": 13, ...}`. The base type is what actually distinguishes them.
#
# It lives here, once, because the reader and the writer both need it and having each carry its
# own copy is exactly how one of them kept the bug after the other was fixed.
function Test-IsJsonObject {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $false }
    $base = if ($Value -is [psobject]) { $Value.PSObject.BaseObject } else { $Value }
    $base -is [System.Management.Automation.PSCustomObject]
}

function Get-BoardConfigPath {
    [CmdletBinding()]
    param([string]$Root)

    $dir = if ($Root) { Get-AbiosStateDir -Root $Root -NoCreate } else { Get-AbiosStateDir -NoCreate }
    if (-not $dir) { return $null }
    Join-Path $dir 'config.json'
}

# Reads the file into a plain hashtable over the defaults.
# Returns: @{ ok = <bool>; config = <hashtable>; error = <string>; path = <string>; exists = <bool> }
function Read-BoardConfig {
    [CmdletBinding()]
    param([string]$Path)

    $cfg = Get-BoardConfigDefaults

    if (-not $Path) {
        return [pscustomobject]@{ ok = $true; config = $cfg; error = ''; path = ''; exists = $false }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ ok = $true; config = $cfg; error = ''; path = $Path; exists = $false }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = "could not be read: $($_.Exception.Message)"; path = $Path; exists = $true }
    }

    # An empty file is a half-written file, not an empty decision - treat it as unreadable.
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'the file is empty'; path = $Path; exists = $true }
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'not valid JSON'; path = $Path; exists = $true }
    }

    if (-not (Test-IsJsonObject $parsed)) {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'the content is not a JSON object'; path = $Path; exists = $true }
    }

    foreach ($key in @($cfg.Keys)) {
        $prop = $parsed.PSObject.Properties[$key]
        if ($prop) { $cfg[$key] = $prop.Value }
    }

    [pscustomobject]@{ ok = $true; config = $cfg; error = ''; path = $Path; exists = $true }
}

# Writes ONE key, preserving every other key already in the file - including keys this version
# does not recognise. A newer version of the tool (or a hand-added note) must survive a write
# from an older one; a whole-file rewrite from the defaults would silently delete it.
function Set-BoardConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        $Value
    )

    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            # Only an OBJECT has keys worth preserving. A scalar or an array is not a config file
            # we can merge into - and enumerating one would drag its own .NET properties in as
            # keys, which is worse than dropping it.
            if (Test-IsJsonObject $existing) {
                foreach ($prop in $existing.PSObject.Properties) { $obj[$prop.Name] = $prop.Value }
            }
        } catch {
            # Unreadable existing file: start clean rather than refuse. The alternative is a repo
            # that can never record a preference again because of one bad byte.
            $obj = [ordered]@{}
        }
    }

    $obj[$Key] = $Value

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}

# The posture that decides how `work` talks about PRs. Three answers, not two:
#   'always'  - the repo asked for one PR per batch; group without asking for evidence.
#   'never'   - the repo asked for one PR per issue; never propose grouping.
#   'auto'    - no decision recorded: propose grouping only where there is EVIDENCE the
#               issues overlap. This is the default, and it is what #662 changes - the old
#               default proposed nothing and left one-PR-per-issue as the silent posture.
#
# -ExpertDeclared (#797): a repo whose merges are decided by its own expert has already said what
# shape its PRs take - one per group of related issues - so when nothing is recorded (or what is
# recorded cannot be read), the default it falls back to is 'always', not 'auto'. A recorded
# answer, including a hand-written "auto", still wins: the declaration is a default, not an override.
function Resolve-GroupingPosture {
    [CmdletBinding()]
    param($Config, [switch]$ExpertDeclared)

    $fallback = if ($ExpertDeclared) { 'always' } else { 'auto' }
    if ($null -eq $Config) { return $fallback }
    $v = $Config['preferGroupedPRs']
    if ($null -eq $v) { return $fallback }
    if ($v -is [string]) {
        switch ($v.Trim().ToLowerInvariant()) {
            'true'  { return 'always' }
            'false' { return 'never' }
            'auto'  { return 'auto' }
            default { return $fallback }
        }
    }
    # Only a real boolean is a decision here. `[bool]` on anything else is truthiness (0 -> a silent
    # 'never', 42 -> 'always', an object -> 'always'): a hand edit the tool cannot read must fall
    # back to the default like the unreadable strings above, not be read as an answer.
    if ($v -is [bool]) { if ($v) { return 'always' } else { return 'never' } }
    return $fallback
}

# What a user sees and types for the grouped-PR setting, and WHERE its value came from (#681).
# `posture` (always/never/auto) is the internal decision; the setting is what
# `-PreferGroupedPRs on|off|auto` accepts, so the menu and every proposal can name the same word the
# user would type to change it. `source` says whether the repo recorded an answer ('config': a
# non-null preferGroupedPRs in .agentic-board/config.json) or nothing was decided and the tool's
# default applies ('default'). A recorded `auto` is stored as null, so "auto" from the default and
# "auto" chosen on purpose are the same to the tool and are reported as 'default'.
#
# With -ExpertDeclared and nothing recorded, the source is 'expert': the value in force came from
# the repo's merge-authority declaration, which is neither the tool's default nor a grouping answer.
function Get-GroupingSetting {
    [CmdletBinding()]
    param($Config, [switch]$ExpertDeclared)

    $posture  = Resolve-GroupingPosture $Config -ExpertDeclared:$ExpertDeclared
    # 'config' only when the stored value is one Resolve-GroupingPosture actually understands.
    # A garbage value (a hand edit: 42, "maybe", an object) falls back to auto INSIDE the resolver,
    # so calling it "config del repo" would report a decision the repo never made - intent stated as
    # fact. The value in force is the default, and the source says so.
    $recorded = $false
    if ($null -ne $Config -and $null -ne $Config['preferGroupedPRs']) {
        $v = $Config['preferGroupedPRs']
        $recorded = ($v -is [bool]) -or
                    (($v -is [string]) -and (@('true', 'false', 'auto') -contains $v.Trim().ToLowerInvariant()))
    }
    [pscustomobject]@{
        value   = switch ($posture) { 'always' { 'on' } 'never' { 'off' } default { 'auto' } }
        posture = $posture
        source  = $(if ($recorded) { 'config' } elseif ($ExpertDeclared) { 'expert' } else { 'default' })
    }
}

# Who decides the merge at /board work step 5d/5e (#797). Two answers:
#   'user'   - today's flow: a merge-confirmation summary, then the user says yes. The default.
#   'expert' - the repo declares an expert agent that reviews the whole PR with clean context and
#              merges without asking when its conditions hold, or PROPOSES to the user when not.
#
# Deterministic, from files only - no network, no model judgement:
#   1. `mergeAuthority` in .agentic-board/config.json: 'user' is an explicit opt-out and always
#      wins; 'expert' declares it outright.
#   2. Otherwise the repo declares it by its files: a `FICHA.md` at the root carrying an
#      `Aprobada: YYYY-MM-DD` line (the owner's approval of the plan) AND `.claude/agents/experto.md`.
#      A FICHA with no approval line is a draft: a plan the owner has not signed cannot hand
#      anyone the right to merge against it.
#   3. Either way the expert agent file must exist. A declaration with no expert to run is reported
#      (`warning`) and falls back to 'user' - merging on a declaration nobody can carry out would be
#      the tool answering for an expert that is not there.
#   4. It fails CLOSED. Merging is irreversible, so anything the tool cannot read - an unrecognised
#      `mergeAuthority` value (`false`, "none", a typo: most likely an attempted opt-out), or a
#      config.json that exists but cannot be parsed (-ConfigUnreadable) - resolves to 'user' with a
#      warning, never to "let the files decide". The grouping preference can fall back to a default;
#      the right to merge without asking cannot.
#   5. -GitRef (what Board-Work passes: the default branch) reads the declaration as COMMITTED there,
#      not from the checkout. At step 5d the checkout IS the PR under review, and a PR that adds an
#      approved FICHA.md, loosens experto.md or writes "mergeAuthority": "expert" must not be judged
#      by its own rules. So an 'expert' grant counts only from that ref, while an opt-out (or
#      anything unreadable) counts from ANYWHERE - the local -Config included - because it can only
#      make the flow ask more. A ref that does not resolve is unreadable: 'user'.
#      Without -GitRef the files are read from -Root on disk (the unit tests' mode).
function Read-DeclarationFile {
    param([string]$Root, [string]$GitRef, [string]$RelPath)
    if (-not $Root) { return $null }
    if ($GitRef) {
        $text = git -C $Root show "${GitRef}:$RelPath" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($text) -join "`n")
    }
    $p = Join-Path $Root $RelPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $p -Raw -ErrorAction Stop } catch { '' }
}

# 'user' / 'expert' / 'unreadable' / $null (nothing declared) for one config source.
function Get-MergeAuthorityDeclaration {
    param($Config)
    if ($null -eq $Config -or $null -eq $Config['mergeAuthority']) { return $null }
    $v = $Config['mergeAuthority']
    $norm = if ($v -is [string]) { $v.Trim().ToLowerInvariant() } else { '' }
    switch ($norm) {
        'user'   { return 'user' }
        'expert' { return 'expert' }
        default  { return 'unreadable' }
    }
}

function Get-MergeAuthority {
    [CmdletBinding()]
    param($Config, [string]$Root, [switch]$ConfigUnreadable, [string]$GitRef)

    $agentRel = '.claude/agents/experto.md'
    $res = [ordered]@{
        authority = 'user'; source = 'default'; reason = 'the repo declares no expert'
        expertAgent = ''; ficha = ''; fichaApproved = ''; warning = ''; ref = $GitRef
    }
    $where = if ($GitRef) { " on $GitRef" } else { '' }

    # Opt-outs first, from every source: each can only make the flow ask more.
    if ($ConfigUnreadable) {
        $res.source = 'config'; $res.reason = 'the repo config cannot be read'
        $res.warning = '.agentic-board/config.json exists but cannot be read, so it may hold an opt-out; the user confirms'
        return [pscustomobject]$res
    }
    $local = Get-MergeAuthorityDeclaration $Config
    $base  = $null
    if ($GitRef) {
        if (-not $Root -or -not (git -C $Root rev-parse --verify --quiet "${GitRef}^{commit}" 2>$null)) {
            $res.reason = 'the default branch cannot be read'
            $res.warning = "could not read '$GitRef' to check the committed declaration; the user confirms"
            return [pscustomobject]$res
        }
        $rawCfg = Read-DeclarationFile -Root $Root -GitRef $GitRef -RelPath '.agentic-board/config.json'
        if ($null -ne $rawCfg) {
            $parsed = try { $rawCfg | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            if (-not (Test-IsJsonObject $parsed)) {
                $base = 'unreadable'
            } else {
                $prop = $parsed.PSObject.Properties['mergeAuthority']
                $base = Get-MergeAuthorityDeclaration @{ mergeAuthority = $(if ($prop) { $prop.Value } else { $null }) }
            }
        }
    }
    foreach ($d in @($local, $base)) {
        if ($d -eq 'unreadable') {
            $res.source = 'config'; $res.reason = 'the repo config holds a merge authority the tool cannot read'
            $res.warning = "mergeAuthority in .agentic-board/config.json is not 'expert' or 'user'$where; the user confirms"
            return [pscustomobject]$res
        }
        if ($d -eq 'user') {
            $res.source = 'config'; $res.reason = 'the repo config says the user confirms every merge'
            return [pscustomobject]$res
        }
    }

    $agentText = Read-DeclarationFile -Root $Root -GitRef $GitRef -RelPath $agentRel
    if ($null -ne $agentText) { $res.expertAgent = $agentRel }
    $fichaText = Read-DeclarationFile -Root $Root -GitRef $GitRef -RelPath 'FICHA.md'
    if ($null -ne $fichaText) {
        $res.ficha = 'FICHA.md'
        # (?!\d), not \b: `_Aprobada: 2026-10-02_` puts a word character right after the date.
        $m = [regex]::Match([string]$fichaText, '(?im)^[\s>*_-]*Aprobada\s*[:*_]*\s*[*_]*\s*(\d{4}-\d{2}-\d{2})(?!\d)')
        if ($m.Success) { $res.fichaApproved = $m.Groups[1].Value }
    }

    # The grant: from the ref when there is one, else from the local config.
    $grant = if ($GitRef) { $base } else { $local }
    if ($grant -eq 'expert') {
        $res.source = 'config'
        if ($res.expertAgent) {
            $res.authority = 'expert'
            $res.reason = "the repo config declares an expert ($agentRel)$where"
        } else {
            $res.warning = "the repo config declares an expert, but $agentRel does not exist$where; the user confirms"
            $res.reason = 'declared expert is missing'
        }
        return [pscustomobject]$res
    }
    if ($local -eq 'expert' -and $GitRef) {
        $res.warning = "mergeAuthority 'expert' is only in the local config; it counts once it is committed to $GitRef"
    }

    if ($res.ficha -and $res.fichaApproved -and $res.expertAgent) {
        $res.authority = 'expert'; $res.source = 'files'
        $res.reason = "FICHA.md approved $($res.fichaApproved) + $agentRel$where"
    } elseif ($res.ficha -and $res.expertAgent -and -not $res.warning) {
        $res.warning = "FICHA.md has no 'Aprobada: YYYY-MM-DD' line$where, so it is a draft; the user confirms"
    }
    [pscustomobject]$res
}

# One line for the menu and for `-MergeAuthority show`.
function Format-MergeAuthorityLabel {
    param($Authority)
    $where = switch ($Authority.source) { 'config' { 'repo config' } 'files' { 'FICHA.md + expert' } default { 'default' } }
    "$($Authority.authority) ($where)"
}
