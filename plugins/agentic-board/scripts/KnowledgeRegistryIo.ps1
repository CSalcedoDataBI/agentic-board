<#  KnowledgeRegistryIo.ps1 — read/write the knowledge registry as JSON *or* YAML (#298).

    `/knowledge` versions its registry in `knowledge/registry.json`. A repo whose pre-commit hook uses
    an allow-list (only code: .py .md .toml .yaml …) blocks a `.json` file — often ON PURPOSE, because
    OAuth `credentials.json` / `token.json` are `.json`, so the barrier that protects secrets also
    shuts the registry out of exactly the sensitive-data repos that most want a reference catalog.
    The registry adapts, not the barrier: it can now live as `registry.yaml`, which the typical
    allow-list already passes.

    PowerShell 5.1/7 has no built-in YAML, and depending on a module would break downstream users who
    do not have it. So this emits a CONSTRAINED YAML for the registry's own flat, tool-controlled
    schema, and — crucially — escapes/serialises every string scalar through the built-in JSON cmdlets:
    ConvertTo-Json of a single string yields a double-quoted token that is ALSO a valid YAML
    double-quoted scalar, and ConvertFrom-Json reads it straight back. No hand-rolled escaping, no
    fragile general-YAML parser — only the shape this file writes is ever parsed.

    Pure at load: dot-source it, it defines functions only.
      . (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')

    Schema:
      version:    <int>
      project:    "<string>"
      domains:    [ "<string>", ... ]
      references: [ { id; domain; type; title; ref; note; added }, ... ]
#>

# Emit one scalar the way both JSON and YAML accept it: an int stays bare, everything else is a
# JSON string token (== a YAML double-quoted scalar). $null becomes "".
function ConvertTo-KnowledgeYamlScalar($value) {
    if ($null -eq $value) { return '""' }
    if ($value -is [int] -or $value -is [long] -or $value -is [double]) { return "$value" }
    if ($value -is [bool]) { return ($value ? 'true' : 'false') }
    return ([string]$value | ConvertTo-Json -Compress)   # -> "escaped", valid in both formats
}

# Read a scalar token back: a leading quote (or a JSON-ish literal) round-trips through ConvertFrom-Json;
# anything else is a bare string. Reverses ConvertTo-KnowledgeYamlScalar.
function ConvertFrom-KnowledgeYamlScalar([string]$token) {
    $t = $token.Trim()
    if ($t -eq '') { return '' }
    if ($t.StartsWith('"')) { return ($t | ConvertFrom-Json) }
    if ($t -match '^-?\d+$') { return [int]$t }
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    return $t
}

# Serialise the registry object to the constrained YAML above.
function ConvertTo-KnowledgeYaml($reg) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# knowledge registry (YAML) - allow-list-friendly source of truth for /knowledge (#298).")
    [void]$sb.AppendLine("# Generated + rewritten by the tool; edit here, then let /knowledge regenerate KNOWLEDGE.md.")
    [void]$sb.AppendLine("version: $(ConvertTo-KnowledgeYamlScalar $reg.version)")
    [void]$sb.AppendLine("project: $(ConvertTo-KnowledgeYamlScalar $reg.project)")
    [void]$sb.AppendLine("domains:")
    foreach ($d in @($reg.domains)) { [void]$sb.AppendLine("  - $(ConvertTo-KnowledgeYamlScalar $d)") }
    [void]$sb.AppendLine("references:")
    foreach ($r in @($reg.references)) {
        $props = @($r.PSObject.Properties)
        $first = $true
        foreach ($p in $props) {
            $prefix = if ($first) { "  - " } else { "    " }
            [void]$sb.AppendLine("$prefix$($p.Name): $(ConvertTo-KnowledgeYamlScalar $p.Value)")
            $first = $false
        }
        if ($first) { [void]$sb.AppendLine("  - {}") }   # a reference with no properties (shouldn't happen)
    }
    return $sb.ToString().TrimEnd() + "`n"
}

# Parse the constrained YAML back into the registry object. Only the shape ConvertTo-KnowledgeYaml
# writes is supported (two-space list indent, four-space map keys); comments and blank lines ignored.
function ConvertFrom-KnowledgeYaml([string]$text) {
    $version = 1; $project = ''; $domains = @(); $references = @()
    $section = ''          # '', 'domains', 'references'
    $cur = $null           # the reference being built
    foreach ($rawLine in ($text -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ($line -eq '' -or $line.TrimStart().StartsWith('#')) { continue }

        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            # A top-level key.
            $k = $Matches[1]; $v = $Matches[2]
            if ($cur) { $references += $cur; $cur = $null }
            switch ($k) {
                'version'    { $version = ConvertFrom-KnowledgeYamlScalar $v; $section = '' }
                'project'    { $project = ConvertFrom-KnowledgeYamlScalar $v; $section = '' }
                'domains'    { $section = 'domains' }
                'references' { $section = 'references' }
                default      { $section = '' }
            }
            continue
        }
        if ($section -eq 'domains' -and $line -match '^\s*-\s*(.+)$') {
            $domains += ConvertFrom-KnowledgeYamlScalar $Matches[1]
            continue
        }
        if ($section -eq 'references') {
            # `  - key: value` starts a new record; `    key: value` continues it.
            if ($line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
                if ($cur) { $references += $cur }
                $cur = [ordered]@{}
                $cur[$Matches[1]] = ConvertFrom-KnowledgeYamlScalar $Matches[2]
            } elseif ($cur -and $line -match '^\s+([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
                $cur[$Matches[1]] = ConvertFrom-KnowledgeYamlScalar $Matches[2]
            }
            continue
        }
    }
    if ($cur) { $references += $cur }
    return [pscustomobject]@{
        version    = $version
        project    = $project
        domains    = @($domains)
        references = @($references | ForEach-Object { [pscustomobject]$_ })
    }
}

# Resolve the registry path under $Root. Prefers an EXISTING registry.yaml, else registry.json; a new
# registry defaults to .json (no behavior change) unless -Format yaml is asked for. Callers that want
# the allow-list-friendly file pass -Format yaml at init.
function Resolve-KnowledgeRegistryPath {
    param([Parameter(Mandatory)][string]$Root, [ValidateSet('', 'json', 'yaml')][string]$Format = '')
    $dir  = Join-Path $Root 'knowledge'
    $yaml = Join-Path $dir 'registry.yaml'
    $json = Join-Path $dir 'registry.json'
    if ($Format -eq 'yaml') { return $yaml }
    if ($Format -eq 'json') { return $json }
    if (Test-Path -LiteralPath $yaml) { return $yaml }
    if (Test-Path -LiteralPath $json) { return $json }
    return $json
}

# Read a registry file, dispatching on extension. Fails the same way the old inline read did.
function Read-KnowledgeRegistry {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($Path -match '\.ya?ml$') { return ConvertFrom-KnowledgeYaml $raw }
    return ($raw | ConvertFrom-Json)
}

# Write a registry object, dispatching on extension. Always UTF-8, matching the old inline write.
function Write-KnowledgeRegistry {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$Path)
    if ($Path -match '\.ya?ml$') { $out = ConvertTo-KnowledgeYaml $Registry }
    else                         { $out = $Registry | ConvertTo-Json -Depth 8 }
    Set-Content -LiteralPath $Path -Value $out -Encoding utf8
}
