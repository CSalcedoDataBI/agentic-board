#Requires -Modules Pester
<#  Tests for Expert-RunVerify.ps1 — the completion check that proves a run wrote its evidence
    instead of asserting it did (#532, part of #526).

    Pure core behind ABIOS_EXPERTRUNVERIFY_DOTSOURCE. Every test operates on the artifact
    content directly; no gh/network access needed.

    Design: each guard is verified by reintroducing its exact defect and confirming the test
    goes red. "A green suite proves nothing on its own" — each check must be falsifiable. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-RunVerify.ps1' | Resolve-Path
    $env:ABIOS_EXPERTRUNVERIFY_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTRUNVERIFY_DOTSOURCE = ''

    $script:Marker = '[abios-evidence]'

    # Fixtures: minimal valid content for each artifact.
    $script:GoodFile    = "# $($script:Marker) #99 — something`n`n<!-- $($script:Marker) -->`n## Evidence`n| test | cmd | PASS | ok |`n"
    $script:GoodPrBody  = "Closes #99`n`n<!-- $($script:Marker) -->`n## Evidence`n..."
    $script:GoodComment = "<!-- $($script:Marker) -->`n## Evidence`n| test | cmd | PASS | ok |`n"
}

Describe 'Test-RunArtifactsComplete — a run that wrote nothing is INCOMPLETE (#532)' {
    It 'reports INCOMPLETE when all three artifacts are absent' {
        $r = Test-RunArtifactsComplete -EvidenceFileContent '' -PrBodyContent '' -IssueCommentBodies @()
        $r.complete | Should -BeFalse
        $r.verdict  | Should -Be 'INCOMPLETE'
    }

    It 'lists all three missing artifacts at once, not just the first' {
        $r = Test-RunArtifactsComplete -EvidenceFileContent '' -PrBodyContent '' -IssueCommentBodies @()
        @($r.missing).Count | Should -Be 3
    }
}

Describe 'Test-RunArtifactsComplete — each artifact is named when missing' {
    It 'names the evidence file when it is absent' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent '' `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain 'evidence/<issue>.md (file missing, marker absent, or no substantive content)'
    }

    It 'names the PR body block when the body has no marker' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       'Closes #99' `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain '[abios-evidence] block or link stub in PR body'
    }

    It 'names the issue comment when no comment carries the marker' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @()
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain '[abios-evidence] comment on the issue'
    }
}

Describe 'Test-RunArtifactsComplete — COMPLETE only when all three are present' {
    It 'reports COMPLETE when all three artifacts carry the marker' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeTrue
        $r.verdict  | Should -Be 'COMPLETE'
        @($r.missing).Count | Should -Be 0
    }

    It 'accepts a comment list with multiple entries when at least one has the marker' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @('CI verde', $script:GoodComment, 'lgtm')
        $r.complete | Should -BeTrue
    }
}

Describe 'Test-RunArtifactsComplete — fails closed (unreadable = missing, not assumed present)' {
    It 'null evidence file content is treated as missing' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $null `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain 'evidence/<issue>.md (file missing, marker absent, or no substantive content)'
    }

    It 'whitespace-only evidence file content is treated as missing' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent "   `n  " `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain 'evidence/<issue>.md (file missing, marker absent, or no substantive content)'
    }

    It 'a non-empty PR body without the marker is treated as missing' {
        # "Closes #532" is the exact PR body the first autonomous runs left — it is not evidence.
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       'Closes #532' `
            -IssueCommentBodies  @($script:GoodComment)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain '[abios-evidence] block or link stub in PR body'
    }

    It 'ordinary PR chatter in the comment list is not an evidence comment' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @('CI verde', 'lgtm', 'gracias!')
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain '[abios-evidence] comment on the issue'
    }

    It 'an empty comment array (null-propagated) is treated as no comments' {
        $r = Test-RunArtifactsComplete `
            -EvidenceFileContent $script:GoodFile `
            -PrBodyContent       $script:GoodPrBody `
            -IssueCommentBodies  @($null)
        $r.complete | Should -BeFalse
        $r.missing  | Should -Contain '[abios-evidence] comment on the issue'
    }
}

