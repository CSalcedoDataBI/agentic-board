#Requires -Modules Pester
<#  Pester tests for Board-Handoff.ps1 - the /board handoff save driver.

    Board-Handoff.ps1 is side-effecting (gh + git + file writes), so it exposes a
    dot-source guard: with $env:ABIOS_HANDOFF_DOTSOURCE set, it returns right after
    defining the pure helpers, WITHOUT the token check or any gh/git/file side
    effect. These tests exercise only those pure helpers - zero network, zero I/O. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Handoff.ps1' | Resolve-Path
    $env:ABIOS_HANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_DOTSOURCE = ''
}

Describe 'Get-HandoffBranchIssue' {
    It 'parses the issue number from an issue-<n>-slug branch' {
        Get-HandoffBranchIssue 'issue-139-build-board-handoff-save' | Should -Be 139
    }
    It 'returns 0 for a non-issue branch' {
        Get-HandoffBranchIssue 'main' | Should -Be 0
    }
    It 'returns 0 for an empty branch' {
        Get-HandoffBranchIssue '' | Should -Be 0
    }
}

Describe 'New-HandoffArchiveName (Windows-safe, colon-free)' {
    It 'produces a colon-free basic ISO-8601 UTC filename' {
        $name = New-HandoffArchiveName ([datetime]'2026-07-07T14:32:05Z')
        $name | Should -Not -Match ':'
        $name | Should -BeExactly '20260707T143205Z-handoff.md'
    }
    It 'keeps an explicit UTC DateTime stable (no double-conversion, timezone-independent)' {
        $utc  = New-HandoffArchiveName ([datetime]::new(2026,7,7,14,0,0,[DateTimeKind]::Utc))
        $utc | Should -BeExactly '20260707T140000Z-handoff.md'
    }
}

Describe 'Get-HandoffStamp (RFC3339 UTC)' {
    It 'stamps RFC3339 with a trailing Z' {
        Get-HandoffStamp ([datetime]'2026-07-07T14:32:05Z') | Should -BeExactly '2026-07-07T14:32:05Z'
    }
}

Describe 'Get-HandoffVerifiedRatio' {
    It 'counts [V] verified over total tagged claims' {
        Get-HandoffVerifiedRatio @('[V] a', '[V] b', '[?] c') | Should -Be '2/3'
    }
    It 'is 0/0 when nothing is tagged' {
        Get-HandoffVerifiedRatio @('plain line', 'another') | Should -Be '0/0'
    }
    It 'counts a leading tag after a "- " bullet' {
        Get-HandoffVerifiedRatio @('- [V] bulleted verified', '- [?] bulleted unknown') | Should -Be '1/2'
    }
    It 'ignores a mid-line tag (e.g. a gathered commit message about [V]/[?] tagging)' {
        # Regression: a commit message that literally contains "[V]/[?]" must NOT be
        # counted as two claims - only the one real leading [V] claim counts.
        $lines = @('[V] Recent commits:', '    - 55fe376 spec: [V]/[?] tagging protocol')
        Get-HandoffVerifiedRatio $lines | Should -Be '1/1'
    }
    It 'is all-verified when there are no [?]' {
        Get-HandoffVerifiedRatio @('[V] one', '[V] two') | Should -Be '2/2'
    }
}

Describe 'ConvertTo-HandoffFrontmatter' {
    It 'serializes an ordered dict between --- fences, preserving order' {
        $fm = [ordered]@{ issue = 139; repo = 'o/r'; pr = 'null' }
        $out = ConvertTo-HandoffFrontmatter $fm
        $out | Should -Match "(?s)^---.*issue: 139.*repo: o/r.*pr: null.*---$"
        ($out -split "`n")[0] | Should -Be '---'
        ($out -split "`n")[-1] | Should -Be '---'
    }
    It 'renders empty values as null' {
        $out = ConvertTo-HandoffFrontmatter ([ordered]@{ pr = '' })
        $out | Should -Match 'pr: null'
    }
}

