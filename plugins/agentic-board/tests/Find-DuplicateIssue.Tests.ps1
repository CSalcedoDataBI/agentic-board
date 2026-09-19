#Requires -Modules Pester
<#  Tests for Find-DuplicateIssue.ps1 - "is this defect already filed?" (#675, #476).

    Fixtures are REAL issue titles from this repo. #654, #658 and #667 are the same defect filed
    three times ("Apply-FieldPreset reports the field as created when the creation failed", all
    closed as not planned); #661 was a duplicate of #655. The two directions matter equally:
      * a genuine duplicate must be FOUND, and
      * a DIFFERENT defect in the same script must NOT be blocked - a helper that cries duplicate
        at every report about a popular script would be switched off within a week.  #>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Find-DuplicateIssue.ps1' | Resolve-Path
    $script:LibPath    = Join-Path $PSScriptRoot '..' 'scripts' 'IssueSearch.ps1' | Resolve-Path
    . $script:LibPath

    function script:I { param([int]$N, [string]$T, [string]$S = 'CLOSED', [string]$R = 'NOT_PLANNED', [string]$B = '', $Closed = $null)
        [pscustomobject]@{ number = $N; title = $T; body = $B; url = "https://github.com/o/r/issues/$N"; state = $S; stateReason = $R; closedAt = $Closed } }

    $script:Filed = @(
        (I 654 'Apply-FieldPreset reports fields as created when field-create failed (every board is missing Type)')
        (I 658 "Apply-FieldPreset: GitHub now reserves the field name 'Type' - creation fails but is reported as created")
        (I 667 "Apply-FieldPreset reports 'created: Type' when the field creation actually failed")
        (I 661 'Board-ReviewGate returns exit 0 when the only review is a quota-blocked Copilot review')
        (I 524 'Board-Triage: -Number instead of -ProjectNum, and no -Repo to disambiguate a multi-repo board')
        (I 505 'Expert-Roles.ps1 -List hangs and never returns' 'OPEN' '')
        (I 502 'Board-Work -Start: already-integrated guard matches a bare #n mention in commit prose, not just a (#n) citation' 'OPEN' '')
        (I 480 'Publish-DocsWiki cannot publish when the wiki has never been initialised' 'OPEN' '')
    )
}

Describe 'Find-SimilarIssues - a real duplicate is FOUND' {
    It 'finds all three filings of the Apply-FieldPreset defect from a reworded report' {
        $h = @(Find-SimilarIssues -Title 'Apply-FieldPreset says the Type field was created although the creation failed' -Candidates $script:Filed)
        $likely = @($h | Where-Object level -eq 'likely').number
        $likely | Should -Contain 654
        $likely | Should -Contain 658
        $likely | Should -Contain 667
    }
    It 'finds the ReviewGate/quota duplicate from a paraphrase' {
        $h = @(Find-SimilarIssues -Title 'Board-ReviewGate passes with exit 0 when the sole review is a Copilot review blocked by quota' -Candidates $script:Filed)
        (@($h | Where-Object level -eq 'likely').number) | Should -Contain 661
    }
    It 'an identical title (any case or spacing) scores 1' {
        $h = @(Find-SimilarIssues -Title '  expert-roles.ps1 -LIST hangs   and never returns ' -Candidates $script:Filed)
        ($h | Where-Object number -eq 505).score | Should -Be 1
    }
    It 'ranks the best match first' {
        $h = @(Find-SimilarIssues -Title "Apply-FieldPreset reports created: Type when the field creation failed" -Candidates $script:Filed)
        $h[0].number | Should -Be 667
    }
    It 'reports a closed twin as such (a recurrence, not a new defect)' {
        $h = @(Find-SimilarIssues -Title 'Apply-FieldPreset reports created when the field creation failed' -Candidates $script:Filed)
        ($h | Where-Object number -eq 667).state | Should -Be 'CLOSED'
        ($h | Where-Object number -eq 667).stateReason | Should -Be 'NOT_PLANNED'
    }
    It 'a report worded in the BODY with the same script anchor still matches on title words' {
        $h = @(Find-SimilarIssues -Title 'field creation failed yet reported as created' -Body 'Seen in Apply-FieldPreset.ps1 on every board' -Candidates $script:Filed)
        (@($h | Where-Object level -eq 'likely').number) | Should -Contain 667
    }
}

