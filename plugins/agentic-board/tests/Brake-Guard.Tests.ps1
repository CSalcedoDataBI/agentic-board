#Requires -Modules Pester
<#  Tests for Brake-Guard.ps1 — the irreversible brake as a mechanical control (#440 / #516).

    The defect these guard against: the brake used to be a paragraph in the launch briefing, and
    an observed run merged its own PR while the tool printed "Brake ARMED". So the tests that
    matter are the ones asserting a REFUSAL happens, not that a string was rendered. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Brake-Guard.ps1' | Resolve-Path
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = $null

    $script:AllIrr = @('merge','deploy','refresh','publish','delete')
}

Describe 'Test-IsBrakedCommand — the merge paths that actually happened (#440)' {
    It 'denies the exact command the observed run used' {
        Test-IsBrakedCommand -Command 'gh pr merge 490 --squash --delete-branch' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies the tool''s own merge script' {
        Test-IsBrakedCommand -Command 'pwsh plugins/agentic-board/scripts/Board-Merge.ps1 -PR 490' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies the REST merge endpoint used directly' {
        Test-IsBrakedCommand -Command 'gh api --method PUT repos/o/r/pulls/12/merge' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies regardless of spacing and casing' {
        Test-IsBrakedCommand -Command "GH   PR`tMERGE  12" -Irreversible $script:AllIrr | Should -Be 'merge'
    }
    It 'treats a newline as a command separator, not as whitespace inside one command' {
        # Deliberate: in a shell a newline ENDS a command. Folding it into a space is what let a
        # dry-run on one line vouch for a merge on the next.
        Test-IsBrakedCommand -Command "git status`ngh pr merge 12" -Irreversible $script:AllIrr | Should -Be 'merge'
    }
}

Describe 'Test-IsBrakedCommand — the other irreversible verbs' {
    It 'denies a release publish'  { Test-IsBrakedCommand -Command 'gh release create v1.0' -Irreversible $script:AllIrr | Should -Be 'publish' }
    It 'denies npm publish'        { Test-IsBrakedCommand -Command 'npm publish --access public' -Irreversible $script:AllIrr | Should -Be 'publish' }
    It 'denies a deploy'           { Test-IsBrakedCommand -Command 'wrangler deploy' -Irreversible $script:AllIrr | Should -Be 'deploy' }
    It 'denies a repo delete'      { Test-IsBrakedCommand -Command 'gh repo delete o/r --yes' -Irreversible $script:AllIrr | Should -Be 'delete' }
    It 'denies a remote branch delete' { Test-IsBrakedCommand -Command 'git push origin --delete feature' -Irreversible $script:AllIrr | Should -Be 'delete' }
    It 'denies a dataset refresh'  { Test-IsBrakedCommand -Command 'az rest --method post --url https://api.fabric/refreshes' -Irreversible $script:AllIrr | Should -Be 'refresh' }
}