Describe 'Format-HandoffMarkdown' {
    It 'omits sections with no content and bullet-prefixes bare lines' {
        $md = Format-HandoffMarkdown -Frontmatter '---' -Heading 'H' -GitBlock '' `
                -NextStep '[V] next' -Done @('did a thing') -OpenThreads @() -Traps @() -KeyFiles @()
        $md | Should -Match '## Next concrete step'
        $md | Should -Match '## Done this session'
        $md | Should -Match '- did a thing'
        $md | Should -Not -Match '## Open threads'
        $md | Should -Not -Match '## Traps'
        $md | Should -Not -Match '## Verified git state'
    }
    It 'does not double-prefix a line that already starts with a dash' {
        $md = Format-HandoffMarkdown -Frontmatter '---' -Heading 'H' -GitBlock '' `
                -NextStep '' -Done @('- already bulleted') -OpenThreads @() -Traps @() -KeyFiles @()
        $md | Should -Match '(?m)^- already bulleted$'
        $md | Should -Not -Match '- - already bulleted'
    }
    It 'includes the git block when provided' {
        $md = Format-HandoffMarkdown -Frontmatter '---' -Heading 'H' -GitBlock '[V] Branch: x' `
                -NextStep '' -Done @() -OpenThreads @() -Traps @() -KeyFiles @()
        $md | Should -Match '## Verified git state'
        $md | Should -Match '\[V\] Branch: x'
    }
}

Describe 'Get-HandoffBodyFromComment' {
    It 'extracts the markdown between the ```md fence and its closing ```' {
        $comment = @'
<!-- abios-handoff -->
**[abios-handoff]** session handoff.

```md
---
issue: 139
---
# Handoff
[V] next step
```
_Last saved 2026-07-07T14:00:00Z._
'@
        $body = Get-HandoffBodyFromComment $comment
        $body | Should -Match '(?m)^issue: 139$'
        $body | Should -Match '\[V\] next step'
        $body | Should -Not -Match 'Last saved'
        $body | Should -Not -Match 'abios-handoff'
    }
    It 'returns empty when there is no fenced block' {
        Get-HandoffBodyFromComment 'just some text, no fence' | Should -BeExactly ''
    }
}

Describe 'Get-HandoffFrontmatterField' {
    BeforeAll {
        $script:Md = "---`nissue: 139`nbranch: issue-139-x`npr: null`n---`n# Handoff`nbody"
    }
    It 'reads a present field' {
        Get-HandoffFrontmatterField $script:Md 'branch' | Should -Be 'issue-139-x'
    }
    It 'returns empty for an absent field' {
        Get-HandoffFrontmatterField $script:Md 'nope' | Should -BeExactly ''
    }
    It 'does not read past the closing fence (body is not frontmatter)' {
        Get-HandoffFrontmatterField $script:Md 'body' | Should -BeExactly ''
    }
    It 'returns empty when the text has no frontmatter' {
        Get-HandoffFrontmatterField "# no frontmatter`ntext" 'issue' | Should -BeExactly ''
    }
}

Describe 'Get-HandoffSection' {
    BeforeAll {
        $script:Md = @'
# Handoff
## Next concrete step
[V] do the thing
## Traps / failed approaches (do NOT repeat)
- [V] trap one
- [?] trap two
## Key files
- a.ps1
'@
    }
    It 'returns the lines under the requested heading only' {
        $t = Get-HandoffSection $script:Md 'Traps / failed approaches (do NOT repeat)'
        $t.Count | Should -Be 2
        $t[0] | Should -Match 'trap one'
        $t[1] | Should -Match 'trap two'
    }
    It 'stops at the next heading' {
        (Get-HandoffSection $script:Md 'Traps / failed approaches (do NOT repeat)') -join "`n" | Should -Not -Match 'a.ps1'
    }
    It 'returns empty for a missing section' {
        @(Get-HandoffSection $script:Md 'Nonexistent').Count | Should -Be 0
    }
}