Describe 'Find-SimilarIssues - a DIFFERENT defect is NOT blocked' {
    It 'another defect in the same script is at most related, never likely' {
        $h = @(Find-SimilarIssues -Title 'Apply-FieldPreset -DryRun still writes labels to the board' -Candidates $script:Filed)
        @($h | Where-Object level -eq 'likely').Count | Should -Be 0
    }
    It 'same script and same flag but a different symptom is not a duplicate' {
        $h = @(Find-SimilarIssues -Title 'Expert-Roles.ps1 -List prints the roles in random order' -Candidates $script:Filed)
        @($h | Where-Object level -eq 'likely').Count | Should -Be 0
        # ... and sharing only the script name is too weak to even be listed as related.
        @($h | Where-Object number -eq 505).Count | Should -Be 0
    }
    It 'a different gate defect does not match the quota-blocked-review one' {
        $h = @(Find-SimilarIssues -Title 'Board-ReviewGate hangs forever when the pull request has no checks' -Candidates $script:Filed)
        @($h | Where-Object level -eq 'likely').Count | Should -Be 0
    }
    It 'an unrelated report finds nothing at all' {
        @(Find-SimilarIssues -Title 'Add a dark mode to the welcome banner' -Candidates $script:Filed).Count | Should -Be 0
    }
    It 'common hyphenated words are not treated as script names' {
        (Get-IssueSignature -Title 'end-to-end read-only run' -Body '').anchors | Should -BeNullOrEmpty
    }
    It 'does not let two-word titles match everything that shares those two words' {
        $h = @(Find-SimilarIssues -Title 'gate hangs' -Candidates $script:Filed)
        @($h | Where-Object level -eq 'likely').Count | Should -Be 0
    }
}

Describe 'Get-IssueSimilarity - how the score is built' {
    It 'a shared anchor adds exactly 0.3 to the same word overlap' {
        # Same titles both times; only the BODIES differ, so the word sets are identical and the
        # score difference is the anchor bonus and nothing else.
        $with    = Get-IssueSimilarity -New ([pscustomobject]@{ title = 'loses cursor pagination'; body = 'seen in Board-Plan.ps1' }) -Existing ([pscustomobject]@{ title = 'loses cursor on long boards'; body = 'in Board-Plan.ps1 too' })
        $without = Get-IssueSimilarity -New ([pscustomobject]@{ title = 'loses cursor pagination'; body = 'seen somewhere' })          -Existing ([pscustomobject]@{ title = 'loses cursor on long boards'; body = 'elsewhere too' })
        [Math]::Round($with.score - $without.score, 3) | Should -Be 0.3
        @($with.sharedAnchors) | Should -Contain 'board-plan'
        @($without.sharedAnchors).Count | Should -Be 0
    }
    It 'a two-word title cannot claim a strong match from one shared word (denominator floor of 3)' {
        $s = Get-IssueSimilarity -New ([pscustomobject]@{ title = 'hangs forever'; body = '' }) -Existing $script:Filed[5]
        $s.score | Should -BeLessThan 0.4
    }
    It 'an identical title is exactly 1, and unrelated titles are 0' {
        (Get-IssueSimilarity -New ([pscustomobject]@{ title = 'Some Title Here'; body = '' }) -Existing ([pscustomobject]@{ title = 'some   title here'; body = '' })).score | Should -Be 1
        (Get-IssueSimilarity -New ([pscustomobject]@{ title = 'apples oranges bananas'; body = '' }) -Existing ([pscustomobject]@{ title = 'dark mode toggle'; body = '' })).score | Should -Be 0
    }
}

