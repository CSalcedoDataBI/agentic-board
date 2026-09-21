<#
.SYNOPSIS
    Read-only audit of a repository's GitHub Actions cost configuration: what it MEASURABLY costs
    and where its workflow files break the cost rules (#614). Writes nothing, anywhere.

.DESCRIPTION
    Two halves, and the report keeps them apart on purpose.

    1. MEASURED COST. Minutes per SKU and per day come from the account usage endpoint
       (`users/<owner>/settings/billing/usage`, or `organizations/<org>/...`), and nothing else.
       Two traps are encoded here, because either one silently produces a wrong cost report:
         - `/actions/runs/<id>/timing` is NOT used. It returned `total_ms: 0` for every run tried
           (failed, cancelled and successful, public and private).
         - Run wall-clock (created_at -> updated_at) is NOT a cost. It includes queue time: during
           the 2026-08-06 Actions incident runs showed 15 minutes of wall clock and recorded zero
           executed steps. Anything this audit calls a cost is a number the usage endpoint reported.
       The quota-weighted figure is the one derived number: measured minutes x the documented
       multiplier (Linux 1, Windows 2, macOS 10), labelled as derived. SKUs it does not know
       (larger runners) are listed and NOT weighted.

    2. RULES over `.github/workflows/*.yml`. Every finding names a file and a line and quotes that
       line. There is no YAML module on a stock machine, so a small YAML-subset parser lives in
       this file; anything it cannot read (anchors, tags, exotic syntax) makes THAT FILE
       "not measured" - never a silent pass. The rules:
         R1  the same job on pull_request AND push (paying twice for one verdict)
         R2  no concurrency + cancel-in-progress: true (release/deploy: it must be false)
         R3  a job with no timeout-minutes (the default is 360)
         R4  a pull_request workflow with no paths / paths-ignore  [advice; see the deadlock trap]
         R5  windows (x2) or macos (x10) runners on a branch push
         R6  upload-artifact without retention-days; setup-* without a cache
         R7  crons that fire more than once a week
         R8  a private repo: an OBSERVATION with the measured minutes, never an action
         FAN the same install step repeated across the jobs one event starts
         TRAP a required status check on a workflow that is path-filtered (the PR parks at
              "Expected - waiting for status" forever)
       Runners per PR and the duplicated setup are read from the files.

    NOTHING IS "OK" BY OMISSION. Every rule reports how many things it evaluated, how many
    findings it made and how many it could not measure, and the "not measured" list carries the
    reason (endpoint refused, expression it cannot evaluate, file it cannot parse).

    Default source is the repo's default branch on GitHub (what actually bills); -Local audits the
    working tree instead (a workflow change you have not pushed yet).

.PARAMETER Repo
    owner/name. Defaults to the `origin` remote of the current repo.
.PARAMETER Month
    yyyy-MM to read the usage for. Default: the current UTC month.
.PARAMETER Local
    Read `.github/workflows` from -Path instead of the default branch on GitHub.
.PARAMETER Path
    Working tree for -Local (default: the current directory).
.PARAMETER Branch
    Branch to read workflows from and to check the required checks of (default: the default branch).
.PARAMETER Top
    How many of the account's biggest repos to list in the account view (default 5).
.PARAMETER Json
    Emit the whole report as JSON.
.PARAMETER TokenVar
    Windows USER env var holding the PAT. Empty (default): decided by the identity resolver.

.EXAMPLE
    .\Get-ActionsCostAudit.ps1                         # this repo, default branch, current month
    .\Get-ActionsCostAudit.ps1 -Local                  # audit the working tree
    .\Get-ActionsCostAudit.ps1 -Repo o/r -Month 2026-08 -Json
#>
[CmdletBinding()]
param(
    [string]$Repo     = '',
    [string]$Month    = '',
    [switch]$Local,
    [string]$Path     = '.',
    [string]$Branch   = '',
    [int]   $Top      = 5,
    [switch]$Json,
    [string]$TokenVar = ''
)

$ErrorActionPreference = 'Stop'

# The fail-closed gh wrapper (#303) and the single owner/name resolver (#281). No raw `gh` here:
# RawGh.Lint.Tests.ps1 counts them, and a bare gh turns a 401 into an empty result.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# ============================================================================================
# YAML subset parser
# ============================================================================================
# Workflow files are block-style YAML with a few flow collections. This reads exactly that and
# THROWS on anything else (anchors, aliases, tags, tabs, multiple documents, multi-line quoted
# scalars), so a file it cannot vouch for is reported "not measured" instead of half-audited.
# Every node carries its 1-based source line: that is what makes a finding traceable.

function New-YNode {
    param([string]$Kind, [int]$Line)
    $n = [pscustomobject]@{ Kind = $Kind; Line = $Line; Value = $null; Quoted = $false
                            Keys = $null; Map = $null; KeyLine = $null; Items = $null }
    if ($Kind -eq 'map') {
        $n.Keys    = [System.Collections.Generic.List[string]]::new()
        $n.Map     = New-Object System.Collections.Hashtable      # case-SENSITIVE, like YAML
        $n.KeyLine = New-Object System.Collections.Hashtable
    }
    if ($Kind -eq 'seq') { $n.Items = [System.Collections.Generic.List[object]]::new() }
    return $n
}

function New-YScalar {
    param([string]$Value, [int]$Line, [bool]$Quoted = $false)
    $n = New-YNode 'scalar' $Line
    $n.Value = $Value
    $n.Quoted = $Quoted
    return $n
}

# Cut a trailing comment. A quote only OPENS a quoted scalar where a value can start (after
# `:`, `-`, `[`, `{`, `,` or at the line start); inside a plain scalar it is just a character, which
# is how YAML itself reads `run: echo "a #b"` (the ` #` starts a comment).
function Remove-YamlComment {
    param([string]$Text)
    $inS = $false; $inD = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inS) {
            if ($c -eq "'") { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++ } else { $inS = $false } }
            continue
        }
        if ($inD) {
            if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inD = $false }
            continue
        }
        if ($c -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($Text[$i - 1]))) { return $Text.Substring(0, $i) }
        if ($c -eq "'" -or $c -eq '"') {
            $j = $i - 1
            while ($j -ge 0 -and [char]::IsWhiteSpace($Text[$j])) { $j-- }
            $opens = ($j -lt 0) -or (':-[{,'.IndexOf($Text[$j]) -ge 0)
            if ($opens) { if ($c -eq "'") { $inS = $true } else { $inD = $true } }
        }
    }
    return $Text
}

# Bracket depth of the flow collection that starts the VALUE of this line (0 when there is none).
function Get-YamlFlowDepth {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?:^|:\s+|-\s+)([\[{].*)$')
    if (-not $m.Success) { return 0 }
    $s = $m.Groups[1].Value
    $depth = 0; $inS = $false; $inD = $false
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($inS) { if ($c -eq "'") { $inS = $false }; continue }
        if ($inD) { if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inD = $false }; continue }
        if ($c -eq "'") { $inS = $true } elseif ($c -eq '"') { $inD = $true }
        elseif ($c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}') { $depth-- }
    }
    return $depth
}

# Physical lines -> tokens { No; Indent; Text; BlockText }. Comments are cut, block scalars
# (`|` / `>`) are swallowed whole into BlockText of their header token, and a flow collection that
# spans lines is joined into one.
function Get-YamlTokens {
    param([string]$Text)
    $lines  = @($Text -split "\r?\n")
    $tokens = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        $raw = $lines[$i]; $no = $i + 1
        if ($i -eq 0 -and $raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
        $trim = $raw.Trim()
        if (-not $trim -or $trim.StartsWith('#') -or $raw -match '^%') { $i++; continue }
        if ($raw -match '^---(\s|$)') {
            if ($tokens.Count -gt 0) { throw "more than one YAML document (line $no)" }
            $i++; continue
        }
        if ($raw -match '^\.\.\.\s*$') { $i++; continue }
        if ($raw -match '^ *\t') { throw "tab used for indentation (line $no)" }

        $indent = $raw.Length - $raw.TrimStart(' ').Length
        $text   = (Remove-YamlComment $raw).TrimEnd().TrimStart(' ')

        $blockRx = '^(?:-\s+)*(?:(?:"[^"]*"|''[^'']*''|[^\s:#][^:]*?):\s+)?[|>][0-9+-]{0,2}$'
        if ($text -match $blockRx) {
            # Content must be indented past the node that owns the scalar: the key column, or the
            # dash column when the scalar sits directly under `- `.
            $col = $indent; $rest = $text; $lastDash = $indent
            while ($rest -match '^(-\s+)(.*)$') { $lastDash = $col; $col += $Matches[1].Length; $rest = $Matches[2] }
            $base = if ($rest -match '^[|>]') { $lastDash } else { $col }
            $j = $i + 1; $body = @()
            while ($j -lt $lines.Count) {
                $l = $lines[$j]
                if ($l.Trim() -eq '') { $body += ''; $j++; continue }
                $lead = $l.Length - $l.TrimStart(' ').Length
                if ($lead -gt $base) { $body += $l; $j++ } else { break }
            }
            $nonBlank = @($body | Where-Object { $_ -ne '' })
            $cut = 0
            if ($nonBlank.Count -gt 0) { $cut = ($nonBlank | ForEach-Object { $_.Length - $_.TrimStart(' ').Length } | Measure-Object -Minimum).Minimum }
            $dedented = @($body | ForEach-Object { if ($_.Length -ge $cut) { $_.Substring($cut) } else { '' } })
            # `|` keeps the line breaks; `>` FOLDS them (a run of text lines is ONE line, a blank line
            # is a break) - which is what a shell sees for `run: >`, so a folded `echo a` + `npm ci`
            # is one command, not an install step.
            if ([regex]::Match($text, '([|>])[0-9+-]{0,2}$').Groups[1].Value -eq '>') {
                $sb = [System.Text.StringBuilder]::new(); $prevText = $false
                foreach ($dl in $dedented) {
                    if ($dl -eq '') { [void]$sb.Append("`n"); $prevText = $false; continue }
                    if ($prevText) { [void]$sb.Append(' ') }
                    [void]$sb.Append($dl); $prevText = $true
                }
                $blockValue = $sb.ToString().TrimEnd()
            } else { $blockValue = ($dedented -join "`n").TrimEnd() }
            $tokens.Add([pscustomobject]@{ No = $no; Indent = $indent; Text = $text; BlockText = $blockValue })
            $i = $j
            continue
        }

        $depth = Get-YamlFlowDepth $text
        $j = $i + 1
        while ($depth -gt 0) {
            if ($j -ge $lines.Count) { throw "unterminated flow collection (line $no)" }
            $text += ' ' + (Remove-YamlComment $lines[$j]).Trim()
            $j++
            $depth = Get-YamlFlowDepth $text
        }
        $tokens.Add([pscustomobject]@{ No = $no; Indent = $indent; Text = $text; BlockText = $null })
        $i = $j
    }
    return ,$tokens
}

