<#
    Issue search: "is this defect already filed?" (#675, #476). Functions only - NO param block and no
    output at load, so dot-sourcing it cannot clobber the caller's parameters (the trap that bit
    Board-Merge, #536). Used by Find-DuplicateIssue.ps1 (the pre-filing check the feedback skill
    runs) and by Invoke-FieldScan.ps1 (recurrence matching).

      Get-IssueSignature      title + body -> content stems + ANCHORS (script names, Verb-Noun
                              functions, -Flags). Anchors are the strongest evidence two reports
                              are about the same thing, and they are counted apart from the words.
      Get-IssueSimilarity     pure score in [0,1] between a new report and one filed issue.
      Find-SimilarIssues      rank candidates; `likely` at/above -LikelyAt, `related` at/above
                              -RelatedAt. Pure: candidates are passed in.
      Find-IssuesMentioning   issues whose text names a given script - recurrence matching.
      Get-ToolRecurrence      per-script incident counts x filed issues -> recurrence / new candidate.
      Get-IssueCandidates     the live read: every open issue plus those closed in the last
                              -ClosedDays (a recently closed twin is a RECURRENCE, not a new defect).

    How the score is built, so it can be argued with: title words matched by overlap coefficient
    (a short report against a long one still matches), plus 0.3 when they share an anchor. Anchors are
    NOT double counted as words. Measured on real duplicates (#654/#658/#667): same-defect rewordings
    score 0.9+, while a DIFFERENT defect in the same script scores about 0.35-0.5 - shown as `related`,
    never blocking. It is advice for a human to read, not a verdict.
#>

. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

$script:DupStop = @(
    'the','and','for','with','when','not','does','doesn','without','from','into','that','this','than','then',
    'are','was','were','has','have','had','but','its','also','only','still','even','never','always','after',
    'before','while','via','can','cannot','should','would','could','issue','issues','bug','fix','error',
    'agentic','board','tool','script','scripts','skill','wrong','instead','actually','every','any','all',
    'one','two','use','uses','used','using','get','gets','make','makes','need','needs','because','about',
    'ps1','psm1','md','json','yml','yaml'
)

# Light stemming so "created/creates/creating/creation" meet: strip a plural or a verb ending. Not
# linguistics - just enough that a reworded title still overlaps. Pure.
function ConvertTo-DupStem {
    param([string]$Word)
    $w = $Word.ToLowerInvariant()
    foreach ($suf in @('ations','ation','ings','ing','ied','ies','ed','es','s','e')) {
        if ($w.Length -gt ($suf.Length + 3) -and $w.EndsWith($suf)) { return $w.Substring(0, $w.Length - $suf.Length) }
    }
    return $w
}

# Title/body -> @{ words; anchors }. Anchors: script/file names (extension dropped), Verb-Noun names
# and -Flags, lower-cased. Words: everything else in the TITLE, stemmed, stop words and anchor parts
# removed. Pure.
function Get-IssueSignature {
    param([string]$Title, [string]$Body)
    $anchors = New-Object System.Collections.Generic.HashSet[string]
    $all = "$Title`n$Body"
    foreach ($m in [regex]::Matches($all, '(?i)\b([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z][A-Za-z0-9]*)+)(?:\.(?:ps1|psm1|md|json|ya?ml))?\b')) {
        $a = $m.Groups[1].Value.ToLowerInvariant()
        # a hyphenated common word ("end-to-end", "read-only") is not a script name: an anchor is a
        # Verb-Noun / Board-Thing shape (two or more capitalised parts) or carries a file extension.
        if ($m.Value -match '\.(ps1|psm1|md|json|ya?ml)$' -or $m.Groups[1].Value -cmatch '^[A-Z][A-Za-z0-9]*(-[A-Z][A-Za-z0-9]*)+$') { [void]$anchors.Add($a) }
    }
    foreach ($m in [regex]::Matches($all, '(?<![\w-])(-[A-Z][A-Za-z]{3,})\b')) { [void]$anchors.Add($m.Groups[1].Value.ToLowerInvariant()) }

    $anchorParts = New-Object System.Collections.Generic.HashSet[string]
    foreach ($a in $anchors) { foreach ($p in ($a.TrimStart('-') -split '-')) { [void]$anchorParts.Add($p) } }

    $words = New-Object System.Collections.Generic.HashSet[string]
    $titleLower = "$Title".ToLowerInvariant()
    foreach ($m in [regex]::Matches($titleLower, '[a-z][a-z0-9]{2,}')) {
        $w = $m.Value
        if ($script:DupStop -contains $w) { continue }
        if ($anchorParts.Contains($w)) { continue }
        $s = ConvertTo-DupStem $w
        if ($s.Length -ge 3) { [void]$words.Add($s) }
    }
    return [pscustomobject]@{ words = @($words); anchors = @($anchors) }
}

# Score one candidate against a new report. Pure. Returns @{ score; sharedAnchors; sharedWords }.
function Get-IssueSimilarity {
    param([Parameter(Mandatory)]$New, [Parameter(Mandatory)]$Existing)
    $nt = "$($New.title)".Trim().ToLowerInvariant() -replace '\s+', ' '
    $et = "$($Existing.title)".Trim().ToLowerInvariant() -replace '\s+', ' '
    $a = Get-IssueSignature -Title $New.title -Body $New.body
    $b = Get-IssueSignature -Title $Existing.title -Body $Existing.body

    $sharedA = @($a.anchors | Where-Object { $b.anchors -contains $_ })
    $sharedW = @($a.words   | Where-Object { $b.words   -contains $_ })
    if ($nt -and $nt -eq $et) { return @{ score = 1.0; sharedAnchors = $sharedA; sharedWords = $sharedW } }

    # Overlap coefficient with a floor of 3 on the denominator, so a two-word title cannot match
    # everything that happens to contain those two words.
    $den = [Math]::Max(3, [Math]::Min(@($a.words).Count, @($b.words).Count))
    $t = [Math]::Min(1.0, $sharedW.Count / $den)
    $anchorBonus = 0.0
    if ($sharedA.Count -gt 0) { $anchorBonus = 0.3 }
    return @{ score = [Math]::Round([Math]::Min(1.0, $t + $anchorBonus), 3); sharedAnchors = $sharedA; sharedWords = $sharedW }
}

# Rank candidates against a new report. Pure: -Candidates is the already-fetched list of
# { number; title; body; url; state; closedAt; stateReason }.
function Find-SimilarIssues {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Body = '',
        [Parameter(Mandatory)]$Candidates,
        [double]$LikelyAt = 0.6,
        [double]$RelatedAt = 0.35
    )
    $new = [pscustomobject]@{ title = $Title; body = $Body }
    $out = @()
    foreach ($c in @($Candidates | Where-Object { $_ })) {
        $s = Get-IssueSimilarity -New $new -Existing $c
        if ($s.score -lt $RelatedAt) { continue }
        $out += [pscustomobject]@{
            number = [int]$c.number; title = "$($c.title)"; url = "$($c.url)"; state = "$($c.state)".ToUpperInvariant()
            closedAt = $c.closedAt; stateReason = "$($c.stateReason)"
            score = $s.score; level = if ($s.score -ge $LikelyAt) { 'likely' } else { 'related' }
            sharedAnchors = @($s.sharedAnchors)
        }
    }
    return @($out | Sort-Object -Property @{Expression='score';Descending=$true}, @{Expression='number';Descending=$true})
}