Describe 'Format-RunVerifyVerdict' {
    It 'says COMPLETE for a complete run' {
        $r = @{ complete = $true; missing = @(); verdict = 'COMPLETE' }
        Format-RunVerifyVerdict -Result $r | Should -Match '(?i)COMPLETE'
    }

    It 'says INCOMPLETE for a run that missed evidence' {
        $r = @{ complete = $false; missing = @('artifact-a'); verdict = 'INCOMPLETE' }
        Format-RunVerifyVerdict -Result $r | Should -Match '(?i)INCOMPLETE'
    }

    It 'lists each missing artifact by name' {
        $r = @{ complete = $false; missing = @('artifact-a', 'artifact-b'); verdict = 'INCOMPLETE' }
        $v = Format-RunVerifyVerdict -Result $r
        $v | Should -Match 'artifact-a'
        $v | Should -Match 'artifact-b'
    }

    It 'tells the run what to do next (actionable verdict, not a bare label)' {
        $r = @{ complete = $false; missing = @('something'); verdict = 'INCOMPLETE' }
        Format-RunVerifyVerdict -Result $r | Should -Match '(?i)record'
    }
}

Describe 'Expert-RunVerify CLI — the evidence file is resolved from the WORKING repo (#532)' {
    # Found in review. $PSScriptRoot is <repo>/plugins/agentic-board/scripts only in this checkout;
    # installed, the script sits in the plugin cache, so walking three levels up lands in the cache
    # and evidence/<issue>.md is never found. A check that always says INCOMPLETE is as useless as
    # one that always says COMPLETE. Asserted on the source, because the CLI half sits below the
    # dot-source guard and cannot be invoked without a repo + network.

    BeforeAll { $script:Src = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'scripts' 'Expert-RunVerify.ps1') }

    It 'asks git for the working repo root' {
        $script:Src | Should -Match 'git rev-parse --show-toplevel'
    }
    It 'falls back to the current directory rather than to a script-relative path' {
        $script:Src | Should -Match 'Get-Location'
    }
    It 'never derives the repo root by walking up from the script location' {
        # The exact defect: Join-Path $PSScriptRoot '..' '..' '..'
        $script:Src | Should -Not -Match "PSScriptRoot\s+'\.\.'\s+'\.\.'\s+'\.\.'"
    }
}