# "key: rest" -> @{ Key; Rest }, or $null when the text is not a mapping line.
function Split-YamlKeyValue {
    param([string]$Text)
    if ($Text -match '^-(\s|$)') { return $null }
    if ($Text.Length -eq 0 -or $Text[0] -eq '[' -or $Text[0] -eq '{') { return $null }
    if ($Text[0] -eq '"' -or $Text[0] -eq "'") {
        $q = $Text[0]; $i = 1
        while ($i -lt $Text.Length) {
            if ($q -eq '"' -and $Text[$i] -eq '\') { $i += 2; continue }
            if ($Text[$i] -eq $q) {
                if ($q -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i += 2; continue }
                break
            }
            $i++
        }
        if ($i -ge $Text.Length) { return $null }
        $key = $Text.Substring(1, $i - 1)
        $after = $Text.Substring($i + 1)
        $m = [regex]::Match($after, '^\s*:(?:\s+(.*))?$')
        if ($m.Success) { return @{ Key = $key; Rest = "$($m.Groups[1].Value)".Trim() } }
        return $null
    }
    $m = [regex]::Match($Text, '^(?<k>.+?):(?:\s+(?<v>.*)|\s*)$')
    if ($m.Success) { return @{ Key = $m.Groups['k'].Value.Trim(); Rest = "$($m.Groups['v'].Value)".Trim() } }
    return $null
}

function Read-YamlQuoted {
    param([string]$Text, [int]$Line)
    $q = $Text[0]; $sb = New-Object System.Text.StringBuilder; $i = 1; $closed = $false
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($q -eq '"' -and $c -eq '\' -and $i + 1 -lt $Text.Length) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
        if ($c -eq $q) {
            if ($q -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { [void]$sb.Append("'"); $i += 2; continue }
            $closed = $true; $i++; break
        }
        [void]$sb.Append($c); $i++
    }
    if (-not $closed) { throw "quoted scalar that does not close on its line (line $Line)" }
    return @{ Value = $sb.ToString(); Next = $i }
}

# ---- flow collections: [a, b] and {a: b} ------------------------------------------------------
function Skip-YamlWs { param($Fs) while ($Fs.I -lt $Fs.S.Length -and [char]::IsWhiteSpace($Fs.S[$Fs.I])) { $Fs.I++ } }

function Read-YamlFlowScalar {
    param($Fs, [int]$Line, [bool]$IsKey)
    Skip-YamlWs $Fs
    if ($Fs.I -ge $Fs.S.Length) { throw "truncated flow collection (line $Line)" }
    $c = $Fs.S[$Fs.I]
    if ($c -eq '"' -or $c -eq "'") {
        $q = Read-YamlQuoted $Fs.S.Substring($Fs.I) $Line
        $Fs.I += $q.Next
        return (New-YScalar $q.Value $Line $true)
    }
    $start = $Fs.I
    while ($Fs.I -lt $Fs.S.Length) {
        $ch = $Fs.S[$Fs.I]
        if ($ch -eq ',' -or $ch -eq ']' -or $ch -eq '}') { break }
        if ($IsKey -and $ch -eq ':' -and ($Fs.I + 1 -ge $Fs.S.Length -or [char]::IsWhiteSpace($Fs.S[$Fs.I + 1]) -or ',}'.IndexOf($Fs.S[$Fs.I + 1]) -ge 0)) { break }
        $Fs.I++
    }
    return (New-YScalar $Fs.S.Substring($start, $Fs.I - $start).Trim() $Line $false)
}

function Read-YamlFlowValue {
    param($Fs, [int]$Line)
    Skip-YamlWs $Fs
    if ($Fs.I -ge $Fs.S.Length) { throw "truncated flow collection (line $Line)" }
    $c = $Fs.S[$Fs.I]
    if ($c -eq '[') {
        $node = New-YNode 'seq' $Line; $Fs.I++
        while ($true) {
            Skip-YamlWs $Fs
            if ($Fs.I -ge $Fs.S.Length) { throw "unterminated flow sequence (line $Line)" }
            if ($Fs.S[$Fs.I] -eq ']') { $Fs.I++; break }
            $node.Items.Add((Read-YamlFlowValue $Fs $Line))
            Skip-YamlWs $Fs
            if ($Fs.I -ge $Fs.S.Length) { throw "unterminated flow sequence (line $Line)" }
            if ($Fs.S[$Fs.I] -eq ',') { $Fs.I++; continue }
            if ($Fs.S[$Fs.I] -eq ']') { $Fs.I++; break }
            throw "unexpected character in flow sequence (line $Line)"
        }
        return $node
    }
    if ($c -eq '{') {
        $node = New-YNode 'map' $Line; $Fs.I++
        while ($true) {
            Skip-YamlWs $Fs
            if ($Fs.I -ge $Fs.S.Length) { throw "unterminated flow mapping (line $Line)" }
            if ($Fs.S[$Fs.I] -eq '}') { $Fs.I++; break }
            $k = (Read-YamlFlowScalar $Fs $Line $true).Value
            Skip-YamlWs $Fs
            if ($Fs.I -lt $Fs.S.Length -and $Fs.S[$Fs.I] -eq ':') {
                $Fs.I++
                $v = Read-YamlFlowValue $Fs $Line
            } else { $v = New-YNode 'null' $Line }
            if ($node.Map.ContainsKey($k)) { throw "duplicate key '$k' (line $Line)" }
            $node.Keys.Add($k); $node.KeyLine[$k] = $Line; $node.Map[$k] = $v
            Skip-YamlWs $Fs
            if ($Fs.I -ge $Fs.S.Length) { throw "unterminated flow mapping (line $Line)" }
            if ($Fs.S[$Fs.I] -eq ',') { $Fs.I++; continue }
            if ($Fs.S[$Fs.I] -eq '}') { $Fs.I++; break }
            throw "unexpected character in flow mapping (line $Line)"
        }
        return $node
    }
    return (Read-YamlFlowScalar $Fs $Line $false)
}

function ConvertFrom-YamlFlow {
    param([string]$Text, [int]$Line)
    $fs = @{ S = $Text; I = 0 }
    $n = Read-YamlFlowValue $fs $Line
    Skip-YamlWs $fs
    if ($fs.I -lt $fs.S.Length) { throw "text after a flow collection (line $Line)" }
    return $n
}

# ---- block structure --------------------------------------------------------------------------
# The value that sits on the token's own line. Consumes the token.
function Read-YamlInline {
    param($St, [string]$Rest, $Token, [int]$ParentIndent)
    $line = $Token.No
    $St.P++
    if ($Rest -match '^[|>]') { return (New-YScalar "$($Token.BlockText)" $line $false) }
    if ($Rest -match '^[&*!]') { throw "YAML anchors, aliases and tags are not supported (line $line)" }
    if ($Rest.StartsWith('[') -or $Rest.StartsWith('{')) { return (ConvertFrom-YamlFlow $Rest $line) }
    if ($Rest.StartsWith('"') -or $Rest.StartsWith("'")) {
        $q = Read-YamlQuoted $Rest $line
        if ($Rest.Substring($q.Next).Trim()) { throw "text after a quoted scalar (line $line)" }
        return (New-YScalar $q.Value $line $true)
    }
    $v = $Rest
    while ($St.P -lt $St.T.Count -and $St.T[$St.P].Indent -gt $ParentIndent) {
        $v += ' ' + $St.T[$St.P].Text
        $St.P++
    }
    return (New-YScalar $v $line $false)
}

function Read-YamlBlock {
    param($St, [int]$ParentIndent)
    $t = $St.T[$St.P]
    if ($t.Text -match '^-(\s|$)') { return (Read-YamlSeq $St $t.Indent) }
    if ($null -ne (Split-YamlKeyValue $t.Text)) { return (Read-YamlMap $St $t.Indent) }
    return (Read-YamlInline $St $t.Text $t $ParentIndent)
}

function Read-YamlMap {
    param($St, [int]$Indent)
    $node = New-YNode 'map' $St.T[$St.P].No
    while ($St.P -lt $St.T.Count) {
        $t = $St.T[$St.P]
        if ($t.Indent -lt $Indent) { break }
        if ($t.Indent -gt $Indent) { throw "unexpected indentation (line $($t.No))" }
        $kv = Split-YamlKeyValue $t.Text
        if ($null -eq $kv) {
            if ($t.Text -match '^-(\s|$)') { break }     # a sibling sequence at the same column
            throw "line is not a 'key: value' pair (line $($t.No))"
        }
        $key = $kv.Key
        if ($node.Map.ContainsKey($key)) { throw "duplicate key '$key' (line $($t.No))" }
        $node.Keys.Add($key); $node.KeyLine[$key] = $t.No
        if ($kv.Rest -eq '') {
            $St.P++
            $child = $null
            if ($St.P -lt $St.T.Count) {
                $nx = $St.T[$St.P]
                if ($nx.Indent -gt $Indent) { $child = Read-YamlBlock $St $Indent }
                elseif ($nx.Indent -eq $Indent -and $nx.Text -match '^-(\s|$)') { $child = Read-YamlSeq $St $Indent }
            }
            if ($null -eq $child) { $child = New-YNode 'null' $t.No }
            $node.Map[$key] = $child
        } else {
            $node.Map[$key] = Read-YamlInline $St $kv.Rest $t $Indent
        }
    }
    return $node
}

function Read-YamlSeq {
    param($St, [int]$Indent)
    $node = New-YNode 'seq' $St.T[$St.P].No
    while ($St.P -lt $St.T.Count) {
        $t = $St.T[$St.P]
        if ($t.Indent -lt $Indent) { break }
        if ($t.Indent -gt $Indent) { throw "unexpected indentation (line $($t.No))" }
        if ($t.Text -notmatch '^-(\s|$)') { break }
        $after   = $t.Text.Substring(1)
        $trimmed = $after.TrimStart(' ')
        $col     = $Indent + 1 + ($after.Length - $trimmed.Length)
        if ($trimmed -eq '') {
            $St.P++
            $child = $null
            if ($St.P -lt $St.T.Count -and $St.T[$St.P].Indent -gt $Indent) { $child = Read-YamlBlock $St $Indent }
            if ($null -eq $child) { $child = New-YNode 'null' $t.No }
            $node.Items.Add($child)
        } else {
            # `- key: v` / `- - x` / `- scalar`: the rest of the line is a node that starts at
            # column $col, so re-enter with the token rewritten to that column.
            $St.T[$St.P] = [pscustomobject]@{ No = $t.No; Indent = $col; Text = $trimmed; BlockText = $t.BlockText }
            $node.Items.Add((Read-YamlBlock $St $Indent))
        }
    }
    return $node
}

# Text -> node tree. Throws a short message on anything outside the supported subset.
function ConvertFrom-WorkflowYaml {
    param([string]$Text)
    $tokens = Get-YamlTokens $Text
    if ($tokens.Count -eq 0) { return (New-YNode 'null' 1) }
    $st = @{ T = $tokens; P = 0 }
    $root = Read-YamlBlock $st -1
    if ($st.P -lt $tokens.Count) { throw "unexpected content (line $($tokens[$st.P].No))" }
    return $root
}

# ---- node accessors ---------------------------------------------------------------------------
function Get-YChild {
    param($Node, [string]$Key)
    if ($null -ne $Node -and $Node.Kind -eq 'map' -and $Node.Map.ContainsKey($Key)) { return $Node.Map[$Key] }
    return $null
}

# Case-insensitive: Actions expressions look properties up that way (matrix.OS finds `os`).
function Get-YChildCI {
    param($Node, [string]$Key)
    if ($null -eq $Node -or $Node.Kind -ne 'map') { return $null }
    foreach ($k in $Node.Keys) { if ($k -ieq $Key) { return $Node.Map[$k] } }
    return $null
}

function Get-YText {
    param($Node)
    if ($null -ne $Node -and $Node.Kind -eq 'scalar') { return [string]$Node.Value }
    return $null
}

# scalar -> one string, sequence -> its scalar items, anything else -> nothing. ALWAYS wrap in @().
function Get-YStrings {
    param($Node)
    if ($null -eq $Node) { return @() }
    if ($Node.Kind -eq 'scalar') { return @([string]$Node.Value) }
    if ($Node.Kind -eq 'seq') { return @($Node.Items | Where-Object { $_.Kind -eq 'scalar' } | ForEach-Object { [string]$_.Value }) }
    return @()
}

# ============================================================================================
# Workflow model
# ============================================================================================

function New-Trigger {
    param([string]$EventName, [int]$Line, $Node)
    $tr = [pscustomobject]@{ Event = $EventName; Line = $Line
                             Branches = @(); BranchesIgnore = @(); Tags = @(); TagsIgnore = @()
                             Paths = @(); PathsIgnore = @(); Crons = @() }
    if ($null -ne $Node -and $Node.Kind -eq 'map') {
        $tr.Branches       = @(Get-YStrings (Get-YChild $Node 'branches'))
        $tr.BranchesIgnore = @(Get-YStrings (Get-YChild $Node 'branches-ignore'))
        $tr.Tags           = @(Get-YStrings (Get-YChild $Node 'tags'))
        $tr.TagsIgnore     = @(Get-YStrings (Get-YChild $Node 'tags-ignore'))
        $tr.Paths          = @(Get-YStrings (Get-YChild $Node 'paths'))
        $tr.PathsIgnore    = @(Get-YStrings (Get-YChild $Node 'paths-ignore'))
    }
    if ($EventName -eq 'schedule' -and $null -ne $Node -and $Node.Kind -eq 'seq') {
        $crons = @()
        foreach ($it in $Node.Items) {
            $c = Get-YChild $it 'cron'
            if ($null -ne $c) { $crons += [pscustomobject]@{ Expr = (Get-YText $c); Line = $c.Line } }
        }
        $tr.Crons = $crons
    }
    return $tr
}

function Get-WorkflowTriggers {
    param($Root)
    $on = Get-YChild $Root 'on'
    $list = @()
    if ($null -eq $on) { return $list }
    if ($on.Kind -eq 'scalar') { $list += (New-Trigger ([string]$on.Value) $on.Line $null) }
    elseif ($on.Kind -eq 'seq') { foreach ($it in $on.Items) { $list += (New-Trigger (Get-YText $it) $it.Line $null) } }
    elseif ($on.Kind -eq 'map') { foreach ($k in $on.Keys) { $list += (New-Trigger $k $on.KeyLine[$k] $on.Map[$k]) } }
    return $list
}

function Get-ConcurrencyInfo {
    param($Node, [int]$KeyLine = 0)
    $o = [pscustomobject]@{ Present = $false; Line = 0; Cancel = 'absent'; CancelLine = 0 }
    if ($null -eq $Node -or $Node.Kind -eq 'null') { return $o }
    # the line of the `concurrency:` key itself, not of the first entry under it
    $o.Present = $true; $o.Line = $(if ($KeyLine -gt 0) { $KeyLine } else { $Node.Line })
    if ($Node.Kind -eq 'map') {
        $c = Get-YChild $Node 'cancel-in-progress'
        if ($null -ne $c) {
            $o.CancelLine = $c.Line
            $v = "$(Get-YText $c)".Trim()
            if ($v -ieq 'true') { $o.Cancel = 'true' }
            elseif ($v -ieq 'false') { $o.Cancel = 'false' }
            else { $o.Cancel = 'expression' }
        }
    }
    return $o
}

# Values a `matrix.<key>` expression can take: the axis list plus any `include` entry that sets it.
function Get-MatrixValues {
    param($Job, [string]$Key)
    $strategy = Get-YChild $Job 'strategy'
    $matrix = Get-YChild $strategy 'matrix'
    if ($null -eq $matrix -or $matrix.Kind -ne 'map') { return $null }
    # An `exclude` can remove the very value a rule would flag; applying it exactly needs the
    # cross product, so a matrix with one is reported as not resolvable rather than guessed.
    if ($null -ne (Get-YChild $matrix 'exclude')) { return $null }
    $vals = @()
    $found = $false
    $axis = Get-YChildCI $matrix $Key
    if ($null -ne $axis -and $axis.Kind -eq 'seq') {
        $found = $true
        foreach ($it in $axis.Items) {
            if ($it.Kind -ne 'scalar' -or "$($it.Value)" -match '\$\{\{') { return $null }
            $vals += [string]$it.Value
        }
    } elseif ($null -ne $axis) { return $null }
    $inc = Get-YChild $matrix 'include'
    if ($null -ne $inc -and $inc.Kind -eq 'seq') {
        foreach ($it in $inc.Items) {
            $v = Get-YChildCI $it $Key
            if ($null -ne $v) { $found = $true; if ($v.Kind -ne 'scalar') { return $null }; $vals += [string]$v.Value }
        }
    }
    if (-not $found) { return $null }
    return @($vals | Select-Object -Unique)
}

# How many runners the strategy fans out to: the product of the axes, or $null when it cannot be
# read exactly (expressions, include / exclude).
function Get-MatrixSize {
    param($Job)
    $strategy = Get-YChild $Job 'strategy'
    $matrix = Get-YChild $strategy 'matrix'
    if ($null -eq $matrix) { return 1 }
    if ($matrix.Kind -ne 'map') { return $null }
    $size = 1
    foreach ($k in $matrix.Keys) {
        if ($k -in @('include', 'exclude')) { return $null }
        $ax = $matrix.Map[$k]
        if ($ax.Kind -ne 'seq') { return $null }
        $size *= $ax.Items.Count
    }
    return $size
}

function Get-JobRunsOn {
    param($Job)
    $ro = Get-YChild $Job 'runs-on'
    $res = [pscustomobject]@{ Labels = @(); Unresolved = $false; Line = 0 }
    if ($null -eq $ro) { return $res }
    $res.Line = $ro.Line
    $raw = @()
    if ($ro.Kind -eq 'scalar') { $raw = @([string]$ro.Value) }
    elseif ($ro.Kind -eq 'seq') { $raw = @(Get-YStrings $ro) }
    elseif ($ro.Kind -eq 'map') { $raw = @(Get-YStrings (Get-YChild $ro 'labels')) }
    foreach ($r in $raw) {
        if ($r -match '^\s*\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}\s*$') {
            $vals = Get-MatrixValues $Job $Matches[1]
            if ($null -eq $vals) { $res.Unresolved = $true } else { $res.Labels += @($vals) }
        } elseif ($r -match '\$\{\{') { $res.Unresolved = $true }
        else { $res.Labels += $r }
    }
    return $res
}

function Get-JobSteps {
    param($Job)
    $steps = Get-YChild $Job 'steps'
    $out = @()
    if ($null -eq $steps -or $steps.Kind -ne 'seq') { return $out }
    foreach ($s in $steps.Items) {
        if ($s.Kind -ne 'map') { continue }
        $with = @{}
        $w = Get-YChild $s 'with'
        if ($null -ne $w -and $w.Kind -eq 'map') { foreach ($k in $w.Keys) { $with[$k] = Get-YText $w.Map[$k] } }
        $runNode = Get-YChild $s 'run'
        $out += [pscustomobject]@{
            Line    = $s.Line
            Name    = (Get-YText (Get-YChild $s 'name'))
            Uses    = (Get-YText (Get-YChild $s 'uses'))
            UsesLine = $(if ($null -ne (Get-YChild $s 'uses')) { $s.KeyLine['uses'] } else { $s.Line })
            Run     = (Get-YText $runNode)
            RunLine = $(if ($null -ne $runNode) { $s.KeyLine['run'] } else { $s.Line })
            With    = $with
            WithLine = $(if ($null -ne (Get-YChild $s 'with')) { $s.KeyLine['with'] } else { $s.Line })
        }
    }
    return $out
}

function Get-WorkflowJobs {
    param($Root)
    $jobsNode = Get-YChild $Root 'jobs'
    $out = @()
    if ($null -eq $jobsNode -or $jobsNode.Kind -ne 'map') { return $out }
    foreach ($id in $jobsNode.Keys) {
        $j = $jobsNode.Map[$id]
        if ($j.Kind -ne 'map') { continue }
        $tm = Get-YChild $j 'timeout-minutes'
        $ifn = Get-YChild $j 'if'
        $out += [pscustomobject]@{
            Id          = $id
            Line        = $jobsNode.KeyLine[$id]
            Name        = (Get-YText (Get-YChild $j 'name'))
            Uses        = (Get-YText (Get-YChild $j 'uses'))       # a reusable-workflow call
            RunsOn      = (Get-JobRunsOn $j)
            TimeoutRaw  = (Get-YText $tm)
            TimeoutLine = $(if ($null -ne $tm) { $j.KeyLine['timeout-minutes'] } else { 0 })
            If          = (Get-YText $ifn)
            IfLine      = $(if ($null -ne $ifn) { $j.KeyLine['if'] } else { 0 })
            Concurrency = (Get-ConcurrencyInfo (Get-YChild $j 'concurrency') $(if ($j.KeyLine.ContainsKey('concurrency')) { $j.KeyLine['concurrency'] } else { 0 }))
            MatrixSize  = (Get-MatrixSize $j)
            Steps       = @(Get-JobSteps $j)
        }
    }
    return $out
}

# One workflow file -> a model. A file the parser rejects comes back Parsed = $false with the
# reason; the caller reports it as not measured.
function ConvertTo-WorkflowModel {
    param([string]$File, [string]$Text)
    $m = [pscustomobject]@{ File = $File; Name = $null; Parsed = $false; Error = $null
                            Triggers = @(); Concurrency = $null; Jobs = @(); Lines = @($Text -split "\r?\n") }
    try {
        $root = ConvertFrom-WorkflowYaml $Text
        if ($root.Kind -ne 'map') { throw 'the document is not a mapping' }
        $m.Name        = (Get-YText (Get-YChild $root 'name'))
        $m.Triggers    = @(Get-WorkflowTriggers $root)
        $m.Concurrency = Get-ConcurrencyInfo (Get-YChild $root 'concurrency') $(if ($root.KeyLine.ContainsKey('concurrency')) { $root.KeyLine['concurrency'] } else { 0 })
        $m.Jobs        = @(Get-WorkflowJobs $root)
        $m.Parsed      = $true
    } catch {
        $m.Error = $_.Exception.Message
    }
    return $m
}

# ============================================================================================
# Cron frequency
# ============================================================================================

$script:CronDow = @{ SUN = 0; MON = 1; TUE = 2; WED = 3; THU = 4; FRI = 5; SAT = 6 }
$script:CronMon = @{ JAN = 1; FEB = 2; MAR = 3; APR = 4; MAY = 5; JUN = 6; JUL = 7; AUG = 8; SEP = 9; OCT = 10; NOV = 11; DEC = 12 }

function Convert-CronValue {
    param([string]$Token, $Names)
    if ($Token -match '^\d+$') { return [int]$Token }
    if ($null -ne $Names -and $Names.ContainsKey($Token.ToUpperInvariant())) { return [int]$Names[$Token.ToUpperInvariant()] }
    return $null
}

# One cron field -> the sorted list of values it selects, or $null when it is not valid.
function Expand-CronField {
    param([string]$Field, [int]$Min, [int]$Max, $Names)
    $set = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($part in ($Field -split ',')) {
        if (-not $part) { return $null }
        $step = 1; $range = $part; $hasStep = $false
        $sm = [regex]::Match($part, '^(.*)/(\d+)$')
        if ($sm.Success) { $range = $sm.Groups[1].Value; $step = [int]$sm.Groups[2].Value; $hasStep = $true; if ($step -lt 1) { return $null } }
        $lo = $null; $hi = $null
        if ($range -eq '*') { $lo = $Min; $hi = $Max }
        else {
            $rm = [regex]::Match($range, '^([A-Za-z0-9]+)-([A-Za-z0-9]+)$')
            if ($rm.Success) {
                $lo = Convert-CronValue $rm.Groups[1].Value $Names
                $hi = Convert-CronValue $rm.Groups[2].Value $Names
            } elseif ($range -match '^[A-Za-z0-9]+$') {
                $lo = Convert-CronValue $range $Names
                $hi = $(if ($hasStep) { $Max } else { $lo })
            } else { return $null }
        }
        if ($null -eq $lo -or $null -eq $hi -or $lo -lt $Min -or $hi -gt $Max -or $lo -gt $hi) { return $null }
        for ($v = $lo; $v -le $hi; $v += $step) { [void]$set.Add($v) }
    }
    return ,@($set | Sort-Object)
}

# How often does this cron fire, on average over the year? Parsed = $false (with a Reason) when the
# expression is not one this can evaluate - that is "not measured", never "fine".
function Get-CronFrequency {
    param([string]$Expr)
    $f = @("$Expr".Trim() -split '\s+')
    if ($f.Count -ne 5) { return [pscustomobject]@{ Parsed = $false; Reason = "se esperaban 5 campos, hay $($f.Count)"; PerWeek = 0; PerDay = 0 } }
    $mi  = Expand-CronField $f[0] 0 59 $null
    $hr  = Expand-CronField $f[1] 0 23 $null
    $dom = Expand-CronField $f[2] 1 31 $null
    $mon = Expand-CronField $f[3] 1 12 $script:CronMon
    $dow = Expand-CronField $f[4] 0 7  $script:CronDow
    foreach ($x in @($mi, $hr, $dom, $mon, $dow)) {
        if ($null -eq $x) { return [pscustomobject]@{ Parsed = $false; Reason = "no es una expresion cron que esta auditoria sepa leer: '$Expr'"; PerWeek = 0; PerDay = 0 } }
    }
    $dowSet = @($dow | ForEach-Object { $_ % 7 } | Sort-Object -Unique)
    $domFrac = $dom.Count / 31.0
    $dowFrac = $dowSet.Count / 7.0
    $domR = ($dom.Count -lt 31); $dowR = ($dowSet.Count -lt 7)
    if (-not $domR -and -not $dowR) { $dayFrac = 1.0 }
    elseif ($domR -and -not $dowR)  { $dayFrac = $domFrac }
    elseif (-not $domR -and $dowR)  { $dayFrac = $dowFrac }
    else                            { $dayFrac = 1 - (1 - $domFrac) * (1 - $dowFrac) }   # cron: day-of-month OR day-of-week
    $perDay  = $mi.Count * $hr.Count
    # averaged over the YEAR: a cron that runs daily but only in January is 31 runs, fewer than weekly (52)
    $perWeek = 7 * $dayFrac * $perDay * ($mon.Count / 12.0)
    return [pscustomobject]@{ Parsed = $true; Reason = ''; PerWeek = [math]::Round($perWeek, 2); PerDay = $perDay }
}

# ============================================================================================
# Rules
# ============================================================================================

$script:RuleTitles = [ordered]@{
    'R1'   = 'el mismo job en pull_request y en push'
    'R2'   = 'concurrency con cancel-in-progress'
    'R3'   = 'timeout-minutes en cada job'
    'R4'   = 'filtro de rutas (paths / paths-ignore) en pull_request'
    'R5'   = 'runners windows / macos en push de rama'
    'R6'   = 'retention-days en artefactos y cache en setup-*'
    'R7'   = 'crons que corren mas de una vez por semana'
    'R8'   = 'repo privado (observacion)'
    'FAN'  = 'setup repetido entre los jobs que dispara un mismo evento'
    'TRAP' = 'check requerido + filtro de rutas (trampa del deadlock)'
    'PARSE' = 'workflows que esta auditoria sabe leer'
    'COST' = 'coste medido (endpoint de uso de la cuenta)'
}

$script:QuotaMultiplier = @{ 'Actions Linux' = 1; 'Actions Windows' = 2; 'Actions macOS' = 10 }

function New-AuditContext {
    [pscustomobject]@{
        Findings   = ([System.Collections.Generic.List[object]]::new())
        Unmeasured = ([System.Collections.Generic.List[object]]::new())
        Ledger     = @{}
    }
}

function Get-LedgerRow {
    param($Ctx, [string]$Rule)
    if (-not $Ctx.Ledger.ContainsKey($Rule)) { $Ctx.Ledger[$Rule] = @{ Evaluated = 0; Findings = 0; NotMeasured = 0 } }
    return $Ctx.Ledger[$Rule]
}

function Add-Eval {
    param($Ctx, [string]$Rule, [int]$Count = 1)
    (Get-LedgerRow $Ctx $Rule).Evaluated += $Count
}

function Add-Finding {
    param($Ctx, [string]$Rule, [string]$Severity, [string]$File, [int]$Line, [string]$Message, $Evidence = @(), $Model = $null)
    $snippet = ''
    if ($null -ne $Model -and $Line -gt 0 -and $Line -le $Model.Lines.Count) {
        $snippet = $Model.Lines[$Line - 1].Trim()
        if ($snippet.Length -gt 140) { $snippet = $snippet.Substring(0, 140) + '...' }
    }
    (Get-LedgerRow $Ctx $Rule).Findings += 1
    $Ctx.Findings.Add([pscustomobject]@{
        Rule = $Rule; Severity = $Severity; File = $File; Line = $Line
        Message = $Message; Snippet = $snippet; Evidence = @($Evidence) })
}

function Add-Unmeasured {
    param($Ctx, [string]$Rule, [string]$File, [int]$Line, [string]$Reason)
    (Get-LedgerRow $Ctx $Rule).NotMeasured += 1
    $Ctx.Unmeasured.Add([pscustomobject]@{ Rule = $Rule; File = $File; Line = $Line; Reason = $Reason })
}

# Does a branch filter admit $Branch?  $true / $false, or $null when the pattern is one this does
# not evaluate (negations, character classes, ?, +) - the caller reports that as not measured.
function Test-GlobMatch {
    param([string]$Pattern, [string]$Value)
    if ($Pattern.StartsWith('!') -or $Pattern -match '[\[\]?+]') { return $null }
    $rx = '^' + (([regex]::Escape($Pattern) -replace '\\\*\\\*', '.*') -replace '\\\*', '[^/]*') + '$'
    return [bool]($Value -match $rx)
}

function Test-BranchFilter {
    param([string[]]$Include, [string[]]$Ignore, [string]$Branch)
    $ok = $true
    if (@($Include).Count -gt 0) {
        $ok = $false
        foreach ($p in @($Include)) {
            $m = Test-GlobMatch $p $Branch
            if ($null -eq $m) { return $null }
            if ($m) { $ok = $true }
        }
    }
    foreach ($p in @($Ignore)) {
        $m = Test-GlobMatch $p $Branch
        if ($null -eq $m) { return $null }
        if ($m) { return $false }
    }
    return $ok
}

function Get-Trigger {
    param($Model, [string[]]$Names)
    foreach ($t in $Model.Triggers) { if ($Names -contains $t.Event) { return $t } }
    return $null
}

# A push trigger that only fires for tags is not a branch push.
function Test-PushIsTagsOnly {
    param($Push)
    return (@($Push.Branches).Count -eq 0 -and @($Push.BranchesIgnore).Count -eq 0 -and @($Push.Tags).Count -gt 0)
}

function Test-ReleaseLike {
    param($Model)
    $label = "$($Model.File) $($Model.Name)"
    return [bool]($label -match '(?i)release|deploy|publish')
}

$script:InstallPattern = '^(npm\s+(ci|install|i)\b|yarn(\s+install)?\s*$|pnpm\s+(i|install)\b|pip3?\s+install\b|python3?\s+-m\s+pip\s+install\b|poetry\s+install\b|uv\s+sync\b|dotnet\s+restore\b|bundle\s+install\b|composer\s+install\b|go\s+mod\s+download\b|Install-Module\b)'

$script:SetupCache = @(
    @{ Action = 'actions/setup-node';   Input = 'cache' }
    @{ Action = 'actions/setup-python'; Input = 'cache' }
    @{ Action = 'actions/setup-java';   Input = 'cache' }
    @{ Action = 'actions/setup-dotnet'; Input = 'cache' }
    @{ Action = 'ruby/setup-ruby';      Input = 'bundler-cache' }
)

function Get-UsesName {
    param([string]$Uses)
    if (-not $Uses) { return '' }
    return (($Uses -split '@')[0]).Trim()
}

# All the per-file rules. $DefaultBranch is the branch R1 asks about.
function Test-WorkflowRules {
    param($Ctx, $Model, [string]$DefaultBranch)
    $f = $Model.File
    $pr   = Get-Trigger $Model @('pull_request', 'pull_request_target')
    $push = Get-Trigger $Model @('push')
    $jobs = @($Model.Jobs)

    # ---- R1 ---------------------------------------------------------------------------------
    # Two ways one commit is judged twice: (a) the push that follows a merge re-runs what the PR
    # already ran, and (b) a push to a branch a PR is open FROM runs next to the pull_request run.
    # pull_request.branches filters the PR BASE and push.branches the PUSHED branch: different
    # questions, answered separately.
    Add-Eval $Ctx 'R1' 1
    if ($null -ne $pr -and $null -ne $push -and $jobs.Count -gt 0 -and -not (Test-PushIsTagsOnly $push)) {
        $pushDef = Test-BranchFilter $push.Branches $push.BranchesIgnore $DefaultBranch
        $prDef   = Test-BranchFilter $pr.Branches $pr.BranchesIgnore $DefaultBranch
        if ($null -eq $pushDef -or $null -eq $prDef) {
            Add-Unmeasured $Ctx 'R1' $f $push.Line 'un filtro de ramas usa un patron que esta auditoria no evalua (negacion, clase, ? o +)'
        } else {
            $incl = @($push.Branches)
            # every branch (bar the ignored ones): no positive list, or a catch-all pattern
            $allBranches = ($incl.Count -eq 0) -or ($incl -contains '**')
            # positive patterns that are not literally the default branch: a PR's head branch can match them
            $others = @($incl | Where-Object { $_ -ne $DefaultBranch })
            $wild   = @($others | Where-Object { $_ -match '\*' })
            $rerun  = ($pushDef -and $prDef)
            if ($allBranches -or $rerun -or $others.Count -gt 0) {
                foreach ($j in $jobs) {
                    if ($j.If -and $j.If -match 'github\.(event_name|ref)') { continue }    # the job tells the two events apart
                    $parts = @()
                    if ($allBranches) {
                        $ign = $(if (@($push.BranchesIgnore).Count -gt 0) { " (salvo $(@($push.BranchesIgnore) -join ', '))" } else { '' })
                        $parts += "cada push a cualquier rama${ign}: un commit empujado a la rama de una PR se juzga dos veces, y otra tras el merge"
                        $sev = 'high'
                    } else {
                        if ($rerun) { $parts += "push a ${DefaultBranch}: el merge repite el veredicto que la PR ya pago" }
                        if ($others.Count -gt 0) { $parts += "push a ramas que coinciden con [$($others -join ', ')]: una PR abierta desde una de esas ramas, o un merge a ellas, repite el veredicto" }
                        $sev = $(if ($rerun -or $wild.Count -gt 0) { 'medium' } else { 'low' })
                    }
                    Add-Finding $Ctx 'R1' $sev $f $j.Line ("job '$($j.Id)' corre en $($pr.Event) (linea $($pr.Line)) Y en push (linea $($push.Line)): " + ($parts -join '; ')) @() $Model
                }
            }
        }
    }

    # ---- R2 ---------------------------------------------------------------------------------
    if ($null -ne $pr -or $null -ne $push) {
        Add-Eval $Ctx 'R2' 1
        $wf = $Model.Concurrency
        $release = Test-ReleaseLike $Model
        $trigLine = $(if ($null -ne $pr) { $pr.Line } else { $push.Line })
        # The concurrency that applies: the workflow's own, or - when it has none - each job's own.
        # Judged unit by unit, so one job that cancels never hides another that does not.
        $units = @(); $uncovered = @()
        if ($wf.Present) { $units += [pscustomobject]@{ Label = 'el workflow'; C = $wf } }
        else {
            foreach ($j in $jobs) {
                if ($j.Concurrency.Present) { $units += [pscustomobject]@{ Label = "el job '$($j.Id)'"; C = $j.Concurrency } }
                else { $uncovered += $j }
            }
        }
        if ($units.Count -eq 0) {
            if ($release) {
                Add-Finding $Ctx 'R2' 'low' $f $trigLine 'workflow de release/deploy sin concurrency: dos releases pueden solaparse (debe llevar concurrency con cancel-in-progress: false)' @() $Model
            } else {
                Add-Finding $Ctx 'R2' 'medium' $f $trigLine 'sin concurrency: cada push nuevo a una PR deja correr (y cobrar) la ejecucion anterior, ya obsoleta' @() $Model
            }
        } else {
            foreach ($u in $units) {
                $cancelLine = $(if ($u.C.CancelLine -gt 0) { $u.C.CancelLine } else { $u.C.Line })
                if ($u.C.Cancel -eq 'expression') {
                    Add-Unmeasured $Ctx 'R2' $f $cancelLine "$($u.Label): cancel-in-progress es una expresion que esta auditoria no evalua"
                } elseif ($release) {
                    if ($u.C.Cancel -eq 'true') {
                        Add-Finding $Ctx 'R2' 'high' $f $cancelLine "$($u.Label) de release/deploy con cancel-in-progress: true: un release cancelado a medias deja tags y PRs inconsistentes (debe ser false)" @() $Model
                    }
                } elseif ($u.C.Cancel -ne 'true') {
                    Add-Finding $Ctx 'R2' 'medium' $f $u.C.Line "$($u.Label) tiene concurrency sin cancel-in-progress: true: las ejecuciones obsoletas siguen corriendo y cobrando" @() $Model
                }
            }
            if (-not $release -and $uncovered.Count -gt 0) {
                Add-Finding $Ctx 'R2' 'medium' $f $trigLine ("jobs sin concurrency: $(@($uncovered | ForEach-Object { $_.Id }) -join ', ') (los demas si la tienen): sus ejecuciones obsoletas siguen corriendo y cobrando") @() $Model
            }
        }
    }

    # ---- R3 ---------------------------------------------------------------------------------
    foreach ($j in $jobs) {
        if ($j.Uses) { continue }       # a reusable-workflow call takes no timeout-minutes of its own
        Add-Eval $Ctx 'R3' 1
        if ($null -eq $j.TimeoutRaw) {
            Add-Finding $Ctx 'R3' 'high' $f $j.Line "job '$($j.Id)' sin timeout-minutes: GitHub aplica 360 min por defecto; un job colgado se come el 12% de una cuota de 3000" @() $Model
        } elseif ($j.TimeoutRaw -match '^\d+$') {
            if ([int]$j.TimeoutRaw -ge 360) {
                Add-Finding $Ctx 'R3' 'high' $f $j.TimeoutLine "job '$($j.Id)' fija timeout-minutes: $($j.TimeoutRaw), que es el valor por defecto: no limita nada" @() $Model
            }
        } else {
            Add-Unmeasured $Ctx 'R3' $f $j.TimeoutLine "el timeout-minutes del job '$($j.Id)' es una expresion: no se evalua"
        }
    }

    # ---- R4 (advice; the engine adds the deadlock verdict once the required checks are known) ----
    if ($null -ne (Get-Trigger $Model @('pull_request', 'pull_request_target'))) { Add-Eval $Ctx 'R4' 1 }

    # ---- R5 ---------------------------------------------------------------------------------
    if ($null -ne $push -and -not (Test-PushIsTagsOnly $push)) {
        foreach ($j in $jobs) {
            if ($j.Uses) { continue }
            Add-Eval $Ctx 'R5' 1
            # a self-hosted runner does not spend GitHub-hosted minutes, whatever its os label says
            if (@(@($j.RunsOn.Labels) | Where-Object { $_ -ieq 'self-hosted' }).Count -gt 0) { continue }
            if ($j.RunsOn.Unresolved) {
                Add-Unmeasured $Ctx 'R5' $f $j.RunsOn.Line "el runs-on del job '$($j.Id)' no se puede resolver (una expresion, o una matriz con exclude)"
            }
            foreach ($lab in @($j.RunsOn.Labels)) {
                $mult = 0; $os = ''
                if ($lab -match '^(?i)windows') { $mult = 2; $os = 'windows' }
                elseif ($lab -match '^(?i)macos') { $mult = 10; $os = 'macos' }
                if ($mult -gt 0) {
                    Add-Finding $Ctx 'R5' 'high' $f $j.RunsOn.Line "job '$($j.Id)' corre en $lab en un push de rama (linea $($push.Line)): $os cuenta x$mult contra la cuota. Windows/macOS solo en push de tags" @() $Model
                }
            }
        }
    }

    # ---- R6 ---------------------------------------------------------------------------------
    foreach ($j in $jobs) {
        $hasCacheStep = @($j.Steps | Where-Object { (Get-UsesName $_.Uses) -like 'actions/cache*' }).Count -gt 0
        foreach ($s in $j.Steps) {
            $name = Get-UsesName $s.Uses
            if ($name -like 'actions/upload-artifact*') {
                Add-Eval $Ctx 'R6' 1
                if (-not $s.With.ContainsKey('retention-days')) {
                    Add-Finding $Ctx 'R6' 'medium' $f $s.UsesLine "job '$($j.Id)' sube un artefacto sin retention-days: se usa la retencion por defecto del repo/organizacion (90 dias salvo que la hayan cambiado)" @() $Model
                }
                continue
            }
            $rule = $script:SetupCache | Where-Object { $_.Action -eq $name } | Select-Object -First 1
            if ($null -ne $rule) {
                Add-Eval $Ctx 'R6' 1
                if (-not $s.With.ContainsKey($rule.Input) -and -not $hasCacheStep) {
                    Add-Finding $Ctx 'R6' 'medium' $f $s.UsesLine "job '$($j.Id)' usa $name sin '$($rule.Input):' ni un paso actions/cache: reinstala las dependencias en cada ejecucion" @() $Model
                }
            } elseif ($name -eq 'actions/setup-go') {
                Add-Eval $Ctx 'R6' 1
                $ver = $null
                if ($s.Uses -match '@v(\d+)') { $ver = [int]$Matches[1] }
                $cacheOff = ($s.With.ContainsKey('cache') -and "$($s.With['cache'])" -ieq 'false')
                if ($cacheOff -and -not $hasCacheStep) {
                    Add-Finding $Ctx 'R6' 'medium' $f $s.UsesLine "job '$($j.Id)' desactiva la cache de setup-go (cache: false) y no hay un paso actions/cache" @() $Model
                } elseif ($null -ne $ver -and $ver -lt 4 -and -not $s.With.ContainsKey('cache') -and -not $hasCacheStep) {
                    Add-Finding $Ctx 'R6' 'medium' $f $s.UsesLine "job '$($j.Id)' usa $($s.Uses): antes de v4 setup-go no cachea por defecto" @() $Model
                } elseif ($null -eq $ver) {
                    Add-Unmeasured $Ctx 'R6' $f $s.UsesLine "setup-go fijado por algo distinto de una etiqueta de version mayor: no se puede leer si cachea por defecto"
                }
            }
        }
    }

    # ---- R7 ---------------------------------------------------------------------------------
    foreach ($t in $Model.Triggers) {
        foreach ($c in @($t.Crons)) {
            Add-Eval $Ctx 'R7' 1
            $freq = Get-CronFrequency $c.Expr
            if (-not $freq.Parsed) {
                Add-Unmeasured $Ctx 'R7' $f $c.Line $freq.Reason
            } elseif ($freq.PerWeek -gt 1) {
                $sev = $(if ($freq.PerWeek -ge 14) { 'high' } else { 'medium' })
                Add-Finding $Ctx 'R7' $sev $f $c.Line ("cron '$($c.Expr)' corre unas $($freq.PerWeek) veces por semana: es gasto que corre aunque no trabajes. Semanal cuesta 1 vez") @() $Model
            }
        }
    }
}

# How does a required check context match a job?  'exact' | 'prefix' | '' (no match).
# The check name a job reports is its `name:` (or its id); a matrix appends " (values)". A name with
# an expression ("Test ${{ matrix.os }}" reports "Test ubuntu-latest") can only be matched on its
# literal prefix, which can collide with an unrelated check that starts the same way - so that
# match is 'prefix' and the callers say so instead of stating it as fact.
function Get-CheckMatchKind {
    param([string]$Context, $Job)
    $names = @($Job.Id)
    $kind = ''
    if ($Job.Name) {
        if ($Job.Name -match '\$\{\{') {
            $lit = ($Job.Name -split '\$\{\{')[0]
            if ($lit.Trim() -and $Context.StartsWith($lit)) { $kind = 'prefix' }
        }
        else { $names += $Job.Name }
    }
    foreach ($n in $names) {
        if ($Context -eq $n -or $Context.StartsWith("$n (")) { return 'exact' }
        # a job that CALLS a reusable workflow reports its checks as "<caller job> / <called job>"
        if ($Job.Uses -and $Context.StartsWith("$n / ")) { return 'exact' }
    }
    return $kind
}

function Test-CheckMatchesJob {
    param([string]$Context, $Job)
    return ((Get-CheckMatchKind $Context $Job) -ne '')
}

# A job whose name STARTS with an expression cannot be matched to a required check by name.
function Get-OpaqueJobs {
    param($Model)
    return @(@($Model.Jobs) | Where-Object { $_.Name -and $_.Name -match '^\s*\$\{\{' })
}

# Jobs of a workflow that are a required status check, given the required contexts: { Job; Kind }.
function Get-RequiredJobs {
    param($Model, [string[]]$Contexts)
    $hit = @()
    foreach ($j in @($Model.Jobs)) {
        $best = ''
        foreach ($c in @($Contexts)) {
            $k = Get-CheckMatchKind $c $j
            if ($k -eq 'exact') { $best = 'exact'; break }
            if ($k -eq 'prefix') { $best = 'prefix' }
        }
        if ($best) { $hit += [pscustomobject]@{ Job = $j; Kind = $best } }
    }
    return $hit
}

# R4 verdicts + the deadlock trap. Needs the required checks, so it runs after they are read.
function Test-PathFilterAndRequiredChecks {
    param($Ctx, $Models, $Required)
    foreach ($m in $Models) {
        $pr = Get-Trigger $m @('pull_request', 'pull_request_target')
        if ($null -eq $pr) { continue }
        $hasFilter = (@($pr.Paths).Count -gt 0 -or @($pr.PathsIgnore).Count -gt 0)
        $reqJobs = @()
        if ($Required.Contexts.Count -gt 0) { $reqJobs = @(Get-RequiredJobs $m $Required.Contexts) }

        if ($hasFilter) {
            Add-Eval $Ctx 'TRAP' 1
            if ($reqJobs.Count -gt 0) {
                $names = ($reqJobs | ForEach-Object { $_.Job.Id }) -join ', '
                $exact = @($reqJobs | Where-Object { $_.Kind -eq 'exact' }).Count -gt 0
                $sev   = $(if ($exact) { 'high' } else { 'medium' })
                $hedge = $(if ($exact) { '' } else { " OJO: el job coincide con el check solo por el prefijo de su nombre (lleva una expresion), que puede chocar con otro check: verificalo." })
                Add-Finding $Ctx 'TRAP' $sev $m.File $pr.Line ("el workflow filtra por rutas y su job '$names' es un check REQUERIDO: una PR que solo toque rutas filtradas nunca dispara el check, y GitHub la deja en 'Expected - waiting for status' para siempre (la unica salida es el bypass de admin).$hedge") @() $m
            } elseif (-not $Required.Complete) {
                Add-Unmeasured $Ctx 'TRAP' $m.File $pr.Line "el workflow filtra por rutas y los checks requeridos no se pudieron leer completos ($($Required.Reason)): no se midio si el filtro puede dejar una PR en deadlock"
            } elseif ($Required.Contexts.Count -gt 0 -and @(Get-OpaqueJobs $m).Count -gt 0) {
                Add-Unmeasured $Ctx 'TRAP' $m.File $pr.Line "el workflow filtra por rutas y un job tiene un nombre que empieza por una expresion: no se pudo comprobar si es un check requerido"
            }
            continue
        }

        # No filter: R4 advice, with the deadlock verdict attached.
        $caution = "Si el contenido (los .md, los datos) ES el producto, no se ignora. Un filtro solo sirve si de verdad ninguna ruta filtrada puede afectar a este workflow."
        if ($reqJobs.Count -gt 0) {
            $names = ($reqJobs | ForEach-Object { $_.Job.Id }) -join ', '
            $may = $(if (@($reqJobs | Where-Object { $_.Kind -eq 'exact' }).Count -gt 0) { 'es' } else { 'PODRIA ser (coincide solo por el prefijo de su nombre, que lleva una expresion)' })
            $verdict = "OJO: su job '$names' $may un check REQUERIDO en el ruleset; anadir un filtro de rutas aqui dejaria PRs paradas en 'Expected - waiting for status'. No lo anadas (o quita el requisito antes)."
        } elseif ($Required.Contexts.Count -gt 0 -and @(Get-OpaqueJobs $m).Count -gt 0) {
            $verdict = "Un job tiene un nombre que empieza por una expresion: no se pudo comprobar si es un check requerido. Comprueba que no lo es ANTES de anadir un filtro de rutas."
        } elseif ($Required.Complete) {
            $verdict = "No es un check requerido en el ruleset (leido), asi que un filtro de rutas no puede dejar una PR en deadlock."
        } else {
            $verdict = "No se pudieron leer los checks requeridos ($($Required.Reason)): comprueba que este workflow no lo es ANTES de anadir un filtro de rutas."
        }
        Add-Finding $Ctx 'R4' 'advice' $m.File $pr.Line ("$($pr.Event) sin paths / paths-ignore: cualquier PR lo dispara, tambien las que solo tocan documentacion. $verdict $caution") @() $m
    }
}

# Can two triggers fire for the same event instance? Disjoint branch lists cannot; anything this cannot
# decide (two globs, a pattern it does not evaluate) counts as overlapping, so it never invents a gap.
function Test-TriggerScopesOverlap {
    param($A, $B)
    $ia = @($A.Branches); $ib = @($B.Branches)
    if ($ia.Count -eq 0 -or $ib.Count -eq 0) { return $true }
    foreach ($p in $ia) {
        foreach ($q in $ib) {
            if ($p -eq $q) { return $true }
            $m1 = Test-GlobMatch $q $p
            $m2 = Test-GlobMatch $p $q
            if ($null -eq $m1 -or $null -eq $m2 -or $m1 -or $m2) { return $true }
        }
    }
    return $false
}

# Runners per PR + the setup that each of them repeats. Read from the files, not measured.
function Get-EventFanOut {
    param($Ctx, $Models, [string]$EventName, [string[]]$Names, [string[]]$SkipIfAlso = @())
    $rows = @()
    foreach ($m in $Models) {
        if ($null -eq (Get-Trigger $m $Names)) { continue }
        # A workflow already counted under another event (a PR workflow that also pushes) is not
        # counted twice: R1 reports that overlap.
        if ($SkipIfAlso.Count -gt 0 -and $null -ne (Get-Trigger $m $SkipIfAlso)) { continue }
        foreach ($j in @($m.Jobs)) {
            $installs = @()
            foreach ($s in $j.Steps) {
                if (-not $s.Run) { continue }
                foreach ($ln in ($s.Run -split "\r?\n")) {
                    $cmd = $ln.Trim()
                    if ($cmd -match $script:InstallPattern) { $installs += [pscustomobject]@{ Command = $cmd; Line = $s.RunLine } }
                }
            }
            $rows += [pscustomobject]@{
                File = $m.File; Model = $m; Trigger = (Get-Trigger $m $Names); JobId = $j.Id; JobLine = $j.Line; Reusable = [bool]$j.Uses
                Guarded = [bool]$j.If; MatrixSize = $j.MatrixSize
                Checkout = (@($j.Steps | Where-Object { (Get-UsesName $_.Uses) -eq 'actions/checkout' }).Count -gt 0)
                Installs = $installs
            }
        }
    }

    # runners
    $runners = 0; $reasons = @()
    foreach ($r in $rows) {
        if ($r.Reusable) { $runners += 1; $reasons += "el job '$($r.JobId)' ($($r.File)) llama a un workflow reutilizable: arranca un numero de runners que no se conoce"; continue }
        if ($null -eq $r.MatrixSize) { $runners += 1; $reasons += "el job '$($r.JobId)' ($($r.File)) tiene una matriz que no se puede contar exacta (se cuenta como 1)" }
        else { $runners += $r.MatrixSize }
        if ($r.Guarded) { $reasons += "el job '$($r.JobId)' ($($r.File)) tiene un if: puede no arrancar" }
    }
    $summary = [pscustomobject]@{
        Event = $EventName; Workflows = @($rows | ForEach-Object { $_.File } | Select-Object -Unique).Count
        Jobs = $rows.Count; Runners = $runners; Exact = ($reasons.Count -eq 0); Reasons = @($reasons)
    }

    # repeated setup: the same install command in >= 2 jobs the same event starts
    Add-Eval $Ctx 'FAN' $rows.Count
    $byCmd = @{}
    foreach ($r in $rows) {
        foreach ($i in $r.Installs) {
            if (-not $byCmd.ContainsKey($i.Command)) { $byCmd[$i.Command] = @() }
            if (-not (@($byCmd[$i.Command]) | Where-Object { $_.File -eq $r.File -and $_.JobId -eq $r.JobId })) {
                $byCmd[$i.Command] += [pscustomobject]@{ File = $r.File; JobId = $r.JobId; Line = $i.Line; Model = $r.Model; Trigger = $r.Trigger }
            }
        }
    }
    foreach ($cmd in $byCmd.Keys) {
        # Only jobs that can run for the SAME event instance: two workflows whose branch filters never
        # overlap (push to main vs push to dev) are not paid for together.
        $all = @($byCmd[$cmd])
        $where = @($all | Where-Object { $a = $_; @($all | Where-Object { -not [object]::ReferenceEquals($_, $a) -and (Test-TriggerScopesOverlap $a.Trigger $_.Trigger) }).Count -gt 0 })
        if ($where.Count -lt 2) { continue }
        $ev = @($where | ForEach-Object { "$($_.File):$($_.Line) (job '$($_.JobId)')" })
        $first = $where[0]
        Add-Finding $Ctx 'FAN' 'medium' $first.File $first.Line ("'$cmd' se repite en $($where.Count) jobs que dispara $EventName, y cada uno es su propio runner con su propio checkout: el setup se paga $($where.Count) veces para juzgar un commit. Un workflow con jobs, o un job con pasos, lo pagaria una vez") $ev $first.Model
    }
    return $summary
}

# Run every file rule + the cross-file ones. $Required: @{ Contexts; Complete; Reason }.
function Invoke-WorkflowRules {
    param($Ctx, $Models, [string]$DefaultBranch, $Required)
    $good = @($Models | Where-Object { $_.Parsed })
    foreach ($m in @($Models | Where-Object { -not $_.Parsed })) {
        Add-Unmeasured $Ctx 'PARSE' $m.File 0 "esta auditoria no pudo leer el archivo ($($m.Error)): no se evaluo ninguna de sus reglas"
    }
    foreach ($m in $good) { Test-WorkflowRules $Ctx $m $DefaultBranch }
    Test-PathFilterAndRequiredChecks $Ctx $good $Required
    $perEvent = @()
    $perEvent += (Get-EventFanOut $Ctx $good 'pull_request' @('pull_request', 'pull_request_target'))
    $perEvent += (Get-EventFanOut $Ctx $good 'push' @('push') @('pull_request', 'pull_request_target'))
    return $perEvent
}

# ============================================================================================
# Live providers (gh, read-only)
# ============================================================================================

function Get-RepoFacts {
    param([string]$Repo)
    $r = Invoke-Gh -GhArgs @('api', "repos/$Repo") -What "leer el repo $Repo" -Json -Retries 2
    [pscustomobject]@{
        Repo = $Repo; Name = $r.name; Owner = $r.owner.login; OwnerType = $r.owner.type
        Private = [bool]$r.private; DefaultBranch = $r.default_branch; Archived = [bool]$r.archived
    }
}

function Get-RemoteWorkflowFiles {
    param([string]$Repo, [string]$Branch, $Ctx)
    $files = @()
    try {
        $list = Invoke-Gh -GhArgs @('api', "repos/$Repo/contents/.github/workflows?ref=$Branch") -What "listar los workflows de $Repo" -Json -Retries 2
    } catch {
        if ("$($_.Exception.Message)" -match 'HTTP 404|Not Found') { return @() }     # no workflows directory: measured, empty
        throw
    }
    foreach ($e in @($list)) {
        if ($e.type -ne 'file' -or $e.name -notmatch '\.ya?ml$') { continue }
        try {
            $out = Invoke-Gh -GhArgs @('api', '-H', 'Accept: application/vnd.github.raw', "repos/$Repo/contents/$($e.path)?ref=$Branch") -What "leer $($e.path)" -Retries 2
            $files += [pscustomobject]@{ File = $e.name; Text = (@($out) -join "`n") }
        } catch {
            Add-Unmeasured $Ctx 'PARSE' $e.name 0 "no se pudo descargar el archivo: $($_.Exception.Message)"
        }
    }
    return $files
}

function Get-LocalWorkflowFiles {
    param([string]$Path)
    $dir = Join-Path $Path '.github/workflows'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match '\.ya?ml$' } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ File = $_.Name; Text = [System.IO.File]::ReadAllText($_.FullName) }
    })
}