Describe 'Find-SimilarIssues - ranking' {
    It 'is ordered best score first' {
        $h = @(Find-SimilarIssues -Title 'Apply-FieldPreset says the Type field was created although the creation failed' -Candidates $script:Filed -RelatedAt 0.05)
        $h.Count | Should -BeGreaterThan 2
        $scores = @($h | ForEach-Object { $_.score })
        for ($i = 1; $i -lt $scores.Count; $i++) { $scores[$i] | Should -BeLessOrEqual $scores[$i - 1] }
    }
}

Describe 'Get-IssueSignature' {
    It 'extracts script names (extension dropped), Verb-Noun names and -Flags as anchors' {
        $s = Get-IssueSignature -Title 'Board-Work.ps1 -TakeOver ignores Get-BoardItems' -Body ''
        $s.anchors | Should -Contain 'board-work'
        $s.anchors | Should -Contain '-takeover'
        $s.anchors | Should -Contain 'get-boarditems'
    }
    It 'does not count anchor parts as ordinary words (no double counting)' {
        (Get-IssueSignature -Title 'Board-Work.ps1 hangs' -Body '').words | Should -Not -Contain 'work'
    }
    It 'stems created/creates so a reworded title still overlaps' {
        (ConvertTo-DupStem 'created') | Should -Be (ConvertTo-DupStem 'creates')
    }
}

Describe 'Find-IssuesMentioning - recurrence matching by script (#476)' {
    It 'finds issues naming the script, with or without .ps1, newest first' {
        $r = @(Find-IssuesMentioning -Script 'Apply-FieldPreset.ps1' -Candidates $script:Filed)
        ($r.number) | Should -Be @(667, 658, 654)
        @(Find-IssuesMentioning -Script 'Apply-FieldPreset' -Candidates $script:Filed).Count | Should -Be 3
    }
    It 'matches a mention in the BODY too' {
        $c = @((I 900 'Something else' 'OPEN' '' 'It happens when Board-Plan.ps1 runs twice'))
        @(Find-IssuesMentioning -Script 'Board-Plan.ps1' -Candidates $c).number | Should -Be @(900)
    }
    It 'does not match a longer script name that merely contains it' {
        $c = @((I 901 'Board-Plan-Extra.ps1 breaks' 'OPEN' ''))
        @(Find-IssuesMentioning -Script 'Board-Plan.ps1' -Candidates $c).Count | Should -Be 0
    }
    It 'finds nothing for a script nobody filed anything about' {
        @(Find-IssuesMentioning -Script 'Backup-Board.ps1' -Candidates $script:Filed).Count | Should -Be 0
    }
}

Describe 'Get-ToolRecurrence - incidents x filed issues (#476)' {
    It 'marks a script with a filed issue as recurrence and one without as a new candidate' {
        $stats = @(
            [pscustomobject]@{ tool = 'Apply-FieldPreset.ps1'; invocations = 5; incidents = 3; failures = 3 },
            [pscustomobject]@{ tool = 'Backup-Board.ps1';      invocations = 2; incidents = 1; failures = 1 })
        $r = @(Get-ToolRecurrence -Stats $stats -Candidates $script:Filed)
        ($r | Where-Object tool -eq 'Apply-FieldPreset.ps1').status | Should -Be 'recurrence'
        (@(($r | Where-Object tool -eq 'Apply-FieldPreset.ps1').filed).number | Sort-Object) | Should -Be @(654, 658, 667)
        ($r | Where-Object tool -eq 'Backup-Board.ps1').status | Should -Be 'new-candidate'
    }
    It 'ignores a script that had no incident at all - being used is not being broken' {
        $stats = @([pscustomobject]@{ tool = 'Apply-FieldPreset.ps1'; invocations = 9; incidents = 0; failures = 0 })
        @(Get-ToolRecurrence -Stats $stats -Candidates $script:Filed).Count | Should -Be 0
    }
    It 'lists the noisiest script first' {
        $stats = @(
            [pscustomobject]@{ tool = 'Backup-Board.ps1';      invocations = 2; incidents = 1; failures = 1 },
            [pscustomobject]@{ tool = 'Apply-FieldPreset.ps1'; invocations = 5; incidents = 4; failures = 3 })
        @(Get-ToolRecurrence -Stats $stats -Candidates $script:Filed)[0].tool | Should -Be 'Apply-FieldPreset.ps1'
    }
    It 'keeps whether the filed issue is open or closed, and why' {
        $r = @(Get-ToolRecurrence -Stats @([pscustomobject]@{ tool = 'Apply-FieldPreset.ps1'; invocations = 1; incidents = 1; failures = 1 }) -Candidates $script:Filed)
        $f = @($r[0].filed) | Where-Object number -eq 667
        $f.state | Should -Be 'CLOSED'
        $f.stateReason | Should -Be 'NOT_PLANNED'
    }
}