Describe 'Evidence once + links (#570)' {
    BeforeAll {
        $script:FullBlock = "<!-- [abios-evidence] -->`n## Evidence`n| Test | Command | Result | Detail |`n| a | b | PASS | c |"
        $script:Stub      = "<!-- [abios-evidence] -->`n## Evidence`n`nFull evidence (single source of truth): [evidence/42.md](https://github.com/o/r/blob/b/evidence/42.md)"
    }

    It 'the link stub satisfies the PR-body and issue-comment requirements' {
        $r = Test-RunArtifactsComplete -EvidenceFileContent $script:FullBlock -PrBodyContent $script:Stub `
                -IssueCommentBodies @($script:Stub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeTrue
    }
    It 'a BARE marker with neither link nor block is a stamp, not evidence - INCOMPLETE' {
        $bare = '<!-- [abios-evidence] -->'
        $r = Test-RunArtifactsComplete -EvidenceFileContent $script:FullBlock -PrBodyContent $bare `
                -IssueCommentBodies @($bare) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
        @($r.missing).Count | Should -Be 2
    }
    It 'a pre-#570 full block in the PR body stays valid (backward compatible)' {
        $r = Test-RunArtifactsComplete -EvidenceFileContent $script:FullBlock -PrBodyContent $script:FullBlock `
                -IssueCommentBodies @($script:FullBlock) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeTrue
    }
    It 'without -EvidenceRef the old marker-only behavior holds' {
        $bare = '<!-- [abios-evidence] -->'
        (Test-RunArtifactsComplete -EvidenceFileContent $script:FullBlock -PrBodyContent $bare -IssueCommentBodies @($bare)).complete | Should -BeTrue
    }
    It 'the FILE must still carry the real marker - a stub cannot vouch for a missing source of truth' {
        $r = Test-RunArtifactsComplete -EvidenceFileContent '' -PrBodyContent $script:Stub `
                -IssueCommentBodies @($script:Stub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
    }
}

Describe 'Round-1 closures on the evidence-link mode (#570)' {
    It 'a stub pointing at ANOTHER issue''s file does not pass for this one' {
        $wrongStub = "<!-- [abios-evidence] -->`n## Evidence`n`nFull evidence (single source of truth): [evidence/99.md](x)"
        $full = "<!-- [abios-evidence] -->`n## Evidence`n| Test | Command | Result | Detail |`n| a | b | PASS | c |"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $full -PrBodyContent $wrongStub `
                -IssueCommentBodies @($wrongStub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
    }
    It 'marker + heading with no link is NOT a legacy block - the table header is the signature' {
        $headingOnly = "<!-- [abios-evidence] -->`n## Evidence"
        $full = "<!-- [abios-evidence] -->`n## Evidence`n| Test | Command | Result | Detail |`n| a | b | PASS | c |"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $full -PrBodyContent $headingOnly `
                -IssueCommentBodies @($headingOnly) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
    }
    It 'a marker-only FILE cannot anchor the pointers - the source of truth needs substance' {
        $stub = "<!-- [abios-evidence] -->`nFull evidence (single source of truth): evidence/42.md"
        $r = Test-RunArtifactsComplete -EvidenceFileContent '<!-- [abios-evidence] -->' -PrBodyContent $stub `
                -IssueCommentBodies @($stub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
        $r.missing | Should -Contain 'evidence/<issue>.md (file missing, marker absent, or no substantive content)'
    }
    It 'a hand-authored evidence file with sections (no generated table) still counts as substance' {
        $hand = "# [abios-evidence] #42`n## What was tested`ntexto`n## Review`nmas texto"
        $stub = "<!-- [abios-evidence] -->`nFull evidence: evidence/42.md"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $hand -PrBodyContent $stub `
                -IssueCommentBodies @($stub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeTrue
    }
}

Describe 'Round-2 closures (#570)' {
    It 'the link stub written INTO the evidence file is a circle with nothing inside - INCOMPLETE' {
        $stub = "<!-- [abios-evidence] -->`n## Evidence`n`n**Summary:** 1 passed / 0 failed`n`nFull evidence (single source of truth): ``evidence/42.md``"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $stub -PrBodyContent $stub `
                -IssueCommentBodies @($stub) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
    }
    It 'a suffixed wrong path (evidence/42.md.bak) is not a reference to evidence/42.md' {
        $wrong = "<!-- [abios-evidence] -->`nFull evidence: evidence/42.md.bak"
        $full = "<!-- [abios-evidence] -->`n## Evidence`n| Test | Command | Result | Detail |`n| a | b | PASS | c |"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $full -PrBodyContent $wrong `
                -IssueCommentBodies @($wrong) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeFalse
    }
    It 'a markdown link with anchor or closing paren still matches the exact path' {
        $ok = "<!-- [abios-evidence] -->`nFull evidence: [evidence/42.md](https://github.com/o/r/blob/b/evidence/42.md)"
        $full = "<!-- [abios-evidence] -->`n## Evidence`n| Test | Command | Result | Detail |`n| a | b | PASS | c |"
        $r = Test-RunArtifactsComplete -EvidenceFileContent $full -PrBodyContent $ok `
                -IssueCommentBodies @($ok) -EvidenceRef 'evidence/42.md'
        $r.complete | Should -BeTrue
    }
}