# Issues whose title/body NAME a script (case-insensitive, with or without .ps1), newest first. Used
# by the field scan's recurrence matching (#476). Pure.
function Find-IssuesMentioning {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)]$Candidates)
    $stem = [regex]::Escape(($Script -replace '(?i)\.ps1$', ''))
    $rx = "(?i)(?<![A-Za-z0-9-])$stem(?:\.ps1)?(?![A-Za-z0-9-])"
    return @($Candidates | Where-Object { $_ -and (("$($_.title)" -match $rx) -or ("$($_.body)" -match $rx)) } |
             Sort-Object -Property @{Expression={[int]$_.number};Descending=$true})
}

# ── Live read (through Invoke-Gh: a failed search THROWS, it never reads as "no duplicates") ──
function Get-IssueCandidates {
    param([Parameter(Mandatory)][string]$Repo, [int]$ClosedDays = 30)
    $fields = 'number,title,body,url,state,closedAt,stateReason'
    $open = @(Invoke-Gh -GhArgs @('issue', 'list', '--repo', $Repo, '--state', 'open', '--limit', '500', '--json', $fields) `
                        -What "listar los issues abiertos de $Repo" -Json -Retries 1)
    $since = (Get-Date).ToUniversalTime().AddDays(-1 * $ClosedDays)
    $closed = @(Invoke-Gh -GhArgs @('issue', 'list', '--repo', $Repo, '--state', 'closed', '--limit', '300', '--json', $fields) `
                          -What "listar los issues cerrados de $Repo" -Json -Retries 1)
    $recent = @($closed | Where-Object {
        if (-not $_.closedAt) { return $false }
        $d = if ($_.closedAt -is [datetime]) { $_.closedAt.ToUniversalTime() } else { [datetime]::Parse("$($_.closedAt)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        $d -ge $since
    })
    return @($open + $recent)
}

# Per-script incident counts (from the field scan) x the filed issues that name the script.
# $Stats: array of { tool; invocations; incidents; failures }. Only scripts with incidents are
# considered. status = 'recurrence' when a filed issue (open, or closed recently) names the script -
# the defect is already known and this is one more occurrence; 'new-candidate' when nothing filed
# mentions it. A human judges both: this only sorts. Pure.
function Get-ToolRecurrence {
    param([Parameter(Mandatory)]$Stats, [Parameter(Mandatory)]$Candidates)
    $out = @()
    foreach ($s in @($Stats | Where-Object { $_ -and [int]$_.incidents -gt 0 })) {
        $m = @(Find-IssuesMentioning -Script "$($s.tool)" -Candidates $Candidates)
        $out += [pscustomobject]@{
            tool = "$($s.tool)"; invocations = [int]$s.invocations; incidents = [int]$s.incidents; failures = [int]$s.failures
            status = if ($m.Count -gt 0) { 'recurrence' } else { 'new-candidate' }
            filed = @($m | ForEach-Object { [pscustomobject]@{ number = [int]$_.number; state = "$($_.state)".ToUpperInvariant(); stateReason = "$($_.stateReason)"; title = "$($_.title)"; url = "$($_.url)" } })
        }
    }
    return @($out | Sort-Object -Property @{Expression='incidents';Descending=$true}, @{Expression='tool'})
}