Describe 'Get-IssueCandidates - the live read fails LOUDLY and honours the closed window' {
    It 'returns open issues plus those closed inside the window, and drops older closed ones' {
        Mock Invoke-GhRaw {
            $now = (Get-Date).ToUniversalTime()
            if ($GhArgs -contains 'open') {
                $o = @(@{ number = 1; title = 'open one'; body = ''; url = 'u1'; state = 'OPEN'; closedAt = $null; stateReason = '' })
                return [pscustomobject]@{ Output = @(($o | ConvertTo-Json -Depth 4 -Compress)); ExitCode = 0; StdErr = '' }
            }
            $c = @(
                @{ number = 2; title = 'closed recently'; body = ''; url = 'u2'; state = 'CLOSED'; closedAt = $now.AddDays(-3).ToString('o');  stateReason = 'COMPLETED' },
                @{ number = 3; title = 'closed long ago'; body = ''; url = 'u3'; state = 'CLOSED'; closedAt = $now.AddDays(-90).ToString('o'); stateReason = 'COMPLETED' }
            )
            [pscustomobject]@{ Output = @(($c | ConvertTo-Json -Depth 4 -Compress)); ExitCode = 0; StdErr = '' }
        }
        $r = @(Get-IssueCandidates -Repo 'o/r' -ClosedDays 30)
        ($r.number | Sort-Object) | Should -Be @(1, 2)
    }
    It 'filters the closed list by closing date SERVER-SIDE (the unfiltered list is the newest 300 CREATED, and a defect created long ago but closed last week would fall off it)' {
        $script:seenClosed = ''
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'closed') { $script:seenClosed = ($GhArgs -join ' ') }
            [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' }
        }
        $null = Get-IssueCandidates -Repo 'o/r' -ClosedDays 30
        $script:seenClosed | Should -Match '--search closed:>=\d{4}-\d{2}-\d{2}'
        $day = [regex]::Match($script:seenClosed, 'closed:>=(\d{4}-\d{2}-\d{2})').Groups[1].Value
        ([datetime]::Parse($day) - (Get-Date).Date.AddDays(-30)).TotalDays | Should -BeIn @(-1, 0, 1)
    }
    It 'THROWS when the open list fills its page - "no duplicate" on a truncated list is a claim nobody checked' {
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'open') {
                $items = 1..500 | ForEach-Object { @{ number = $_; title = "t$_"; body = ''; url = 'u'; state = 'OPEN'; closedAt = $null; stateReason = '' } }
                return [pscustomobject]@{ Output = @(($items | ConvertTo-Json -Depth 4 -Compress)); ExitCode = 0; StdErr = '' }
            }
            [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' }
        }
        { Get-IssueCandidates -Repo 'o/r' } | Should -Throw -ExpectedMessage '*abiertos*limite*'
    }
    It 'THROWS when the closed list fills its page' {
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'closed') {
                $now = (Get-Date).ToUniversalTime().ToString('o')
                $items = 1..300 | ForEach-Object { @{ number = $_; title = "t$_"; body = ''; url = 'u'; state = 'CLOSED'; closedAt = $now; stateReason = 'COMPLETED' } }
                return [pscustomobject]@{ Output = @(($items | ConvertTo-Json -Depth 4 -Compress)); ExitCode = 0; StdErr = '' }
            }
            [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' }
        }
        { Get-IssueCandidates -Repo 'o/r' } | Should -Throw -ExpectedMessage '*cerrados*limite*'
    }
    It 'THROWS when ONLY the open-issues read fails - the closed read succeeding must not cover for it' {
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'open') { return [pscustomobject]@{ Output = @(); ExitCode = 1; StdErr = 'gh: HTTP 502' } }
            [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' }
        }
        { Get-IssueCandidates -Repo 'o/r' } | Should -Throw -ExpectedMessage '*abiertos*'
    }
    It 'THROWS when ONLY the closed-issues read fails' {
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'closed') { return [pscustomobject]@{ Output = @(); ExitCode = 1; StdErr = 'gh: HTTP 502' } }
            [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' }
        }
        { Get-IssueCandidates -Repo 'o/r' } | Should -Throw -ExpectedMessage '*cerrados*'
    }
    It 'THROWS when gh fails - a failed search must never read as "no duplicates"' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @(); ExitCode = 1; StdErr = 'gh: HTTP 401' } }
        { Get-IssueCandidates -Repo 'o/r' } | Should -Throw -ExpectedMessage '*listar los issues*'
    }
    It 'asks for the state reason, so a not-planned twin can be reported as such' {
        $script:seen = @()
        Mock Invoke-GhRaw { $script:seen += ($GhArgs -join ' '); [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' } }
        $null = Get-IssueCandidates -Repo 'o/r'
        ($script:seen -join "`n") | Should -Match 'stateReason'
    }
}

Describe 'the feedback skill runs the duplicate check BEFORE it files (#675)' {
    BeforeAll {
        $script:Skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'skills' 'abios-feedback' 'SKILL.md') -Raw
    }
    It 'names the helper, and does so before the first gh issue create' {
        $check  = $script:Skill.IndexOf('Find-DuplicateIssue.ps1')
        $create = $script:Skill.IndexOf('gh issue create')
        $check  | Should -BeGreaterThan -1
        $create | Should -BeGreaterThan -1
        $check  | Should -BeLessThan $create
    }
    It 'tells the agent what each exit code means, including that a failed search is not "no duplicates"' {
        $script:Skill | Should -Match 'exit 3'
        $script:Skill | Should -Match 'exit 0'
        $script:Skill | Should -Match 'exit 2'
        $script:Skill | Should -Match 'not\*\* "no duplicates"'
    }
}

Describe 'Find-DuplicateIssue.ps1 - the CLI contract the skill acts on' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:ScriptPath -Raw }
    It 'exits 3 on a probable duplicate, 2 when the search failed, 0 otherwise' {
        $script:Src | Should -Match '(?s)if \(\$likely\.Count -gt 0\) \{ exit 3 \}\s*exit 0'
        $script:Src | Should -Match '(?s)catch \{.*?exit 2'
    }
    It 'says a failed search is NOT "no duplicates"' {
        $script:Src | Should -Match "NO significa 'sin duplicados'"
    }
    It 'takes its identity from the resolver' {
        $script:Src | Should -Match 'Get-GhTokenForContext'
    }
    It 'goes through Invoke-Gh - no raw gh in the CLI or the shared functions' {
        foreach ($f in @($script:ScriptPath, $script:LibPath)) {
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'gh' }, $true)).Count | Should -Be 0
        }
    }
    It 'the shared functions have NO param block, so dot-sourcing them cannot clobber a caller' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LibPath, [ref]$null, [ref]$null)
        $ast.ParamBlock | Should -BeNullOrEmpty
    }
}