Describe 'Test-IsBrakedCommand — must NOT block the work the run has to do' {
    # Over-blocking is how a safety control gets switched off for being annoying. These are the
    # commands the autonomous run legitimately issues all day.
    It 'allows opening a PR'        { Test-IsBrakedCommand -Command 'gh pr create --fill' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows viewing a PR'        { Test-IsBrakedCommand -Command 'gh pr view 490 --json state' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows the review gate'     { Test-IsBrakedCommand -Command 'pwsh scripts/Board-ReviewGate.ps1 -PR 490' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows a normal push'       { Test-IsBrakedCommand -Command 'git push -u origin issue-516-x' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows a local git merge of main into the branch' {
        Test-IsBrakedCommand -Command 'git merge origin/main' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
    }
    It 'allows running tests'       { Test-IsBrakedCommand -Command 'pwsh -c Invoke-Pester' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows deleting a local file' { Test-IsBrakedCommand -Command 'rm ./tmp.txt' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
}

Describe 'Test-IsBrakedCommand — the contract decides, not the guard' {
    It 'allows a merge when the contract does not mark merge irreversible' {
        Test-IsBrakedCommand -Command 'gh pr merge 490' -Irreversible @('deploy') | Should -BeNullOrEmpty
    }
    It 'allows everything when the irreversible list is empty' {
        Test-IsBrakedCommand -Command 'gh pr merge 490' -Irreversible @() | Should -BeNullOrEmpty
    }
    It 'denies merge but allows deploy when only merge is braked' {
        Test-IsBrakedCommand -Command 'gh pr merge 490'  -Irreversible @('merge') | Should -Be 'merge'
        Test-IsBrakedCommand -Command 'wrangler deploy'  -Irreversible @('merge') | Should -BeNullOrEmpty
    }
    It 'is case-insensitive about the contract vocabulary' {
        Test-IsBrakedCommand -Command 'gh pr merge 490' -Irreversible @('MERGE') | Should -Be 'merge'
    }
}

Describe 'Test-IsBrakedCommand — a preview mutates nothing' {
    It 'allows the merge script in -DryRun' {
        Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490 -DryRun' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
    }
    It 'allows -WhatIf' {
        Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490 -WhatIf' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
    }
    It 'still denies without the preview flag' {
        Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490' -Irreversible $script:AllIrr | Should -Be 'merge'
    }
}

Describe 'Test-IsBrakedCommand — bypasses found by external review (round 1)' {
    # Every case here was a working bypass of the first cut of this guard. They are the reason
    # the classifier judges per SEGMENT and protects its own marker.

    Context 'a dry-run token must not vouch for the rest of the command line' {
        It 'denies a real merge hiding behind a dry-run echo' {
            Test-IsBrakedCommand -Command 'echo --dry-run; gh pr merge 490' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies a real merge after a genuine dry-run of something else' {
            Test-IsBrakedCommand -Command 'npm publish --dry-run && gh pr merge 490' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies across a newline-separated script' {
            Test-IsBrakedCommand -Command "pwsh Board-Merge.ps1 -PR 1 -DryRun`ngh pr merge 490" -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies across a pipe' {
            Test-IsBrakedCommand -Command 'echo --dry-run | gh pr merge 490' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'still allows a genuinely preview-only command line' {
            Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490 -DryRun' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'still allows several preview-only segments' {
            Test-IsBrakedCommand -Command 'git status; pwsh Board-Merge.ps1 -PR 490 -DryRun' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
    }

    Context 'the run must not be able to disarm itself' {
        It 'denies deleting the marker' {
            Test-IsBrakedCommand -Command 'rm .agentic-board/brake-armed.json' -Irreversible $script:AllIrr |
                Should -Be 'tamper'
        }
        It 'denies deleting it with the PowerShell verb' {
            Test-IsBrakedCommand -Command 'Remove-Item .agentic-board\brake-armed.json -Force' -Irreversible $script:AllIrr |
                Should -Be 'tamper'
        }
        It 'denies overwriting it' {
            Test-IsBrakedCommand -Command 'echo {} > .agentic-board/brake-armed.json' -Irreversible $script:AllIrr |
                Should -Be 'tamper'
        }
        It 'denies wiping the whole state directory' {
            Test-IsBrakedCommand -Command 'rm -rf .agentic-board' -Irreversible $script:AllIrr |
                Should -Be 'tamper'
        }
        It 'denies tampering even when the contract brakes on nothing — the marker is not the contract''s to disable' {
            Test-IsBrakedCommand -Command 'rm .agentic-board/brake-armed.json' -Irreversible @() |
                Should -Be 'tamper'
        }
        It 'still allows deleting an unrelated file in the state directory' {
            Test-IsBrakedCommand -Command 'rm .agentic-board/briefing-99.txt' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
    }

    Context 'the merge endpoint is blocked by endpoint, not by client' {
        It 'denies curl against the REST merge endpoint' {
            Test-IsBrakedCommand -Command 'curl -X PUT https://api.github.com/repos/o/r/pulls/12/merge' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies Invoke-RestMethod against it' {
            Test-IsBrakedCommand -Command 'Invoke-RestMethod -Method Put -Uri https://api.github.com/repos/o/r/pulls/12/merge' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies python/requests against it' {
            Test-IsBrakedCommand -Command 'python -c "requests.put(''https://api.github.com/repos/o/r/pulls/12/merge'')"' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'still denies through gh api' {
            Test-IsBrakedCommand -Command 'gh api --method PUT repos/o/r/pulls/12/merge' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
    }
}

Describe 'Test-IsBrakedCommand — bypasses found by external review (round 2)' {
    Context 'shell quoting must not hide the subcommand' {
        It 'denies a quoted subcommand' {
            Test-IsBrakedCommand -Command "gh pr 'merge' 490" -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies double-quoted fragments' {
            Test-IsBrakedCommand -Command 'gh "pr" "merge" 490' -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies a fully quoted invocation' {
            Test-IsBrakedCommand -Command "'gh' 'pr' 'merge' 490" -Irreversible $script:AllIrr | Should -Be 'merge'
        }
    }

    Context 'indirection through a variable is refused rather than guessed at' {
        # A value the shell only produces at runtime is invisible to string matching. An
        # autonomous run has no legitimate need to reach gh through a variable, so refusing is
        # the safe side of a call this guard genuinely cannot make.
        It 'denies a variable subcommand in bash form' {
            Test-IsBrakedCommand -Command 'gh pr $verb 490' -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies a variable subcommand in cmd form' {
            Test-IsBrakedCommand -Command 'gh pr %verb% 490' -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies a variable straight after gh' {
            Test-IsBrakedCommand -Command 'gh $sub merge 490' -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'still allows an ordinary gh read with a variable argument' {
            Test-IsBrakedCommand -Command 'gh issue view $n --repo o/r' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-IsBrakedCommand — bypasses found by external review (round 3)' {
    Context 'a line continuation is one command, not two' {
        It 'denies a bash backslash continuation' {
            Test-IsBrakedCommand -Command "gh pr \`nmerge 490" -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies a PowerShell backtick continuation' {
            Test-IsBrakedCommand -Command "gh pr ```nmerge 490" -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies a continuation with trailing spaces before the newline' {
            Test-IsBrakedCommand -Command "gh pr \   `n   merge 490" -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'still treats a PLAIN newline as a separator' {
            # The continuation fix must not undo the round-1 fix it sits next to.
            Test-IsBrakedCommand -Command "pwsh Board-Merge.ps1 -PR 1 -DryRun`ngh pr merge 490" -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
    }
}

Describe 'Test-IsBrakedCommand — bypasses found by external review (round 4)' {
    Context 'a preview claim is only honoured from something that can preview' {
        It 'denies a REST merge carrying a dry-run token in an unrelated argument' {
            Test-IsBrakedCommand -Command 'curl -H "X-Test: --dry-run" -X PUT https://api.github.com/repos/o/r/pulls/12/merge' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'denies gh pr merge with a bolted-on dry-run token it does not support' {
            Test-IsBrakedCommand -Command 'gh pr merge 490 --dry-run' -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'still allows the tool''s own script in -DryRun' {
            Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490 -DryRun' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'still allows npm publish --dry-run' {
            Test-IsBrakedCommand -Command 'npm publish --dry-run' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
        }
    }

    Context 'every spelling of the same destructive request' {
        It 'denies gh api --method=DELETE' {
            Test-IsBrakedCommand -Command 'gh api --method=DELETE repos/o/r/issues/1' -Irreversible $script:AllIrr |
                Should -Be 'delete'
        }
        It 'denies gh api -X DELETE' {
            Test-IsBrakedCommand -Command 'gh api -X DELETE repos/o/r/issues/1' -Irreversible $script:AllIrr |
                Should -Be 'delete'
        }
        It 'denies the refspec form of a remote branch delete' {
            Test-IsBrakedCommand -Command 'git push origin :feature-x' -Irreversible $script:AllIrr |
                Should -Be 'delete'
        }
        It 'does NOT read a push to main as an ordinary refspec (#542)' {
            # This test used to assert the opposite, and that assertion WAS the gap: it was written
            # to prove the delete pattern did not over-match, and in doing so it pinned
            # `HEAD:main` as allowed. Pushing to the default branch is a merge by this file's own
            # definition; it is only "ordinary" from the delete pattern's point of view.
            Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'still allows a refspec onto an ordinary branch' {
            # What the original test meant to guard: the delete pattern must not eat a normal
            # refspec push.
            Test-IsBrakedCommand -Command 'git push origin HEAD:feature-x' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'still allows a plain push' {
            Test-IsBrakedCommand -Command 'git push -u origin issue-516-x' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'Read-BrakeMarker — an emptied marker is tampering, not permission' {
    It 'treats an empty irreversible list as the full vocabulary' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("brake-empty-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir '.agentic-board') -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $dir '.agentic-board/brake-armed.json') -Value '{"issue":516,"irreversible":[]}'
            $m = Read-BrakeMarker -StartDir $dir
            $m.emptied | Should -BeTrue
            @($m.irreversible) | Should -Contain 'merge'
            Test-IsBrakedCommand -Command 'gh pr merge 490' -Irreversible $m.irreversible | Should -Be 'merge'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-IsBrakedCommand — empty input' {
    It 'allows an empty command'      { Test-IsBrakedCommand -Command ''    -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
    It 'allows a whitespace command'  { Test-IsBrakedCommand -Command '   ' -Irreversible $script:AllIrr | Should -BeNullOrEmpty }
}

Describe 'Read-BrakeMarker — only an armed worktree is affected' {
    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("brake-" + [Guid]::NewGuid().ToString('N'))
        $script:Armed   = Join-Path $script:Root 'armed'
        $script:Plain   = Join-Path $script:Root 'plain'
        $script:Nested  = Join-Path $script:Armed 'src/deep/nested'
        New-Item -ItemType Directory -Path (Join-Path $script:Armed '.agentic-board') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Plain  -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Armed '.agentic-board/brake-armed.json') `
            -Value (New-BrakeMarkerJson -Issue 516 -Irreversible @('merge') -ArmedAt '2026-07-30 10:00:00')
    }
    # Guarded: if BeforeAll failed, $script:Root is empty and an unguarded Remove-Item resolves to
    # the filesystem root. Never hand a delete a path you have not checked.
    AfterAll {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'finds the marker in the worktree root' {
        (Read-BrakeMarker -StartDir $script:Armed).issue | Should -Be 516
    }
    It 'finds it from a nested subdirectory (walks up)' {
        (Read-BrakeMarker -StartDir $script:Nested).issue | Should -Be 516
    }
    It 'carries the contract list through' {
        (Read-BrakeMarker -StartDir $script:Armed).irreversible | Should -Be @('merge')
    }
    It 'returns nothing for an ordinary directory — a human session is never touched' {
        Read-BrakeMarker -StartDir $script:Plain | Should -BeNullOrEmpty
    }
    It 'returns nothing for an empty path' {
        Read-BrakeMarker -StartDir '' | Should -BeNullOrEmpty
    }
    It 'treats a CORRUPT marker as armed — a broken safety file is not a licence to merge' {
        $bad = Join-Path $script:Root 'bad'
        New-Item -ItemType Directory -Path (Join-Path $bad '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bad '.agentic-board/brake-armed.json') -Value '{ not json'
        $m = Read-BrakeMarker -StartDir $bad
        $m           | Should -Not -BeNullOrEmpty
        $m.unreadable| Should -BeTrue
        @($m.irreversible) | Should -Contain 'merge'
    }
}

Describe 'New-BrakeMarkerJson' {
    It 'records the issue and the contract list' {
        $j = New-BrakeMarkerJson -Issue 42 -Irreversible @('merge','deploy') | ConvertFrom-Json
        $j.issue | Should -Be 42
        @($j.irreversible) | Should -Be @('merge','deploy')
    }
    It 'falls back to the full vocabulary rather than arming nothing' {
        $j = New-BrakeMarkerJson -Issue 42 -Irreversible @() | ConvertFrom-Json
        @($j.irreversible) | Should -Contain 'merge'
    }
    It 'lowercases the vocabulary so the guard matches it' {
        $j = New-BrakeMarkerJson -Issue 42 -Irreversible @('MERGE') | ConvertFrom-Json
        @($j.irreversible) | Should -Be @('merge')
    }
}

Describe 'Set-BrakeArmedState — the marker must follow the contract in BOTH directions' {
    BeforeAll {
        $script:SRoot = Join-Path ([IO.Path]::GetTempPath()) ("brakearm-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SRoot -Force | Out-Null
    }
    AfterAll {
        if ($script:SRoot -and (Test-Path -LiteralPath $script:SRoot)) {
            Remove-Item -LiteralPath $script:SRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'arms a fresh worktree, creating the state directory' {
        $wt = Join-Path $script:SRoot 'fresh'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 516 -Irreversible @('merge') | Should -Be 'armed'
        (Read-BrakeMarker -StartDir $wt).issue | Should -Be 516
    }

    It 'DISARMS a reused worktree that still carries a previous run''s marker' {
        # The round-2 finding: without this, the hook keeps refusing merges for a run whose
        # contract no longer brakes on them, while the launcher prints 'Brake OFF'.
        $wt = Join-Path $script:SRoot 'reused'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 440 -Irreversible @('merge') | Should -Be 'armed'
        Read-BrakeMarker -StartDir $wt | Should -Not -BeNullOrEmpty

        Set-BrakeArmedState -WorkPath $wt -Armed $false | Should -Be 'disarmed'
        Read-BrakeMarker -StartDir $wt | Should -BeNullOrEmpty
    }

    It 'reports nothing to do when disarming an already-unarmed worktree' {
        $wt = Join-Path $script:SRoot 'never-armed'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $false | Should -Be 'none'
    }

    It 're-arming overwrites the previous run''s marker rather than stacking on it' {
        $wt = Join-Path $script:SRoot 'rearm'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 440 -Irreversible @('merge') | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 516 -Irreversible @('merge','deploy') | Out-Null
        $m = Read-BrakeMarker -StartDir $wt
        $m.issue | Should -Be 516
        @($m.irreversible) | Should -Be @('merge','deploy')
    }
}

Describe 'New-BrakeDenyJson — the payload the hook contract requires' {
    It 'emits the exact PreToolUse deny shape' {
        $o = New-BrakeDenyJson -Action 'merge' -Issue 516 | ConvertFrom-Json
        $o.hookSpecificOutput.hookEventName      | Should -Be 'PreToolUse'
        $o.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $o.hookSpecificOutput.permissionDecisionReason | Should -Match 'BRAKE'
    }
    It 'names the issue so the human can find the run' {
        (New-BrakeDenyJson -Action 'merge' -Issue 516 | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason |
            Should -Match '#516'
    }
    It 'tells the agent not to route around the control' {
        (New-BrakeDenyJson -Action 'merge' | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason |
            Should -Match 'do not look for another way'
    }
    It 'explains itself when the marker was unreadable' {
        (New-BrakeDenyJson -Action 'merge' -Unreadable | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason |
            Should -Match 'unreadable'
    }
}

Describe 'Brake-PreToolUseHook — end to end through the real hook contract' {
    BeforeAll {
        $script:Hook = Join-Path $PSScriptRoot '..' 'scripts' 'Brake-PreToolUseHook.ps1' | Resolve-Path
        $script:HRoot  = Join-Path ([IO.Path]::GetTempPath()) ("brakehook-" + [Guid]::NewGuid().ToString('N'))
        $script:HArmed = Join-Path $script:HRoot 'armed'
        $script:HPlain = Join-Path $script:HRoot 'plain'
        New-Item -ItemType Directory -Path (Join-Path $script:HArmed '.agentic-board') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:HPlain -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:HArmed '.agentic-board/brake-armed.json') `
            -Value (New-BrakeMarkerJson -Issue 516 -Irreversible @('merge','publish'))

        # Feed a payload through the hook exactly as Claude Code would: JSON on stdin.
        function script:Invoke-Hook([string]$Tool, [string]$Command, [string]$Cwd) {
            $payload = @{
                hook_event_name = 'PreToolUse'
                tool_name       = $Tool
                cwd             = $Cwd
                tool_input      = @{ command = $Command }
            } | ConvertTo-Json -Depth 5 -Compress
            return ($payload | pwsh -NoProfile -File $script:Hook | Out-String).Trim()
        }
    }
    AfterAll {
        if ($script:HRoot -and (Test-Path -LiteralPath $script:HRoot)) {
            Remove-Item -LiteralPath $script:HRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'DENIES the merge inside an armed worktree' {
        $out = script:Invoke-Hook 'Bash' 'gh pr merge 490 --squash' $script:HArmed
        $out | Should -Not -BeNullOrEmpty
        ($out | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }
    It 'DENIES it through the PowerShell tool too' {
        $out = script:Invoke-Hook 'PowerShell' 'gh pr merge 490' $script:HArmed
        ($out | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }
    It 'stays silent for the same command in an ordinary directory' {
        script:Invoke-Hook 'Bash' 'gh pr merge 490 --squash' $script:HPlain | Should -BeNullOrEmpty
    }
    It 'stays silent for harmless work inside the armed worktree' {
        script:Invoke-Hook 'Bash' 'git status' $script:HArmed | Should -BeNullOrEmpty
    }
    It 'ignores tools that cannot execute a command' {
        script:Invoke-Hook 'Read' 'gh pr merge 490' $script:HArmed | Should -BeNullOrEmpty
    }
    It 'denies a publish because this contract brakes on it' {
        ($(script:Invoke-Hook 'Bash' 'gh release create v9' $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
            Should -Be 'deny'
    }
    It 'allows a deploy because this contract does NOT brake on it' {
        script:Invoke-Hook 'Bash' 'wrangler deploy' $script:HArmed | Should -BeNullOrEmpty
    }
    It 'DENIES the composite command that hid a merge behind a dry-run token' {
        ($(script:Invoke-Hook 'Bash' 'echo --dry-run; gh pr merge 490' $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
            Should -Be 'deny'
    }
    It 'DENIES deleting its own marker' {
        ($(script:Invoke-Hook 'Bash' 'rm .agentic-board/brake-armed.json' $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason |
            Should -Match 'Disarming your own safety control'
    }
    It 'DENIES curl against the REST merge endpoint' {
        ($(script:Invoke-Hook 'Bash' 'curl -X PUT https://api.github.com/repos/o/r/pulls/12/merge' $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
            Should -Be 'deny'
    }

    Context 'the file-writing tools cannot rewrite the marker either' {
        BeforeAll {
            # Feed a write-tool payload (file_path instead of command).
            function script:Invoke-WriteHook([string]$Tool, [string]$Path, [string]$Cwd) {
                $payload = @{
                    hook_event_name = 'PreToolUse'
                    tool_name       = $Tool
                    cwd             = $Cwd
                    tool_input      = @{ file_path = $Path }
                } | ConvertTo-Json -Depth 5 -Compress
                return ($payload | pwsh -NoProfile -File $script:Hook | Out-String).Trim()
            }
        }
        It 'DENIES editing the marker' {
            $p = Join-Path $script:HArmed '.agentic-board/brake-armed.json'
            ($(script:Invoke-WriteHook 'Edit' $p $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
                Should -Be 'deny'
        }
        It 'DENIES writing over the marker' {
            $p = Join-Path $script:HArmed '.agentic-board/brake-armed.json'
            ($(script:Invoke-WriteHook 'Write' $p $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
                Should -Be 'deny'
        }
        It 'allows editing any ordinary file in the armed worktree' {
            script:Invoke-WriteHook 'Edit' (Join-Path $script:HArmed 'src/app.ps1') $script:HArmed | Should -BeNullOrEmpty
        }
        It 'DENIES MultiEdit against the marker (round 3 — an uncovered write path)' {
            $p = Join-Path $script:HArmed '.agentic-board/brake-armed.json'
            ($(script:Invoke-WriteHook 'MultiEdit' $p $script:HArmed) | ConvertFrom-Json).hookSpecificOutput.permissionDecision |
                Should -Be 'deny'
        }
    }

    Context 'the hook must fail CLOSED when its own guard cannot load (round 2)' {
        # The severe case: if the armed flag were only set after dot-sourcing Brake-Guard.ps1, a
        # broken guard would leave the catch believing the run was unarmed and allow everything.
        BeforeAll {
            # A private copy of the hook whose sibling guard file is deliberately unparseable.
            $script:BrokenDir = Join-Path $script:HRoot 'brokenguard'
            New-Item -ItemType Directory -Path $script:BrokenDir -Force | Out-Null
            Copy-Item -LiteralPath $script:Hook -Destination (Join-Path $script:BrokenDir 'Brake-PreToolUseHook.ps1')
            Set-Content -LiteralPath (Join-Path $script:BrokenDir 'Brake-Guard.ps1') -Value 'function Broken { this is not valid powershell ((('
        }
        It 'DENIES inside an armed worktree even though the guard fails to load' {
            $payload = @{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                cwd             = $script:HArmed
                tool_input      = @{ command = 'gh pr merge 490' }
            } | ConvertTo-Json -Depth 5 -Compress
            $hook = Join-Path $script:BrokenDir 'Brake-PreToolUseHook.ps1'
            $out = ($payload | pwsh -NoProfile -File $hook | Out-String).Trim()
            $out | Should -Not -BeNullOrEmpty
            ($out | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
        }
        It 'still stays silent OUTSIDE an armed worktree when the guard fails to load' {
            $payload = @{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                cwd             = $script:HPlain
                tool_input      = @{ command = 'gh pr merge 490' }
            } | ConvertTo-Json -Depth 5 -Compress
            $hook = Join-Path $script:BrokenDir 'Brake-PreToolUseHook.ps1'
            ($payload | pwsh -NoProfile -File $hook | Out-String).Trim() | Should -BeNullOrEmpty
        }
    }
}

Describe 'The marker remembers whether the human ORDERED end-to-end (#530)' {
    # The permission belongs to the instruction that launched the run, not to a file that could be
    # edited afterwards -- and the merge decision happens later, when this marker is the only thing
    # that still remembers what was actually asked for.
    BeforeAll {
        $script:ERoot = Join-Path ([IO.Path]::GetTempPath()) ("brake-e2e-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ERoot -Force | Out-Null
    }
    AfterAll {
        if ($script:ERoot -and (Test-Path -LiteralPath $script:ERoot)) {
            Remove-Item -LiteralPath $script:ERoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'records the order when it was given' {
        $j = New-BrakeMarkerJson -Issue 530 -Irreversible @('merge') -EndToEnd $true | ConvertFrom-Json
        $j.endToEnd | Should -BeTrue
    }
    It 'defaults to NOT ordered' {
        (New-BrakeMarkerJson -Issue 530 -Irreversible @('merge') | ConvertFrom-Json).endToEnd | Should -BeFalse
    }
    It 'reads the order back through the marker' {
        $wt = Join-Path $script:ERoot 'ordered'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 530 -Irreversible @('merge') -EndToEnd $true | Out-Null
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeTrue
    }
    It 'reads NOT ordered back when it was not ordered' {
        $wt = Join-Path $script:ERoot 'plain'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 530 -Irreversible @('merge') | Out-Null
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'an OLD marker with no such field reads as NOT ordered' {
        # A run that predates this mode never received that permission; absence is not consent.
        $wt = Join-Path $script:ERoot 'legacy'
        New-Item -ItemType Directory -Path (Join-Path $wt '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $wt '.agentic-board/brake-armed.json') `
            -Value '{"issue":440,"irreversible":["merge"]}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'the marker still protects itself when the run was ordered end-to-end' {
        # Ordering the finish is not permission to disarm the control that decides whether you may.
        Test-IsBrakedCommand -Command 'rm .agentic-board/brake-armed.json' -Irreversible @('merge') |
            Should -Be 'tamper'
    }
}

Describe 'The end-to-end order must be a real boolean (external review, round 1)' {
    # `[bool]$o.endToEnd` accepted the STRING "false": PowerShell casts any non-empty string to
    # $true, so a malformed or hand-edited marker granted the very permission the field withholds.
    BeforeAll {
        $script:BRoot = Join-Path ([IO.Path]::GetTempPath()) ("brake-bool-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:BRoot -Force | Out-Null
        function script:MarkerWith([string]$name, [string]$json) {
            $wt = Join-Path $script:BRoot $name
            New-Item -ItemType Directory -Path (Join-Path $wt '.agentic-board') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $wt '.agentic-board/brake-armed.json') -Value $json
            return $wt
        }
    }
    AfterAll {
        if ($script:BRoot -and (Test-Path -LiteralPath $script:BRoot)) {
            Remove-Item -LiteralPath $script:BRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the STRING "false" is NOT an order' {
        $wt = script:MarkerWith 'strfalse' '{"issue":530,"irreversible":["merge"],"endToEnd":"false"}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'the STRING "true" is NOT an order either — only a real boolean counts' {
        $wt = script:MarkerWith 'strtrue' '{"issue":530,"irreversible":["merge"],"endToEnd":"true"}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'a number is not an order' {
        $wt = script:MarkerWith 'num' '{"issue":530,"irreversible":["merge"],"endToEnd":1}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'null is not an order' {
        # NB: the folder is not called 'nul' -- that is a reserved Windows device name and the
        # directory create fails with a baffling '\\.\nul' error.
        $wt = script:MarkerWith 'jsonnull' '{"issue":530,"irreversible":["merge"],"endToEnd":null}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
    It 'a real boolean true IS the order' {
        $wt = script:MarkerWith 'realtrue' '{"issue":530,"irreversible":["merge"],"endToEnd":true}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeTrue
    }
    It 'a real boolean false is not' {
        $wt = script:MarkerWith 'realfalse' '{"issue":530,"irreversible":["merge"],"endToEnd":false}'
        (Read-BrakeMarker -StartDir $wt).endToEnd | Should -BeFalse
    }
}

Describe 'Test-IsBrakedCommand — an ORDERED run is refused exactly like an unordered one (#541)' {
    # #536 opened one path for a run the owner had ordered to finish: the gate's own script, on the
    # reasoning that it re-checks the four conditions and refuses on its own. Three rounds of
    # external review then found that OPENING it made two latent holes reachable, and neither is a
    # string-matching problem this file could fix:
    #
    #   - `cd C:\ ; pwsh <genuine-gate> -PR 42` passes per segment, and the gate resolves its
    #     marker from its RUNTIME cwd - outside the worktree there is none, so it skips all four
    #     conditions and merges. The two halves of the control disagreed about which directory the
    #     run was in, and the run got to pick.
    #   - The review condition is satisfied by a PR comment the run can post itself.
    #
    # So the classifier honours no order at all. These tests pin that: the order is RECORDED in the
    # marker and acted on nowhere, which is the honest state until #541.

    It 'refuses the gate script for an ordered run, just as for any other' {
        Test-IsBrakedCommand -Command 'pwsh C:\plug .29.0\scripts\Board-Merge.ps1 -PR 535' `
            -Irreversible $script:AllIrr | Should -Be 'merge'
    }
    It 'refuses it however the path is spelled' {
        foreach ($c in @(
            'pwsh plugins/agentic-board/scripts/Board-Merge.ps1 -PR 5'
            'pwsh ./board-merge.ps1 -PR 5'
            'pwsh -File C:\plug .29.0\scripts\Board-Merge.ps1 -PR 5'
            'cd C:\ ; pwsh C:\plug .29.0\scripts\Board-Merge.ps1 -PR 5'
        )) {
            Test-IsBrakedCommand -Command $c -Irreversible $script:AllIrr |
                Should -Be 'merge' -Because "'$c' must not be reachable while #541 is open"
        }
    }
    It 'takes no end-to-end parameter at all — there is nothing for it to switch' {
        # A parameter that exists and changes nothing is how a control comes to mean less than it
        # says. If the order is ever honoured again, this test is the thing that has to change.
        (Get-Command Test-IsBrakedCommand).Parameters.Keys | Should -Not -Contain 'EndToEnd'
    }
    It 'still allows a genuine preview of the gate' {
        Test-IsBrakedCommand -Command 'pwsh Board-Merge.ps1 -PR 490 -DryRun' -Irreversible $script:AllIrr |
            Should -BeNullOrEmpty
    }
    It 'honours a contract that does not brake on merge at all' {
        Test-IsBrakedCommand -Command 'pwsh scripts/Board-Merge.ps1 -PR 1' -Irreversible @('deploy') |
            Should -Be ''
    }
}

Describe 'Test-IsBrakedCommand — pushing straight to the default branch IS a merge (#542)' {
    # Pre-existing gap, older than the end-to-end work: the brake watched `gh pr merge`, the REST
    # merge endpoints and Board-Merge.ps1, and missed the simplest route of all. `git push origin
    # HEAD:main` puts work on the default branch with one command and matched nothing.
    #
    # It was not an oversight so much as a decision that reads differently now: the delete pattern's
    # comment says the lookbehind "keeps `HEAD:main` (an ordinary push refspec) out of it". But this
    # file's own vocabulary defines merge as "putting work on the default branch", which is exactly
    # what that refspec does.

    It 'denies the plain refspec push to main' {
        Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies a branch-to-main refspec' {
        Test-IsBrakedCommand -Command 'git push origin my-branch:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies the same against master' {
        Test-IsBrakedCommand -Command 'git push origin HEAD:master' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies a FORCE refspec push to main' {
        Test-IsBrakedCommand -Command 'git push --force origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies the + force spelling' {
        Test-IsBrakedCommand -Command 'git push origin +HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies the fully-qualified ref form' {
        # Claimed in the PR body and in the code comment, and it did work - but nothing ASSERTED it.
        # On a change born from "the suite was green because a test asserted the gap was correct",
        # an unasserted claim is the one thing not to leave lying around.
        Test-IsBrakedCommand -Command 'git push origin HEAD:refs/heads/main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
        Test-IsBrakedCommand -Command 'git push origin HEAD:refs/heads/master' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies it when the shell terminates the token without a space' {
        # Found by the CI reviewer on the FIX for the over-blocking, not on the original pattern.
        # `(\s|$)` accepts only a space or end-of-segment, and the segment splitter does not treat
        # a lone `&` or a redirection as a separator - so `HEAD:main&` (background the push) and
        # `HEAD:main>out.txt` matched nothing and went through. The `` this replaced DID catch
        # them: fixing the false positive reopened a different hole in the same pattern.
        foreach ($c in @(
            'git push origin HEAD:main&'
            'git push origin HEAD:main>out.txt'
            'git push origin main&'
            'git push origin HEAD:main<in.txt'
        )) {
            Test-IsBrakedCommand -Command $c -Irreversible $script:AllIrr |
                Should -Be 'merge' -Because "'$c' reaches main"
        }
    }
    It 'denies pushing the local default branch by name' {
        Test-IsBrakedCommand -Command 'git push origin main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies it in a later segment' {
        Test-IsBrakedCommand -Command 'git status && git push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'follows the contract — no brake when merge is not irreversible' {
        Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible @('deploy') |
            Should -Be ''
    }

    Context 'must NOT block the pushes the run makes all day' {
        # Over-blocking is how a safety control gets switched off for being annoying, and this
        # pattern sits on the run's single most common command.
        It 'allows pushing its own branch' {
            Test-IsBrakedCommand -Command 'git push -u origin issue-542-push-to-default' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows a bare push' {
            Test-IsBrakedCommand -Command 'git push' -Irreversible $script:AllIrr | Should -BeNullOrEmpty
        }
        It 'allows a force-with-lease on its own branch' {
            Test-IsBrakedCommand -Command 'git push --force-with-lease origin my-branch' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows a branch whose NAME merely contains main' {
            Test-IsBrakedCommand -Command 'git push -u origin issue-9-domain-model' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
            Test-IsBrakedCommand -Command 'git push origin feature/maintenance' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows a refspec onto a branch merely ending in something like main' {
            Test-IsBrakedCommand -Command 'git push origin HEAD:my-domain' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows a branch whose name STARTS with main followed by a separator' {
            # Found by the CI reviewer on the first cut of this pattern. `` only requires the next
            # character to be non-word, so `main-cleanup` and `master.bak` satisfied it and got
            # refused - a false positive on exactly the command this guard must not over-block.
            # The `maintenance` case passed because `t` IS a word character, which is why the first
            # round of tests missed it entirely.
            Test-IsBrakedCommand -Command 'git push origin HEAD:main-cleanup' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
            Test-IsBrakedCommand -Command 'git push origin HEAD:master.bak' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
            Test-IsBrakedCommand -Command 'git push -u origin main-cleanup' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'still recognises the DELETE spelling as delete, not as a merge' {
            Test-IsBrakedCommand -Command 'git push origin :old-branch' -Irreversible $script:AllIrr |
                Should -Be 'delete'
        }
    }
}

Describe 'Test-IsBrakedCommand — git global flags must not shake off the guard (#542, review round 3)' {
    # `\bgit\s+push\b` demands that `push` follow `git` immediately, so ANY global option between
    # them broke every git rule at once. `-C` and `-c` are everyday flags, not exotica.
    #
    # This one was NOT introduced by this PR: the pre-existing `--delete` patterns had the same
    # anchor and the same hole. Found only because the reviewer asked what the anchor assumes.

    It 'denies a push to main behind -C' {
        Test-IsBrakedCommand -Command 'git -C . push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies it behind -c <config>' {
        Test-IsBrakedCommand -Command 'git -c http.extraheader= push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies it behind --no-pager' {
        Test-IsBrakedCommand -Command 'git --no-pager push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'denies it behind several stacked flags' {
        Test-IsBrakedCommand -Command 'git --no-pager -C . -c core.pager=cat push origin HEAD:main' `
            -Irreversible $script:AllIrr | Should -Be 'merge'
    }
    It 'closes the same hole in the PRE-EXISTING branch-delete rule' {
        Test-IsBrakedCommand -Command 'git -C . push origin --delete feature' -Irreversible $script:AllIrr |
            Should -Be 'delete'
    }
    It 'closes it for the refspec delete too' {
        Test-IsBrakedCommand -Command 'git -C . push origin :feature-x' -Irreversible $script:AllIrr |
            Should -Be 'delete'
    }

    Context 'and still does not invent matches' {
        It 'does not treat an unrelated git command as a push' {
            # Quote stripping turns this into `git commit -m push to main`; only tokens that LOOK
            # like flags may sit between git and push, so `commit` stops it dead.
            Test-IsBrakedCommand -Command 'git commit -m "push to main"' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'does not brake an ordinary flagged push' {
            Test-IsBrakedCommand -Command 'git -C . push -u origin issue-542-x' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'does not brake a flagged push to a main-ish branch name' {
            Test-IsBrakedCommand -Command 'git -C . push origin HEAD:main-cleanup' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-IsBrakedCommand — the round-3 fix carried two of its own (#542, review round 4)' {
    # Both introduced by the fix for the global-flag anchor. Neither is exotic.

    Context 'the flag allowance must not be countable' {
        # Bounding the repetition at 5 turned the fix into a new bypass: SIX `-c` flags and the
        # rule stops matching. Chaining several `-c` (user.name, user.email, http.sslVerify,
        # core.pager...) is ordinary scripting, not an attack.
        #
        # The bound was justified in the comment as ReDoS protection. That justification was wrong:
        # the repeated group is anchored by mandatory whitespace and its character classes are
        # disjoint, so there is no catastrophic backtracking to protect against. A guard narrowed
        # against an imagined risk, opening a real one.
        It 'denies a push to main behind SIX global flags' {
            Test-IsBrakedCommand -Command 'git -c a=1 -c b=1 -c c=1 -c d=1 -c e=1 -c f=1 push origin HEAD:main' `
                -Irreversible $script:AllIrr | Should -Be 'merge'
        }
        It 'denies it behind twelve' {
            $flags = (1..12 | ForEach-Object { "-c k$_=v" }) -join ' '
            Test-IsBrakedCommand -Command "git $flags push origin HEAD:main" -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'closes the same count hole in the delete rule' {
            Test-IsBrakedCommand -Command 'git -c a=1 -c b=1 -c c=1 -c d=1 -c e=1 -c f=1 push origin --delete f' `
                -Irreversible $script:AllIrr | Should -Be 'delete'
        }
    }

    Context 'a slash is not a refspec separator' {
        # `[:/]` treated `/` as if it delimited a refspec. It does not - `/` is an ordinary
        # character inside a branch name, so any branch merely ENDING in main/master was refused.
        It 'allows a branch that merely ends in master' {
            Test-IsBrakedCommand -Command 'git push origin release/master' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows a branch that merely ends in main' {
            Test-IsBrakedCommand -Command 'git push origin team/main' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'allows that same branch as an explicit refspec target' {
            # Not raised by the review, but it is the same defect one step along.
            Test-IsBrakedCommand -Command 'git push origin HEAD:team/main' -Irreversible $script:AllIrr |
                Should -BeNullOrEmpty
        }
        It 'STILL denies the fully-qualified ref, which is a real spelling of the default branch' {
            Test-IsBrakedCommand -Command 'git push origin HEAD:refs/heads/main' -Irreversible $script:AllIrr |
                Should -Be 'merge'
            Test-IsBrakedCommand -Command 'git push origin HEAD:refs/heads/master' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
        It 'STILL denies the plain forms' {
            Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible $script:AllIrr |
                Should -Be 'merge'
            Test-IsBrakedCommand -Command 'git push origin main' -Irreversible $script:AllIrr |
                Should -Be 'merge'
        }
    }
}

Describe 'Test-IsBrakedCommand — the classifier must not be stallable (#542, review round 4)' {
    # This guard runs on EVERY tool call. A command that makes it backtrack forever does not just
    # slow the run down - it wedges the session, and a wedged guard is a removed guard.
    #
    # Not hypothetical: while removing the flag COUNT (itself a bypass), the replacement used
    # `-{1,2}[^\s;|&]+`, where both halves can consume the second dash of `--flag`. Two readings
    # per token, 1000 tokens, and the matcher ran past three minutes. Both the external reviewer
    # and I had argued it was safe because "the character classes are disjoint". The argument was
    # wrong and only the stopwatch said so.
    #
    # These are timing assertions on purpose. Generous bounds - they exist to catch a hang, not to
    # police milliseconds on a busy CI box.

    It 'answers quickly on a long run of valueless flags' {
        $cmd = 'git ' + ('--flag ' * 1000) + 'status'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Test-IsBrakedCommand -Command $cmd -Irreversible $script:AllIrr
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000 -Because 'this exact shape hung the matcher'
    }
    It 'answers quickly when that run ends in a real push' {
        $cmd = 'git ' + ('--flag ' * 1000) + 'push origin HEAD:main'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-IsBrakedCommand -Command $cmd -Irreversible $script:AllIrr
        $sw.Stop()
        $r | Should -Be 'merge'
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
    }
    It 'answers quickly on a long run of flags WITH values' {
        $cmd = 'git ' + ('-c k=v ' * 2000) + 'status'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Test-IsBrakedCommand -Command $cmd -Irreversible $script:AllIrr
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
    }
}

Describe 'Test-IsBrakedCommand — deleting the default branch is a DELETE (#542, review round 5)' {
    # `git push origin :main` removes the remote default branch. The merge refspec pattern matched
    # it first (its source side allowed zero characters) and the array is walked in order, so the
    # refusal said "merge is marked irreversible" for a command that DELETES main - arguably worse.
    #
    # Not a bypass, and worth stating why rather than assuming: the contract filter is applied per
    # pattern BEFORE matching, so a contract braking only `delete` already refused it correctly.
    # What was wrong was the verb the human is told, and this control is only as useful as the
    # account it gives of itself.

    It 'calls the empty-source refspec a delete, not a merge' {
        Test-IsBrakedCommand -Command 'git push origin :main' -Irreversible @('merge','delete') |
            Should -Be 'delete'
        Test-IsBrakedCommand -Command 'git push origin :master' -Irreversible @('merge','delete') |
            Should -Be 'delete'
    }
    It 'still calls a real refspec push a merge' {
        Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible @('merge','delete') |
            Should -Be 'merge'
    }
    It 'still refuses it when only delete is braked' {
        Test-IsBrakedCommand -Command 'git push origin :main' -Irreversible @('delete') |
            Should -Be 'delete'
    }
    It 'follows the contract when only MERGE is braked' {
        # Deliberate, and recorded so it is a decision rather than an accident: this command is a
        # delete, so a contract that does not brake deletes does not brake this. The guard follows
        # the contract; it does not invent policy - the rule this file opens with.
        Test-IsBrakedCommand -Command 'git push origin :main' -Irreversible @('merge') |
            Should -BeNullOrEmpty
    }
    It 'is unaffected for ordinary branches' {
        Test-IsBrakedCommand -Command 'git push origin :feature-x' -Irreversible @('merge','delete') |
            Should -Be 'delete'
    }
}

Describe 'Test-IsBrakedCommand — the prefix must not step over a background operator (#542, review round 6)' {
    # Segments split on `;`, `&&`, `||`, `|` and newlines, but NOT on a lone `&` - deliberately, since
    # the branch-name lookahead treats `&` as a terminator. The gap between the two: the `[^;]*`
    # sitting before the refspec excluded only `;`, so the matcher could skip PAST a background `&`
    # and pick up any later `something:main` in the same segment - text belonging to a different
    # command entirely.
    #
    # A false positive, never a bypass (a looser prefix can only add matches). Fixed anyway: this
    # pattern sits on the run's most common command, and over-blocking is how a control gets
    # switched off - the argument this whole change rests on.

    It 'does not read text after a background & as the push target' {
        Test-IsBrakedCommand -Command 'git push origin fine & echo notes:main' -Irreversible $script:AllIrr |
            Should -BeNullOrEmpty
    }
    It 'does not read text after a pipe-ish operator as the push target' {
        Test-IsBrakedCommand -Command 'git push origin fine & cat refs:master' -Irreversible $script:AllIrr |
            Should -BeNullOrEmpty
    }
    It 'still denies when the refspec is the REAL target and & merely follows it' {
        # The round-2 cases must survive: there the `&` comes AFTER the refspec, not before it.
        Test-IsBrakedCommand -Command 'git push origin HEAD:main&' -Irreversible $script:AllIrr |
            Should -Be 'merge'
        Test-IsBrakedCommand -Command 'git push origin HEAD:main>out.txt' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'still denies the ordinary forms' {
        Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
        Test-IsBrakedCommand -Command 'git -C . push origin HEAD:refs/heads/master' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
    It 'still denies a real merge sitting in a LATER segment' {
        # The prefix is narrowed, not the segment splitting: a genuine second command still counts.
        Test-IsBrakedCommand -Command 'git status ; git push origin HEAD:main' -Irreversible $script:AllIrr |
            Should -Be 'merge'
    }
}

Describe 'The enforced time budget (#564)' {
    # Until this change the contract's 120-minute budget was PROSE: Get-BudgetVerdict existed and
    # nothing called it, so a runaway run had no wall-clock limit at all. The marker now carries
    # budgetMinutes + armedAt, Get-BudgetState computes the verdict, and the hook refuses non
    # wrap-up commands once the budget is spent.
    BeforeAll {
        $script:T0 = [datetime]'2026-08-03 10:00:00'
        function script:Marker([int]$budget, [string]$armedAt = '2026-08-03 10:00:00') {
            @{ issue = 42; irreversible = @('merge'); armedAt = $armedAt; budgetMinutes = $budget }
        }
    }

    Context 'Get-BudgetState' {
        It 'not enforced when the marker has no budget (0) - runs launched without one are untouched' {
            $s = Get-BudgetState -Marker (script:Marker 0) -Now $script:T0.AddHours(9)
            $s.Enforced   | Should -BeFalse
            $s.OverBudget | Should -BeFalse
        }
        It 'within budget -> not over' {
            $s = Get-BudgetState -Marker (script:Marker 120) -Now $script:T0.AddMinutes(60)
            $s.Enforced   | Should -BeTrue
            $s.OverBudget | Should -BeFalse
            $s.ElapsedMinutes | Should -Be 60
        }
        It 'past budget -> over, with the elapsed number the deny message needs' {
            $s = Get-BudgetState -Marker (script:Marker 120) -Now $script:T0.AddMinutes(121)
            $s.OverBudget     | Should -BeTrue
            $s.ElapsedMinutes | Should -Be 121
            $s.MaxMinutes     | Should -Be 120
        }
        It 'fails OPEN on an unparsable armedAt - the budget is a liveness limit, not a safety control' {
            # The brake fails closed; the budget deliberately does not. A corrupt timestamp that
            # denied every command would brick normal work to enforce a resource cap.
            $s = Get-BudgetState -Marker (script:Marker 120 'not-a-date') -Now $script:T0.AddHours(9)
            $s.Enforced   | Should -BeFalse
            $s.OverBudget | Should -BeFalse
        }
        It 'fails OPEN on a missing armedAt' {
            $s = Get-BudgetState -Marker (script:Marker 120 '') -Now $script:T0.AddHours(9)
            $s.OverBudget | Should -BeFalse
        }
    }

    Context 'the marker round-trips the budget' {
        It 'New-BrakeMarkerJson carries budgetMinutes' {
            $json = New-BrakeMarkerJson -Issue 7 -Irreversible @('merge') -ArmedAt '2026-08-03 10:00:00' -BudgetMinutes 90
            ($json | ConvertFrom-Json).budgetMinutes | Should -Be 90
        }
        It 'a marker without the field reads as 0 (no enforcement) - older runs keep working' {
            $json = New-BrakeMarkerJson -Issue 7 -Irreversible @('merge') -ArmedAt '2026-08-03 10:00:00'
            ($json | ConvertFrom-Json).budgetMinutes | Should -Be 0
        }
        It 'a negative budget clamps to 0 rather than arming a nonsense limit' {
            $json = New-BrakeMarkerJson -Issue 7 -Irreversible @('merge') -BudgetMinutes -5
            ($json | ConvertFrom-Json).budgetMinutes | Should -Be 0
        }
    }

    Context 'Test-IsBudgetExemptCommand - what an over-budget run may still do' {
        It 'allows the handoff save (THE thing the budget wants it to run)' {
            Test-IsBudgetExemptCommand -Command 'pwsh -File scripts/Board-Handoff.ps1 -Save' | Should -BeTrue
        }
        It 'refuses a handoff -Resume: resuming is the START of more work, not the end of it (round 7)' {
            Test-IsBudgetExemptCommand -Command 'pwsh -File scripts/Board-Handoff.ps1 -Resume' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'scripts/Board-Handoff.ps1 -Resume' | Should -BeFalse
        }
        It 'refuses -Resume hiding a -Save in a comment (round 8: no comments in wrap-up commands, and -resume refuses on its own)' {
            Test-IsBudgetExemptCommand -Command 'pwsh -File scripts/Board-Handoff.ps1 -Resume # -Save' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'scripts/Board-Handoff.ps1 -Resume -Save' | Should -BeFalse
        }
        It 'allows committing and pushing the WIP' {
            Test-IsBudgetExemptCommand -Command 'git add -A' | Should -BeTrue
            Test-IsBudgetExemptCommand -Command 'git commit -m "wip: out of budget"' | Should -BeTrue
            Test-IsBudgetExemptCommand -Command 'git push origin HEAD:issue-42-branch' | Should -BeTrue
        }
        It 'push is WIP-shaped only: mirror/all/tags/force/delete/:ref forms are NOT wrap-up (#565 round 2)' {
            Test-IsBudgetExemptCommand -Command 'git push --mirror origin' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push --all origin' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push --tags origin' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push --force origin HEAD:feature' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push -f origin HEAD:feature' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push origin --delete old-branch' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push origin :old-branch' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push origin +HEAD:feature' | Should -BeFalse   # force refspec (round 3)
        }
        It 'push to the DEFAULT branch is never wrap-up, whatever the contract says (round 4)' {
            Test-IsBudgetExemptCommand -Command 'git push origin HEAD:main' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push origin main' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git push origin HEAD:refs/heads/master' | Should -BeFalse
        }
        It 'git diff --output writes a file through a read-shaped command - refused (round 4)' {
            Test-IsBudgetExemptCommand -Command 'git diff --output=src/app.ts' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git log --output out.txt' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git diff HEAD~1' | Should -BeTrue
        }
        It 'allows reporting where it stopped' {
            Test-IsBudgetExemptCommand -Command 'gh pr comment 90 --body "out of budget, handoff saved"' | Should -BeTrue
        }
        It 'refuses more work' {
            Test-IsBudgetExemptCommand -Command 'npm run build' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'Invoke-Pester tests/' | Should -BeFalse
        }
        It 'refuses more work hiding behind a handoff in the same command line' {
            # EVERY segment must be exempt - the same per-segment rule the brake applies, in reverse.
            Test-IsBudgetExemptCommand -Command 'pwsh -File scripts/Board-Handoff.ps1 -Save; npm run build' | Should -BeFalse
        }
        It 'refuses work that merely CONTAINS an exempt phrase (external review: anchored, not matched anywhere)' {
            # `npm run build -- git status` contained "git status" and sailed through the
            # unanchored first cut. The command must BE the wrap-up, not mention one.
            Test-IsBudgetExemptCommand -Command 'npm run build -- git status' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'echo see Board-Handoff.ps1 for details' | Should -BeFalse
        }
        It 'still allows the pwsh-launcher shape after anchoring' {
            Test-IsBudgetExemptCommand -Command 'pwsh -NoProfile -File scripts/Board-Handoff.ps1 -Save' | Should -BeTrue
            Test-IsBudgetExemptCommand -Command "& 'C:\repo\scripts\Board-Handoff.ps1' -Save" | Should -BeTrue
        }
        It 'refuses a pwsh -Command that merely MENTIONS the exempt script (round 2: -File target required)' {
            Test-IsBudgetExemptCommand -Command 'pwsh -Command "npm run build # Board-Handoff.ps1"' | Should -BeFalse
        }
        It 'refuses -Command executing OTHER work with the handoff as mere arguments (round 5: closed host-flag list)' {
            # pwsh treats this as executing build.ps1; the trailing -File never reaches the host.
            Test-IsBudgetExemptCommand -Command 'pwsh -Command .\build.ps1 -File .\scripts\Board-Handoff.ps1' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'pwsh -EncodedCommand bnBtIHJ1biBidWlsZA== -File scripts/Board-Handoff.ps1' | Should -BeFalse
        }
        It 'still allows the known non-executing host flags before -File' {
            Test-IsBudgetExemptCommand -Command 'pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Board-Handoff.ps1 -Save' | Should -BeTrue
        }
        It 'refuses work smuggled into an exempt segment via &, redirection or subexpression (round 3: exempt segments must be inert)' {
            Test-IsBudgetExemptCommand -Command 'git status & npm run build' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git status > src/app.ts' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git commit -m "$(npm run build)"' | Should -BeFalse
        }
        It 'refuses the substitution forms the normalizer hides or leaves behind (round 4)' {
            Test-IsBudgetExemptCommand -Command 'git status `npm run build`' | Should -BeFalse       # backticks: checked raw
            Test-IsBudgetExemptCommand -Command 'git status (npm run build)' | Should -BeFalse       # PS grouping
            Test-IsBudgetExemptCommand -Command 'git status @(npm run build)' | Should -BeFalse      # PS array subexpr
        }
        It 'stash is save-only: push/save pass, pop/apply/drop/clear are more work or lost work (round 4)' {
            Test-IsBudgetExemptCommand -Command 'git stash' | Should -BeTrue
            Test-IsBudgetExemptCommand -Command 'git stash push -m wip' | Should -BeTrue
            Test-IsBudgetExemptCommand -Command 'git stash pop' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git stash drop' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git stash clear' | Should -BeFalse
        }
        It 'wrap-up git takes NO global flags - `-c diff.external=` was an execution primitive (round 6)' {
            Test-IsBudgetExemptCommand -Command 'git -c diff.external=build.cmd diff' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'git -C C:\elsewhere status' | Should -BeFalse
        }
        It 'the exempt script is an exact basename, not a suffix (round 6)' {
            Test-IsBudgetExemptCommand -Command 'pwsh -File scripts/Evil-Board-Handoff.ps1' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'scripts/Evil-Board-Handoff.ps1 -Save' | Should -BeFalse
            Test-IsBudgetExemptCommand -Command 'scripts/Board-Handoff.ps1 -Save' | Should -BeTrue
        }
        It 'an empty command is not exempt' {
            Test-IsBudgetExemptCommand -Command '' | Should -BeFalse
        }
    }

    Context 'Test-IsBudgetExemptWrite - the wrap-up surfaces' {
        It 'allows the handoff files' {
            Test-IsBudgetExemptWrite -Path 'C:\repo\HANDOFF.md' | Should -BeTrue
            Test-IsBudgetExemptWrite -Path 'C:\repo\.handoffs\2026-08-03-issue-42.md' | Should -BeTrue
        }
        It 'allows the run state dir and evidence' {
            Test-IsBudgetExemptWrite -Path 'C:\repo\.agentic-board\active-run.json' | Should -BeTrue
            Test-IsBudgetExemptWrite -Path 'C:\repo\evidence\42.md' | Should -BeTrue
        }
        It 'refuses source files - that is more work' {
            Test-IsBudgetExemptWrite -Path 'C:\repo\src\app.ts' | Should -BeFalse
            Test-IsBudgetExemptWrite -Path 'C:\repo\scripts\Board-Work.ps1' | Should -BeFalse
        }
        It 'refuses a `..` escape through an allowed directory (external review: pure core cannot resolve, so it refuses the shape)' {
            Test-IsBudgetExemptWrite -Path 'C:\repo\.agentic-board\..\src\app.ts' | Should -BeFalse
            Test-IsBudgetExemptWrite -Path 'C:\repo\.handoffs\..\src\app.ts' | Should -BeFalse
        }
        It 'with a root, surfaces anchor to the worktree ROOT - a mid-path directory name is not a surface (round 6)' {
            Test-IsBudgetExemptWrite -Path 'C:\repo\src\.agentic-board\app.ts' -Root 'C:\repo' | Should -BeFalse
            Test-IsBudgetExemptWrite -Path 'C:\other\project\.agentic-board\x.json' -Root 'C:\repo' | Should -BeFalse
            Test-IsBudgetExemptWrite -Path 'C:\repo\.agentic-board\active-run.json' -Root 'C:\repo' | Should -BeTrue
            Test-IsBudgetExemptWrite -Path 'C:\repo\HANDOFF.md' -Root 'C:\repo' | Should -BeTrue
            Test-IsBudgetExemptWrite -Path 'C:\repo\evidence\42.md' -Root 'C:\repo' | Should -BeTrue
        }
    }

    Context 'the brake still wins over the budget exemption' {
        It 'git push to MAIN is a braked merge even though git push is budget-exempt' {
            # The hook checks Test-IsBrakedCommand BEFORE the budget exemption, so the exempt
            # list can never become a side door for the irreversible.
            Test-IsBrakedCommand -Command 'git push origin HEAD:main' -Irreversible @('merge') | Should -Be 'merge'
        }
    }
}

Describe 'Run signals - a stopped run must not sit silent (#565)' {
    # A denial's only output used to go to the MODEL. These pin: the local denial log, the
    # once-per-(kind,issue) dedup markers, and the comment bodies the human actually reads.
    Context 'signal markers (dedup)' {
        It 'round-trips: not posted -> set -> posted' {
            $wt = Join-Path $TestDrive 'sig-wt'
            New-Item -ItemType Directory -Path $wt -Force | Out-Null
            Test-SignalPosted -WorkPath $wt -Kind 'brake' -Issue 42 | Should -BeFalse
            Set-SignalPosted  -WorkPath $wt -Kind 'brake' -Issue 42 | Should -BeTrue
            Test-SignalPosted -WorkPath $wt -Kind 'brake' -Issue 42 | Should -BeTrue
        }
        It 'kinds and issues dedup independently' {
            $wt = Join-Path $TestDrive 'sig-wt2'
            New-Item -ItemType Directory -Path $wt -Force | Out-Null
            Set-SignalPosted  -WorkPath $wt -Kind 'brake' -Issue 42 | Should -BeTrue
            Test-SignalPosted -WorkPath $wt -Kind 'budget' -Issue 42 | Should -BeFalse
            Test-SignalPosted -WorkPath $wt -Kind 'brake' -Issue 43 | Should -BeFalse
        }
    }

    Context 'denial log' {
        It 'appends parseable JSONL lines' {
            $wt = Join-Path $TestDrive 'log-wt'
            New-Item -ItemType Directory -Path $wt -Force | Out-Null
            Write-DenialLog -WorkPath $wt -Kind 'brake' -Action 'merge' -Issue 7 | Should -BeTrue
            Write-DenialLog -WorkPath $wt -Kind 'budget' -Issue 7 | Should -BeTrue
            $lines = Get-Content (Join-Path $wt '.agentic-board\denials.jsonl')
            @($lines).Count | Should -Be 2
            ($lines[0] | ConvertFrom-Json).action | Should -Be 'merge'
            ($lines[1] | ConvertFrom-Json).kind   | Should -Be 'budget'
        }
    }

    Context 'comment bodies' {
        It 'the brake signal names the action, the issue and the log to check' {
            $b = New-SignalCommentBody -Kind 'brake' -Action 'merge' -Issue 42
            $b | Should -Match '\[abios-signal\] brake issue=42'
            $b | Should -Match '\*\*merge\*\*'
            $b | Should -Match 'issue-42\.log'
        }
        It 'the budget signal carries the elapsed/max numbers' {
            $b = New-SignalCommentBody -Kind 'budget' -Issue 42 -ElapsedMinutes 130 -MaxMinutes 120
            $b | Should -Match '\[abios-signal\] budget issue=42'
            $b | Should -Match '130 of its 120-minute budget'
        }
    }

    Context 'Send-RunSignal fail direction' {
        It 'logs locally and never throws when the marker has no repo (nothing to post to)' {
            $wt = Join-Path $TestDrive 'send-wt'
            $dir = Join-Path $wt '.agentic-board'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $markerPath = Join-Path $dir 'brake-armed.json'
            Set-Content -LiteralPath $markerPath -Value '{}'
            $marker = @{ issue = 9; repo = ''; path = $markerPath }
            { Send-RunSignal -Marker $marker -Kind 'brake' -Action 'merge' } | Should -Not -Throw
            Test-Path (Join-Path $dir 'denials.jsonl') | Should -BeTrue
            # No repo -> no comment attempt -> no dedup marker written.
            Test-SignalPosted -WorkPath $wt -Kind 'brake' -Issue 9 | Should -BeFalse
        }
    }
}

Describe 'The marker round-trips the repo (#565)' {
    It 'New-BrakeMarkerJson carries repo and Read shape parses it back' {
        $json = New-BrakeMarkerJson -Issue 7 -Irreversible @('merge') -Repo 'owner/name'
        ($json | ConvertFrom-Json).repo | Should -Be 'owner/name'
    }
    It 'a marker without repo reads as empty (older runs keep working, they just cannot signal)' {
        $json = New-BrakeMarkerJson -Issue 7 -Irreversible @('merge')
        ($json | ConvertFrom-Json).repo | Should -Be ''
    }
}

Describe 'Quoted text is data, not shell syntax (#565 review)' {
    # The budget deny tells the run to leave a comment and commit its WIP - and those messages
    # legitimately contain "(#42)" and similar. The metacharacter scan judges SHELL SYNTAX only:
    # quoted spans are masked first, while $() and backticks stay refused even inside quotes
    # (they execute there).
    It 'allows the exact wrap-up the deny message asks for' {
        Test-IsBudgetExemptCommand -Command 'git commit -m "wip: out of budget (#42)"' | Should -BeTrue
        Test-IsBudgetExemptCommand -Command 'gh issue comment 42 --body "out of budget, handoff saved (#42) - see log"' | Should -BeTrue
    }
    It 'still refuses execution forms even inside double quotes' {
        Test-IsBudgetExemptCommand -Command 'git commit -m "done $(npm run build)"' | Should -BeFalse
        Test-IsBudgetExemptCommand -Command 'gh issue comment 42 --body "x `npm run build` y"' | Should -BeFalse
    }
    It 'still refuses UNQUOTED operators' {
        Test-IsBudgetExemptCommand -Command 'git status > src/app.ts' | Should -BeFalse
        Test-IsBudgetExemptCommand -Command 'git status & npm run build' | Should -BeFalse
    }
}