Describe 'Get-AutoMemorySlug' {
    It 'replaces every non-alphanumeric char with a dash (matches CC project slug)' {
        Get-AutoMemorySlug 'C:\Users\Cristobal\Repos\agentic-board' | Should -BeExactly 'C--Users-Cristobal-Repos-agentic-board'
    }
    It 'leaves an all-alphanumeric string untouched' {
        Get-AutoMemorySlug 'abc123' | Should -BeExactly 'abc123'
    }
}

Describe 'Set-MemoryIndexLine (upsert)' {
    It 'appends the line when the marker is absent, preserving other lines' {
        $body = "# Memory index`n- [Other](other.md) - hook`n"
        $out = Set-MemoryIndexLine $body '(active-handoff.md)' '- [Active handoff](active-handoff.md) - resume.'
        $out | Should -Match '# Memory index'
        $out | Should -Match '\[Other\]\(other.md\)'
        $out | Should -Match '\[Active handoff\]\(active-handoff.md\)'
    }
    It 'replaces the existing marker line instead of duplicating it' {
        $body = "# Memory index`n- [Active handoff](active-handoff.md) - resume issue #1.`n"
        $out = Set-MemoryIndexLine $body '(active-handoff.md)' '- [Active handoff](active-handoff.md) - resume issue #2.'
        ([regex]::Matches($out, 'active-handoff\.md')).Count | Should -Be 1
        $out | Should -Match 'issue #2'
        $out | Should -Not -Match 'issue #1'
    }
}

Describe 'Remove-MemoryIndexLine' {
    It 'drops the marker line and keeps the rest' {
        $body = "# Memory index`n- [Active handoff](active-handoff.md) - resume.`n- [Other](other.md) - hook`n"
        $out = Remove-MemoryIndexLine $body '(active-handoff.md)'
        $out | Should -Not -Match 'active-handoff.md'
        $out | Should -Match '\[Other\]\(other.md\)'
    }
    It 'is a no-op (content-preserving) when the marker is absent' {
        $body = "# Memory index`n- [Other](other.md) - hook`n"
        (Remove-MemoryIndexLine $body '(active-handoff.md)') | Should -Match '\[Other\]\(other.md\)'
    }
}

Describe 'Add-GitignoreEntries (idempotent)' {
    It 'appends missing patterns' {
        $out = Add-GitignoreEntries "node_modules/`n" @('/HANDOFF.md', '/.handoffs/')
        $out | Should -Match '/HANDOFF.md'
        $out | Should -Match '/.handoffs/'
    }
    It 'is a no-op when all patterns already exist' {
        $body = "/HANDOFF.md`n/.handoffs/`n"
        Add-GitignoreEntries $body @('/HANDOFF.md', '/.handoffs/') | Should -BeExactly $body
    }
    It 'handles an empty starting body' {
        $out = Add-GitignoreEntries "" @('/HANDOFF.md')
        $out | Should -BeExactly "/HANDOFF.md`n"
    }
    It 'only adds the truly missing pattern' {
        $out = Add-GitignoreEntries "/HANDOFF.md`n" @('/HANDOFF.md', '/.handoffs/')
        ([regex]::Matches($out, '/HANDOFF\.md')).Count | Should -Be 1
        $out | Should -Match '/.handoffs/'
    }
}

Describe 'Get-HandoffSaveMode (#304)' {
    It 'is "linked" when an issue is set (portable comment + memo)' {
        Get-HandoffSaveMode -Issue 42 | Should -Be 'linked'
    }
    It 'a set issue wins even if -Local is also passed' {
        Get-HandoffSaveMode -Issue 42 -Local | Should -Be 'linked'
    }
    It 'is "local" when no issue but -Local opts in deliberately' {
        Get-HandoffSaveMode -Issue 0 -Local | Should -Be 'local'
    }
    It 'is "refuse" when no issue and no -Local (no silent local degrade)' {
        Get-HandoffSaveMode -Issue 0 | Should -Be 'refuse'
    }
    It 'treats a negative/unset issue as no issue' {
        Get-HandoffSaveMode -Issue -1 | Should -Be 'refuse'
    }
}

