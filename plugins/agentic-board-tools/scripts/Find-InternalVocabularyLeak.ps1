<#
.SYNOPSIS
    Detect internal implementation vocabulary (script filenames, bare extensions, version-pinned
    cache paths) in a string meant for a user to read.

.DESCRIPTION
    Reported first-hand by the product owner, a BI professional and not a programmer, after a
    live `/expert auto` session: "me choca ver como esto Expert-Auto.ps1; PS1 no se para que" —
    seeing a raw script filename told them nothing and broke their trust that the tool was
    speaking to them, not at them (#491).

    Three failure shapes, all pure text matching (#494):
      - A PowerShell script filename in this codebase's own naming convention
        (`Verb-Noun.ps1`, e.g. `Board-Work.ps1`, `New-BoardPR.ps1`).
      - A bare `.ps1`/`.psm1`/`.psd1` extension mentioned on its own, not as part of a filename
        match above (catches "the .ps1 file" phrasing a Verb-Noun regex would miss).
      - A version-pinned plugin cache path (`plugins/agentic-board/agentic-board/0.37.0/...`) —
        these break on the next release, so printing one is doubly wrong: it names an internal
        path AND that path will 404 in a month.

    Deliberately text-only, no filesystem access: the same check has to run over BOTH literal
    strings extracted from a script's own `Write-Host` calls (Get-WriteHostArgumentText, in this
    same file) and prose in commands/*.md or skills/*.md — two very different sources feeding one
    rule, per CONTRIBUTING's command-surface contract and the epic's own prior-art note that this
    belongs in `CommandSurface.Tests.ps1`, not a new harness.

.EXAMPLE
    . .\Find-InternalVocabularyLeak.ps1
    Find-InternalVocabularyLeak -Text 'Siguiente paso: Board-Work.ps1 -Start <n>'
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# This codebase's own filename convention: PascalCase Verb-Noun(-Noun...).ps1 — matches every
# script under scripts/*.ps1 (Board-Work.ps1, New-BoardPR.ps1, Tmdl-DiffReview.ps1, ...) without
# also matching ordinary prose, which a looser `[A-Za-z]+\.ps1` would (e.g. "a .ps1 file").
$script:ScriptFilenamePattern = '\b[A-Z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+\.ps(?:1|m1|d1)\b'

# A bare extension not already covered by a filename match above — "the .ps1 script" phrasing.
$script:BareExtensionPattern = '(?<![A-Za-z0-9_-])\.ps(?:1|m1|d1)\b'

# A version-pinned plugin cache path: breaks on the next release the moment it is printed.
$script:CachePathPattern = '(?i)[\\/]plugins[\\/]cache[\\/][^\s"'']*?[\\/]\d+\.\d+\.\d+(?:[\\/][^\s"'']*)?'

<#  Scan $Text for internal vocabulary. Returns an array of @{ Kind; Match } — empty when clean.
    Kind is one of 'ScriptFilename' / 'BareExtension' / 'CachePath'. A bare-extension hit whose
    span is already covered by a filename hit is not reported twice. Pure. #>
function Find-InternalVocabularyLeak {
    param([string]$Text = '')
    $t = "$Text"
    if (-not $t) { return @() }

    $hits = [System.Collections.Generic.List[hashtable]]::new()
    $filenameSpans = [System.Collections.Generic.List[object]]::new()

    foreach ($m in [regex]::Matches($t, $script:ScriptFilenamePattern)) {
        $hits.Add(@{ Kind = 'ScriptFilename'; Match = $m.Value })
        $filenameSpans.Add(@{ Start = $m.Index; End = ($m.Index + $m.Length) })
    }
    foreach ($m in [regex]::Matches($t, $script:BareExtensionPattern)) {
        $covered = [bool]($filenameSpans | Where-Object { $m.Index -ge $_.Start -and $m.Index -lt $_.End })
        if (-not $covered) { $hits.Add(@{ Kind = 'BareExtension'; Match = $m.Value }) }
    }
    foreach ($m in [regex]::Matches($t, $script:CachePathPattern)) {
        $hits.Add(@{ Kind = 'CachePath'; Match = $m.Value })
    }
    return @($hits | ForEach-Object { [pscustomobject]$_ })
}

<#  Every `Write-Host` call's non-flag argument text in a .ps1 file, with its line number.
    AST-based (not line-regex) so a multi-line or `-f`-formatted Write-Host is read whole and a
    `-ForegroundColor Cyan`-style parameter name is never mistaken for message text. Returns
    @{ Line; Text } per argument — NOT pure (reads the file), kept in this file because it is the
    other half of the same concern: producing the strings Find-InternalVocabularyLeak checks. #>
function Get-WriteHostArgumentText {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { return @() }

    $calls = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.CommandElements.Count -gt 0 -and
        ("$($node.CommandElements[0].Extent.Text)" -eq 'Write-Host')
    }, $true)

    $out = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in $calls) {
        for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
            $el = $c.CommandElements[$i]
            # Skip parameter tokens (-ForegroundColor, -NoNewline, ...) and their value — a color
            # NAME is never user-facing text, and misreading it as such would be a false positive.
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { $i++; continue }
            $out.Add(@{ Line = $el.Extent.StartLineNumber; Text = $el.Extent.Text })
        }
    }
    return @($out | ForEach-Object { [pscustomobject]$_ })
}

# Dot-source guard: tests set $env:ABIOS_VOCABLEAK_DOTSOURCE to load the pure core only.
if ($env:ABIOS_VOCABLEAK_DOTSOURCE) { return }