# Required status checks for the branch: the rulesets that apply to it, plus classic branch
# protection. Complete = $false when either source could not be read (then "not required" is not
# a claim this audit may make).
function Get-RequiredChecks {
    param([string]$Repo, [string]$Branch)
    $contexts = @(); $problems = @(); $complete = $true
    try {
        $rules = Invoke-Gh -GhArgs @('api', "repos/$Repo/rules/branches/$Branch") -What "leer las reglas de $Branch" -Json -Retries 2
        foreach ($r in @($rules)) {
            if ($r.type -eq 'required_status_checks') {
                foreach ($c in @($r.parameters.required_status_checks)) { if ($c.context) { $contexts += [string]$c.context } }
            }
        }
    } catch { $complete = $false; $problems += "rulesets: $($_.Exception.Message)" }
    try {
        $prot = Invoke-Gh -GhArgs @('api', "repos/$Repo/branches/$Branch/protection/required_status_checks") -What "leer la proteccion de $Branch" -Json -Retries 2
        foreach ($c in @($prot.contexts)) { if ($c) { $contexts += [string]$c } }
        foreach ($c in @($prot.checks)) { if ($c.context) { $contexts += [string]$c.context } }
    } catch {
        if ("$($_.Exception.Message)" -notmatch 'Branch not protected|Required status checks not enabled') {
            $complete = $false; $problems += "branch protection: $($_.Exception.Message)"
        }
    }
    [pscustomobject]@{ Contexts = @($contexts | Select-Object -Unique); Complete = $complete; Reason = ($problems -join '; ') }
}

