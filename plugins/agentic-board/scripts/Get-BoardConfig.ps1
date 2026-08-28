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
    }
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
        return [pscustomobject]@{ ok = $false; config = $cfg; error = "no se pudo leer: $($_.Exception.Message)"; path = $Path; exists = $true }
    }

    # An empty file is a half-written file, not an empty decision - treat it as unreadable.
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'el archivo esta vacio'; path = $Path; exists = $true }
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'no es JSON valido'; path = $Path; exists = $true }
    }

    # `-is [pscustomobject]` is useless here: PowerShell wraps EVERY value in a PSObject, so a bare
    # JSON string passes it. The base type is the one that actually distinguishes an object from a
    # scalar or an array - a test caught this returning "ok" for `"just a string"`.
    $base = if ($null -ne $parsed -and $parsed -is [psobject]) { $parsed.PSObject.BaseObject } else { $parsed }
    if ($base -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ ok = $false; config = $cfg; error = 'el contenido no es un objeto JSON'; path = $Path; exists = $true }
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
            if ($existing -is [pscustomobject]) {
                foreach ($p in $existing.PSObject.Properties) { $obj[$p.Name] = $p.Value }
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
function Resolve-GroupingPosture {
    [CmdletBinding()]
    param($Config)

    if ($null -eq $Config) { return 'auto' }
    $v = $Config['preferGroupedPRs']
    if ($null -eq $v) { return 'auto' }
    if ($v -is [string]) {
        switch ($v.Trim().ToLowerInvariant()) {
            'true'  { return 'always' }
            'false' { return 'never' }
            'auto'  { return 'auto' }
            default { return 'auto' }
        }
    }
    if ([bool]$v) { 'always' } else { 'never' }
}