Describe 'Read-HandoffBodyFile (#419 - file-backed body parameters)' {
    BeforeAll {
        $script:TmpDir = Join-Path $TestDrive 'handoff-body'
        New-Item -ItemType Directory -Force $script:TmpDir | Out-Null
    }

    It 'reads all five sections from a JSON file' {
        $f = Join-Path $script:TmpDir 'full.json'
        @{
            NextStep    = "[V] Run the tests"
            Done        = @("[V] wrote save", "[V] wrote resume")
            OpenThreads = @("Decide on -NoMemo default")
            Traps       = @("Do not pass inline prose with /board")
            KeyFiles    = @("plugins/agentic-board/scripts/Board-Handoff.ps1")
        } | ConvertTo-Json | Set-Content -Path $f
        $bd = Read-HandoffBodyFile $f
        $bd.NextStep    | Should -BeExactly "[V] Run the tests"
        $bd.Done.Count  | Should -Be 2
        $bd.OpenThreads | Should -Contain "Decide on -NoMemo default"
        $bd.Traps       | Should -Contain "Do not pass inline prose with /board"
        $bd.KeyFiles    | Should -Contain "plugins/agentic-board/scripts/Board-Handoff.ps1"
    }

    It 'returns empty defaults for sections absent from the JSON' {
        $f = Join-Path $script:TmpDir 'partial.json'
        @{ NextStep = "[V] partial" } | ConvertTo-Json | Set-Content -Path $f
        $bd = Read-HandoffBodyFile $f
        $bd.NextStep       | Should -BeExactly "[V] partial"
        $bd.Done.Count     | Should -Be 0
        $bd.OpenThreads.Count | Should -Be 0
        $bd.Traps.Count    | Should -Be 0
        $bd.KeyFiles.Count | Should -Be 0
    }

    It 'treats slash-commands in section values as plain text (not executed)' {
        $f = Join-Path $script:TmpDir 'slashes.json'
        @{ NextStep = "[V] run /board plan then /knowledge add"; Done = @("/scan found nothing") } |
            ConvertTo-Json | Set-Content -Path $f
        $bd = Read-HandoffBodyFile $f
        $bd.NextStep | Should -Match '/board'
        $bd.NextStep | Should -Match '/knowledge'
        $bd.Done     | Should -Contain "/scan found nothing"
    }

    It 'throws when the file does not exist' {
        { Read-HandoffBodyFile (Join-Path $script:TmpDir 'missing.json') } | Should -Throw "*does not exist*"
    }

    It 'throws when the path is a directory, not a file' {
        { Read-HandoffBodyFile $script:TmpDir } | Should -Throw "*does not exist*"
    }

    It 'tracks presence per field: present (even empty) is distinguishable from absent' {
        $f = Join-Path $script:TmpDir 'presence.json'
        # Done present-but-empty, NextStep present, the other three absent.
        '{ "NextStep": "[V] only step", "Done": [] }' | Set-Content -Path $f
        $bd = Read-HandoffBodyFile $f
        $bd.Present.NextStep    | Should -BeTrue
        $bd.Present.Done        | Should -BeTrue   # explicitly empty MUST override inline
        $bd.Done.Count          | Should -Be 0
        $bd.Present.OpenThreads | Should -BeFalse  # absent falls back to inline/default
        $bd.Present.Traps       | Should -BeFalse
        $bd.Present.KeyFiles    | Should -BeFalse
    }

    It 'counts a JSON null field as present, normalized to the empty default' {
        $f = Join-Path $script:TmpDir 'nullfield.json'
        '{ "NextStep": null }' | Set-Content -Path $f
        $bd = Read-HandoffBodyFile $f
        $bd.Present.NextStep | Should -BeTrue
        $bd.NextStep         | Should -BeExactly ""
    }
}