# Measure-Object -Sum is $null on an empty input in Windows PowerShell 5.1 and 0 in 7: one answer for both.
function Get-Sum {
    param($Items, [string]$Prop)
    $s = (@($Items) | Measure-Object $Prop -Sum).Sum
    if ($null -eq $s) { return 0.0 }
    return [double]$s
}

function Get-DayKey {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    return ([string]$Value).Substring(0, 10)
}

# The measured half. Everything numeric in the result came out of the usage endpoint.
function Get-UsageMeasure {
    param($Facts, [string]$Month, [int]$Top = 5)
    $parts = $Month -split '-'
    $seg = $(if ($Facts.OwnerType -eq 'Organization') { "organizations/$($Facts.Owner)" } else { "users/$($Facts.Owner)" })
    try {
        $body = Invoke-Gh -GhArgs @('api', "/$seg/settings/billing/usage?year=$([int]$parts[0])&month=$([int]$parts[1])") `
                          -What "leer el uso de Actions de $($Facts.Owner) ($Month)" -Json -Retries 2
    } catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; Month = $Month }
    }
    $items = @($body.usageItems | Where-Object { $_.product -eq 'actions' })

    $mine = @($items | Where-Object { $_.repositoryName -ieq $Facts.Name })
    $minRows = @($mine | Where-Object { $_.unitType -eq 'Minutes' })
    $bySku = [ordered]@{}
    foreach ($g in ($minRows | Group-Object sku | Sort-Object Name)) { $bySku[$g.Name] = [math]::Round((Get-Sum $g.Group 'quantity'), 2) }
    $byDay = @()
    foreach ($g in ($minRows | Group-Object { Get-DayKey $_.date } | Sort-Object Name)) {
        $skus = [ordered]@{}
        foreach ($sg in ($g.Group | Group-Object sku | Sort-Object Name)) { $skus[$sg.Name] = [math]::Round((Get-Sum $sg.Group 'quantity'), 2) }
        $byDay += [pscustomobject]@{ Date = $g.Name; Minutes = [math]::Round((Get-Sum $g.Group 'quantity'), 2); Skus = $skus }
    }
    $storage = Get-Sum @($mine | Where-Object { $_.unitType -eq 'GigabyteHours' }) 'quantity'
    $weighted = 0.0; $unweighted = @()
    foreach ($k in $bySku.Keys) {
        if ($script:QuotaMultiplier.ContainsKey($k)) { $weighted += $bySku[$k] * $script:QuotaMultiplier[$k] } else { $unweighted += $k }
    }
    $gross = Get-Sum $mine 'grossAmount'
    $net   = Get-Sum $mine 'netAmount'

    # account view: every repo that used minutes, biggest first; visibility asked per repo
    $repoRows = @()
    foreach ($g in ($items | Where-Object { $_.unitType -eq 'Minutes' } | Group-Object repositoryName)) {
        $skuMin = @{}
        foreach ($sg in ($g.Group | Group-Object sku)) { $skuMin[$sg.Name] = Get-Sum $sg.Group 'quantity' }
        $w = 0.0
        foreach ($k in $skuMin.Keys) { if ($script:QuotaMultiplier.ContainsKey($k)) { $w += $skuMin[$k] * $script:QuotaMultiplier[$k] } }
        $repoRows += [pscustomobject]@{ Repo = $g.Name; Minutes = [math]::Round((Get-Sum $g.Group 'quantity'), 2); Weighted = $w; Visibility = 'unknown' }
    }
    $repoRows = @($repoRows | Sort-Object Minutes -Descending)
    foreach ($r in $repoRows) {
        if ($r.Repo -ieq $Facts.Name) { $r.Visibility = $(if ($Facts.Private) { 'private' } else { 'public' }); continue }
        try {
            $rv = Invoke-Gh -GhArgs @('api', "repos/$($Facts.Owner)/$($r.Repo)", '--jq', '.private') -What "leer la visibilidad de $($r.Repo)"
            $t = ((@($rv) | ForEach-Object { "$_" }) -join '').Trim()
            if ($t -eq 'true') { $r.Visibility = 'private' } elseif ($t -eq 'false') { $r.Visibility = 'public' }
        } catch { }
    }
    $quotaBearing = Get-Sum @($repoRows | Where-Object { $_.Visibility -eq 'private' }) 'Weighted'
    $unknownVis   = @($repoRows | Where-Object { $_.Visibility -eq 'unknown' })

    [pscustomobject]@{
        Measured = $true; Reason = ''; Month = $Month; Endpoint = "$seg/settings/billing/usage"
        RepoMinutes = [math]::Round((Get-Sum $minRows 'quantity'), 2)
        BySku = $bySku; ByDay = $byDay
        StorageGbHours = [math]::Round($storage, 4)
        QuotaWeightedMinutes = $weighted; UnweightedSkus = @($unweighted)
        GrossUsd = [math]::Round($gross, 4); NetUsd = [math]::Round($net, 4)
        AccountMinutes = [math]::Round((Get-Sum @($items | Where-Object { $_.unitType -eq 'Minutes' }) 'quantity'), 2)
        AccountQuotaBearingWeighted = [double]$quotaBearing
        AccountUnknownVisibility = @($unknownVis | ForEach-Object { $_.Repo })
        TopRepos = @($repoRows | Select-Object -First $Top)
    }
}

# ============================================================================================
# The audit
# ============================================================================================

function Get-ActionsCostAudit {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Month = '',
        [switch]$Local,
        [string]$Path = '.',
        [string]$Branch = '',
        [int]$Top = 5
    )
    if (-not $Month) { $Month = (Get-Date).ToUniversalTime().ToString('yyyy-MM') }
    if ($Month -notmatch '^\d{4}-(0[1-9]|1[0-2])$') { throw "-Month debe ser yyyy-MM (recibi '$Month')." }

    $ctx   = New-AuditContext
    $facts = Get-RepoFacts $Repo
    if (-not $Branch) { $Branch = $facts.DefaultBranch }

    # -- workflow files
    if ($Local) {
        $files = @(Get-LocalWorkflowFiles $Path)
        $source = "working tree ($Path)"
    } else {
        $files = @(Get-RemoteWorkflowFiles $Repo $Branch $ctx)
        $source = "branch $Branch on GitHub"
    }
    $models = @($files | ForEach-Object { ConvertTo-WorkflowModel $_.File $_.Text })

    # -- required checks (only worth the calls when some workflow runs on a PR)
    $required = [pscustomobject]@{ Contexts = @(); Complete = $true; Reason = '' }
    if (@($models | Where-Object { $_.Parsed -and (Get-Trigger $_ @('pull_request', 'pull_request_target')) }).Count -gt 0) {
        $required = Get-RequiredChecks $Repo $Branch
        if (-not $required.Complete) {
            Add-Unmeasured $ctx 'TRAP' '' 0 "los checks requeridos no se pudieron leer completos: $($required.Reason)"
        }
    }

    Add-Eval $ctx 'PARSE' $models.Count
    $perEvent = Invoke-WorkflowRules $ctx $models $Branch $required

    # -- cost
    Add-Eval $ctx 'COST' 1
    $usage = Get-UsageMeasure $facts $Month $Top
    if (-not $usage.Measured) {
        Add-Unmeasured $ctx 'COST' '' 0 "el endpoint de uso no se pudo leer, asi que NO se reporta ningun coste (un cero seria una afirmacion): $($usage.Reason)"
    }

    # -- R8: an observation, never an action
    Add-Eval $ctx 'R8' 1
    if ($facts.Private) {
        $mins = $(if ($usage.Measured) { "$($usage.RepoMinutes) min medidos en $Month" } else { 'el uso no se pudo medir' })
        Add-Finding $ctx 'R8' 'observation' '' 0 ("el repo es PRIVADO ($mins). Los repos publicos no consumen cuota de Actions; los privados si. Es una observacion: la visibilidad es decision del dueno y esta auditoria no propone cambiarla. Si el contenido tiene o no motivo para ser privado, no lo puede medir.") @() $null
    }

    # -- ledger + per-file summary
    $ledger = @()
    foreach ($k in $script:RuleTitles.Keys) {
        $row = Get-LedgerRow $ctx $k
        $ledger += [pscustomobject]@{ Rule = $k; Title = $script:RuleTitles[$k]; Evaluated = $row.Evaluated; Findings = $row.Findings; NotMeasured = $row.NotMeasured }
    }
    $wfRows = @($models | ForEach-Object {
        [pscustomobject]@{
            File = $_.File; Name = $_.Name; Parsed = $_.Parsed; Error = $_.Error
            Events = @($_.Triggers | ForEach-Object { $_.Event }); Jobs = @($_.Jobs).Count
        }
    })
    $runnersPerPr = @($perEvent | Where-Object { $_.Event -eq 'pull_request' -and $_.Jobs -gt 0 } | Select-Object -First 1)[0]
    $order = @{ 'high' = 0; 'medium' = 1; 'low' = 2; 'advice' = 3; 'observation' = 4 }
    $sorted = @($ctx.Findings | Sort-Object @{ Expression = { $order[$_.Severity] } }, Rule, File, Line)

    [pscustomobject]@{
        Repo = $Repo; Branch = $Branch; Private = $facts.Private; Source = $source; Month = $Month
        Workflows = $wfRows; Cost = $usage; RunnersPerPr = $runnersPerPr
        RequiredChecks = $required; Findings = $sorted; Unmeasured = @($ctx.Unmeasured); Rules = $ledger
        Method = @(
            'Coste = numeros del endpoint de uso de la cuenta. No se usa el endpoint de timing de los runs (devuelve 0) ni el reloj de pared de un run (incluye la cola).'
            'Minutos ponderados = minutos medidos x multiplicador documentado (Linux 1, Windows 2, macOS 10). Los SKU de runners grandes se listan, no se ponderan.'
            'Las reglas leen los workflows de la fuente elegida; un archivo que esta auditoria no sabe leer se reporta, no se omite.'
        )
    }
}

# ============================================================================================
# Report
# ============================================================================================

function Format-Num { param($N) return ([double]$N).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) }

function Write-ActionsCostReport {
    param($R)
    $sevColor = @{ 'high' = 'Red'; 'medium' = 'DarkYellow'; 'low' = 'Yellow'; 'advice' = 'Cyan'; 'observation' = 'Gray' }
    $sevLabel = @{ 'high' = 'ALTA'; 'medium' = 'MEDIA'; 'low' = 'BAJA'; 'advice' = 'CONSEJO'; 'observation' = 'OBSERVACION' }

    Write-Host ''
    Write-Host "=== /board actions-cost - costo de Actions de $($R.Repo) ===" -ForegroundColor Cyan
    Write-Host "    Solo lectura: no cambia nada en ningun repo. Workflows leidos de: $($R.Source)" -ForegroundColor DarkGray
    Write-Host ''

    Write-Host "-- 1. COSTE MEDIDO ($($R.Month), endpoint de uso de la cuenta) --" -ForegroundColor Cyan
    $c = $R.Cost
    if (-not $c.Measured) {
        Write-Host "  NO MEDIDO: $($c.Reason)" -ForegroundColor Red
        Write-Host "  (no se imprime un 0: un 0 seria una afirmacion que esta auditoria no puede respaldar)" -ForegroundColor DarkGray
    } else {
        Write-Host ("  {0}: {1} min medidos este mes ({2})" -f $R.Repo, (Format-Num $c.RepoMinutes), $(if ($R.Private) { 'repo privado: cuenta contra la cuota' } else { 'repo publico: no consume cuota' }))
        foreach ($k in $c.BySku.Keys) {
            $note = $(if ($script:QuotaMultiplier.ContainsKey($k)) { " (x$($script:QuotaMultiplier[$k]) contra la cuota)" } else { ' (SKU sin multiplicador conocido: no ponderado)' })
            Write-Host ("    {0,-22} {1,8} min{2}" -f $k, (Format-Num $c.BySku[$k]), $note)
        }
        if ($R.Private -and $c.BySku.Count -gt 0) {
            Write-Host ("  Ponderado (minutos x multiplicador documentado, DERIVADO): {0} min de cuota" -f (Format-Num $c.QuotaWeightedMinutes))
        }
        Write-Host ("  Almacenamiento: {0} GB-hora   Importe bruto: `$ {1}   Importe cobrado: `$ {2}" -f (Format-Num $c.StorageGbHours), (Format-Num $c.GrossUsd), (Format-Num $c.NetUsd))
        if ($c.ByDay.Count -gt 0) {
            Write-Host '  Por dia:'
            foreach ($d in $c.ByDay) {
                $skus = ($d.Skus.Keys | ForEach-Object { "$_ $(Format-Num $d.Skus[$_])" }) -join ', '
                Write-Host ("    {0}  {1,8} min   ({2})" -f $d.Date, (Format-Num $d.Minutes), $skus) -ForegroundColor DarkGray
            }
        }
        Write-Host ("  Cuenta {0}: {1} min en total; {2} min ponderados en repos privados" -f $R.Repo.Split('/')[0], (Format-Num $c.AccountMinutes), (Format-Num $c.AccountQuotaBearingWeighted))
        foreach ($t in $c.TopRepos) {
            Write-Host ("    {0,-40} {1,8} min   {2}" -f $t.Repo, (Format-Num $t.Minutes), $t.Visibility) -ForegroundColor DarkGray
        }
        if ($c.AccountUnknownVisibility.Count -gt 0) {
            Write-Host "  Visibilidad no leida para: $($c.AccountUnknownVisibility -join ', ') (no entran en el ponderado de cuota)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ''

    Write-Host '-- 2. RUNNERS POR PR (leido de los workflows, no medido) --' -ForegroundColor Cyan
    $rp = $R.RunnersPerPr
    if ($rp) {
        Write-Host ("  Una PR arranca {0} runner(s): {1} job(s) en {2} workflow(s). Exacto: {3}" -f $rp.Runners, $rp.Jobs, $rp.Workflows, $(if ($rp.Exact) { 'si' } else { 'no' }))
        foreach ($why in $rp.Reasons) { Write-Host "    - $why" -ForegroundColor DarkGray }
    } else { Write-Host '  Ningun workflow se dispara con pull_request.' }
    Write-Host ''

    Write-Host '-- 3. HALLAZGOS (cada uno con archivo:linea y la linea citada) --' -ForegroundColor Cyan
    if ($R.Findings.Count -eq 0) { Write-Host '  Ninguno. Mira la seccion 5: dice cuantas cosas se evaluaron.' }
    foreach ($f in $R.Findings) {
        $where = $(if ($f.File) { "$($f.File):$($f.Line)" } else { '(repo)' })
        Write-Host ("  [{0}] {1,-4} {2}  {3}" -f $sevLabel[$f.Severity], $f.Rule, $where, $f.Message) -ForegroundColor $sevColor[$f.Severity]
        if ($f.Snippet) { Write-Host "         > $($f.Snippet)" -ForegroundColor DarkGray }
        foreach ($e in $f.Evidence) { Write-Host "         - $e" -ForegroundColor DarkGray }
    }
    Write-Host ''

    Write-Host '-- 4. NO SE PUDO MEDIR --' -ForegroundColor Cyan
    if ($R.Unmeasured.Count -eq 0) { Write-Host '  Nada quedo sin medir.' }
    foreach ($u in $R.Unmeasured) {
        $where = $(if ($u.File) { "$($u.File):$($u.Line)" } else { '(general)' })
        Write-Host ("  {0,-5} {1}  {2}" -f $u.Rule, $where, $u.Reason) -ForegroundColor DarkYellow
    }
    Write-Host ''

    Write-Host '-- 5. LIBRO DE REGLAS (evaluado / hallazgos / sin medir) --' -ForegroundColor Cyan
    foreach ($l in $R.Rules) {
        Write-Host ("  {0,-5} {1,-58} {2,3} / {3,2} / {4,2}" -f $l.Rule, $l.Title, $l.Evaluated, $l.Findings, $l.NotMeasured)
    }
    Write-Host ''
    Write-Host '  Como se midio:' -ForegroundColor DarkGray
    foreach ($m in $R.Method) { Write-Host "    $m" -ForegroundColor DarkGray }
    Write-Host ''
}

# Dot-source guard: with $env:ABIOS_ACTIONSCOST_DOTSOURCE set, return after defining the functions
# WITHOUT touching git, gh or the token - lets the tests drive the real code.
if ($env:ABIOS_ACTIONSCOST_DOTSOURCE) { return }

# ------------------------------------------------------------------------------- main
try {
    if (-not $Repo) { $Repo = $(if ($Local) { Get-RepoFromOrigin -Path $Path } else { Get-RepoFromOrigin }) }
    if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo debe ser owner/name (recibi '$Repo')." }
    $owner = ($Repo -split '/')[0]

    # Identity: the owner's account, or the AGENT's inside a braked run - the one resolver.
    $prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
    $env:ABIOS_TOKENVAR_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
    $env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
    $ctxTok = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner $owner -ExplicitVar $TokenVar
    $env:GH_TOKEN = $ctxTok.token

    $report = Get-ActionsCostAudit -Repo $Repo -Month $Month -Local:$Local -Path $Path -Branch $Branch -Top $Top
    if ($Json) { $report | ConvertTo-Json -Depth 10 } else { Write-ActionsCostReport $report }
    exit 0
} catch {
    Write-Host "No pude auditar el costo de Actions: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Esto NO significa 'sin problemas': la auditoria no se completo." -ForegroundColor Red
    exit 1
}
