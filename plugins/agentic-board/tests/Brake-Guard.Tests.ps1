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
