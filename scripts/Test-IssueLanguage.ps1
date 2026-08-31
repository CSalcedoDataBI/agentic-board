<#  Test-IssueLanguage.ps1 — flag issue text that is not in English (#305).

    This repo is English-only, but `abios-feedback` files its issues from ANY project, usually while
    the conversation with the user is in Spanish. The rule itself lives where the text is drafted
    (skills/abios-feedback/SKILL.md); this is the CI backstop, because instruction alone is exactly
    what drifted — 12 of 170 issues, all in two days.

    It never blocks: GitHub has no pre-create hook for issues, so the only honest options are
    "label it" or "pretend". It labels, which makes drift visible instead of silent.

    Detection is deliberately conservative, because a detector that cries wolf gets muted:
      * fenced and inline code is stripped BEFORE scoring — issues legitimately quote Spanish tool
        output (a Windows PowerShell parse error, for instance) and that is not a language problem;
      * markers are Spanish function words that are NOT also English words and NOT common
        identifiers. Notably absent: 'todo', 'no', 'solo', 'con', 'es', 'un' — every one of them
        appears in ordinary English dev prose, and 'todo'/'no' alone were enough to make a naive
        scan flag #8 and #84, two English issues whose crime was discussing Spanish;
      * accented characters and inverted punctuation are near-unambiguous and score double.

    Thresholds are tuned against the real corpus and pinned by Test-IssueLanguage.Tests.ps1, which
    asserts BOTH directions: the known-Spanish issues flag, and the known-English ones do not.

    Usage:
      ./scripts/Test-IssueLanguage.ps1 -Title "..." -Body "..."          # -> object
      ./scripts/Test-IssueLanguage.ps1 -Title "..." -Body "..." -AsJson  # -> json, for CI
#>
[CmdletBinding()]
param(
    [string]$Title = '',
    [string]$Body  = '',
    [int]$TitleThreshold = 2,
    [int]$BodyThreshold  = 6,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

# Spanish function words with no English homograph. Kept short on purpose: every term here is one
# that cannot plausibly appear in an English sentence about PowerShell.
$script:SpanishMarkers = @(
    'el','la','los','las','una','unos','unas','del','al'
    'que','para','sin','por','pero','como','cuando','donde','porque','aunque'
    'sobre','entre','desde','hasta','tras','segun','mientras','antes','despues'
    'esto','este','esta','estos','estas','eso','esos','esas'
    'esta','estan','hay','puede','pueden','debe','deben','hace','hacen','tiene','tienen'
    'ya','muy','cada','tambien','asi','aqui','alli','siempre','nunca','ahora','entonces'
    'falta','arreglo','mejora','fallo','archivo','rama','cambio','prueba'
    'se','su','sus','le','les','lo','ni','mas','pero'
)

# Strong signals: characters that simply do not occur in English prose.
$script:AccentPattern = '[áéíóúüñ¿¡]'

function Remove-CodeSpans {
    <# Strip fenced blocks, inline code and URLs. Quoting a Spanish error message is not writing
       Spanish, and a URL is not prose. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '(?s)```.*?```', ' ')      # fenced blocks
    $t = [regex]::Replace($t, '(?s)~~~.*?~~~', ' ')      # alternate fence
    $t = [regex]::Replace($t, '`[^`]*`', ' ')            # inline code
    $t = [regex]::Replace($t, '<!--.*?-->', ' ')         # html comments
    $t = [regex]::Replace($t, 'https?://\S+', ' ')       # urls
    return $t
}

function Get-SpanishScore {
    <# Pure: text in, score out. An accented character counts double — it is the one signal that
       cannot be an English word in disguise. #>
    param([string]$Text)
    if (-not $Text) { return 0 }
    $prose = Remove-CodeSpans -Text $Text
    $score = 0
    foreach ($m in $script:SpanishMarkers) {
        $score += ([regex]::Matches($prose, "\b$m\b", 'IgnoreCase')).Count
    }
    $score += 2 * ([regex]::Matches($prose, $script:AccentPattern, 'IgnoreCase')).Count
    return $score
}

function Test-IssueLanguage {
    <# Verdict for one issue. Title and body are scored separately: a Spanish title is the loud
       failure (it is what everyone reads), a Spanish body needs more evidence because bodies are
       long and quote things. #>
    param([string]$Title, [string]$Body, [int]$TitleThreshold = 2, [int]$BodyThreshold = 6)
    $titleScore = Get-SpanishScore -Text $Title
    $bodyScore  = Get-SpanishScore -Text $Body
    [pscustomobject]@{
        TitleScore = $titleScore
        BodyScore  = $bodyScore
        IsEnglish  = ($titleScore -lt $TitleThreshold) -and ($bodyScore -lt $BodyThreshold)
        Reason     = @(
            if ($titleScore -ge $TitleThreshold) { "title scores $titleScore (>= $TitleThreshold)" }
            if ($bodyScore  -ge $BodyThreshold)  { "body scores $bodyScore (>= $BodyThreshold)" }
        ) -join '; '
    }
}

# Dot-source guard: with $env:ABIOS_ISSUELANG_DOTSOURCE set, return after defining the pure
# helpers WITHOUT emitting output - lets the tests unit-test them.
if ($env:ABIOS_ISSUELANG_DOTSOURCE) { return }

$verdict = Test-IssueLanguage -Title $Title -Body $Body `
    -TitleThreshold $TitleThreshold -BodyThreshold $BodyThreshold
if ($AsJson) { $verdict | ConvertTo-Json -Compress } else { $verdict }
