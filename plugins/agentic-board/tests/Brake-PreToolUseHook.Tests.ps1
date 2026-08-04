#Requires -Modules Pester
<#  Tests for Brake-PreToolUseHook.ps1 — the half of the brake that does not depend on the agent's
    cooperation (#516), taught the end-to-end order in #536.

    Brake-Guard.ps1's pure core was well covered; the HOOK that drives it was not, even though it
    is the piece Claude Code actually executes and the only one that can produce a refusal. These
    drive the real script over real stdin and assert on the payload it prints, so the contract
    with the harness (exit 0 + permissionDecision=deny, or exit 0 + silence) is pinned.

    The fail direction is asymmetric ON PURPOSE and is asserted in both directions:
      - no marker  -> silence, always. A control that interferes with ordinary work gets removed.
      - marker + anything unclear -> deny. Inside an armed run, "I could not tell" is not a yes. #>

BeforeAll {
    $script:Hook = Join-Path $PSScriptRoot '..' 'scripts' 'Brake-PreToolUseHook.ps1' | Resolve-Path
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("brakehook-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

    # A worktree with a marker in it. $MarkerJson of '' means NO marker (an ordinary session).
    function script:NewWorktree {
        param([string]$Name, [string]$MarkerJson)
        $wt = Join-Path $script:Root $Name
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        if ($MarkerJson) {
            $dir = Join-Path $wt '.agentic-board'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'brake-armed.json') -Value $MarkerJson -Encoding UTF8
        }
        return $wt
    }

    function script:Marker {
        param([bool]$EndToEnd = $false, [string[]]$Irr = @('merge','deploy','refresh','publish','delete'))
        $e = if ($EndToEnd) { 'true' } else { 'false' }
        $l = ($Irr | ForEach-Object { "`"$_`"" }) -join ','
        return "{`"issue`":532,`"irreversible`":[$l],`"endToEnd`":$e}"
    }

    # Drive the hook exactly as the harness does: JSON on stdin, read stdout.
    function script:RunHook {
        param([string]$Cwd, [string]$Tool = 'Bash', [string]$Command = '', [string]$FilePath = '')
        $payload = @{
            tool_name  = $Tool
            cwd        = $Cwd
            tool_input = @{ command = $Command; file_path = $FilePath }
        } | ConvertTo-Json -Depth 5 -Compress

        $in = Join-Path $script:Root ("in-" + [guid]::NewGuid().ToString('N') + ".json")
        Set-Content -LiteralPath $in -Value $payload -Encoding UTF8
        $out = (Get-Content -LiteralPath $in -Raw | & pwsh -NoProfile -File "$script:Hook" 2>$null | Out-String)
        Remove-Item -LiteralPath $in -Force -ErrorAction SilentlyContinue
        return "$out".Trim()
    }

    function script:DecisionOf {
        param([string]$Out)
        if (-not $Out) { return '' }
        try { return "$(($Out | ConvertFrom-Json).hookSpecificOutput.permissionDecision)" } catch { return 'UNPARSEABLE' }
    }
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Brake hook — an ordinary session is never touched' {
    It 'stays silent when there is no marker anywhere above the cwd' {
        $wt = script:NewWorktree 'plain' ''
        script:RunHook -Cwd $wt -Command 'gh pr merge 490 --squash' | Should -BeNullOrEmpty
    }
    It 'stays silent for tools that cannot reach an irreversible action' {
        $wt = script:NewWorktree 'readonly' (script:Marker)
        script:RunHook -Cwd $wt -Tool 'Read' -Command 'gh pr merge 490' | Should -BeNullOrEmpty
    }
    It 'stays silent for an ordinary command inside an armed run' {
        $wt = script:NewWorktree 'ordinary' (script:Marker)
        script:RunHook -Cwd $wt -Command 'git status' | Should -BeNullOrEmpty
    }
    It 'finds a marker in a PARENT directory, not just the cwd' {
        $wt  = script:NewWorktree 'parent' (script:Marker)
        $sub = Join-Path $wt 'src/deep'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        script:DecisionOf (script:RunHook -Cwd $sub -Command 'gh pr merge 1') | Should -Be 'deny'
    }
}

Describe 'Brake hook — an armed run without the order' {
    It 'denies the merge the observed run actually used' {
        $wt = script:NewWorktree 'armed' (script:Marker)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'gh pr merge 490 --squash --delete-branch') |
            Should -Be 'deny'
    }
    It 'denies the gated merge script too — without an order it is just another merge' {
        $wt = script:NewWorktree 'armed-gated' (script:Marker)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'pwsh scripts/Board-Merge.ps1 -PR 535') |
            Should -Be 'deny'
    }
    It 'denies writing to the marker (tamper)' {
        $wt = script:NewWorktree 'armed-write' (script:Marker)
        $target = Join-Path (Join-Path $wt '.agentic-board') 'brake-armed.json'
        script:DecisionOf (script:RunHook -Cwd $wt -Tool 'Write' -FilePath $target) | Should -Be 'deny'
    }
    It 'explains itself rather than just refusing' {
        $wt = script:NewWorktree 'armed-why' (script:Marker)
        script:RunHook -Cwd $wt -Command 'gh pr merge 1' | Should -Match 'BRAKE'
    }
}

Describe 'Brake hook — the order is recorded and acted on nowhere (#541)' {
    # #536 let an ordered run reach the gate's own script. Review found that opening it made two
    # latent holes reachable — a `cd` out of the worktree makes the gate skip its own four
    # conditions, and the review condition is a comment the run can post itself. Neither is
    # fixable in a command-string classifier, so nothing is opened until #541.

    It 'refuses the gate script even when the marker carries the order' {
        $gate = Join-Path (Split-Path $script:Hook -Parent) 'Board-Merge.ps1'
        $wt = script:NewWorktree 'e2e-gate' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command "pwsh -File $gate -PR 535") | Should -Be 'deny'
    }
    It 'refuses the cd-out-of-the-worktree shape that motivated closing it' {
        $gate = Join-Path (Split-Path $script:Hook -Parent) 'Board-Merge.ps1'
        $wt = script:NewWorktree 'e2e-cd' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command "cd C:\ ; pwsh -File $gate -PR 535") |
            Should -Be 'deny'
    }
    It 'refuses a raw merge when ordered' {
        $wt = script:NewWorktree 'e2e-raw' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'gh pr merge 535 --squash') | Should -Be 'deny'
    }
    It 'refuses deploy and publish when ordered' {
        $wt = script:NewWorktree 'e2e-deploy' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'wrangler deploy') | Should -Be 'deny'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'npm publish')     | Should -Be 'deny'
    }
    It 'refuses tampering when ordered' {
        $wt = script:NewWorktree 'e2e-tamper' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'rm .agentic-board/brake-armed.json') |
            Should -Be 'deny'
    }
    It 'behaves identically ordered and unordered' {
        # The clearest statement of the current contract: the order changes nothing here.
        $gate = Join-Path (Split-Path $script:Hook -Parent) 'Board-Merge.ps1'
        $on  = script:NewWorktree 'e2e-on'  (script:Marker -EndToEnd $true)
        $off = script:NewWorktree 'e2e-off' (script:Marker -EndToEnd $false)
        (script:DecisionOf (script:RunHook -Cwd $on  -Command "pwsh -File $gate -PR 1")) |
            Should -Be (script:DecisionOf (script:RunHook -Cwd $off -Command "pwsh -File $gate -PR 1"))
    }
}

Describe 'Brake hook — inside an armed run, failure means refusal' {
    It 'denies when the marker is present but unreadable' {
        $wt = script:NewWorktree 'corrupt' '{ this is not json'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'gh pr merge 1') | Should -Be 'deny'
    }
    It 'denies an emptied irreversible list rather than reading it as "brakes on nothing"' {
        $wt = script:NewWorktree 'emptied' '{"issue":532,"irreversible":[]}'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'gh pr merge 1') | Should -Be 'deny'
    }
    It 'an unreadable marker is not an order either' {
        # The permissive direction must not be reachable through corruption.
        $wt = script:NewWorktree 'corrupt-gated' '{ broken'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'pwsh scripts/Board-Merge.ps1 -PR 1') |
            Should -Be 'deny'
    }
}

Describe 'The hook enforces the time budget (#564)' {
    # End-to-end over real stdin: an armed marker whose budget is SPENT refuses more work but
    # leaves the wrap-up path open. The brake still takes precedence over the exemption.
    BeforeAll {
        function script:BudgetMarker {
            param([int]$Budget, [string]$ArmedAt)
            return "{`"issue`":42,`"irreversible`":[`"merge`"],`"endToEnd`":false,`"armedAt`":`"$ArmedAt`",`"budgetMinutes`":$Budget}"
        }
        $script:SpentAt = (Get-Date).AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss')   # 180 min ago
        $script:FreshAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    It 'refuses more work once the budget is spent, and says BUDGET (not BRAKE)' {
        $wt  = script:NewWorktree 'budget-spent' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Command 'npm run build'
        script:DecisionOf $out | Should -Be 'deny'
        $out | Should -Match 'BUDGET'
    }
    It 'still allows the handoff save when over budget' {
        $wt  = script:NewWorktree 'budget-handoff' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Command 'pwsh -File scripts/Board-Handoff.ps1 -Save'
        $out | Should -BeNullOrEmpty
    }
    It 'still allows committing the WIP when over budget' {
        $wt  = script:NewWorktree 'budget-commit' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Command 'git commit -m "wip: out of budget"'
        $out | Should -BeNullOrEmpty
    }
    It 'the BRAKE still wins: a push to main over budget is refused as merge, not excused as git' {
        $wt  = script:NewWorktree 'budget-brake' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Command 'git push origin HEAD:main'
        script:DecisionOf $out | Should -Be 'deny'
        $out | Should -Match 'BRAKE'
    }
    It 'within budget, ordinary work passes untouched' {
        $wt  = script:NewWorktree 'budget-fresh' (script:BudgetMarker 120 $script:FreshAt)
        $out = script:RunHook -Cwd $wt -Command 'npm run build'
        $out | Should -BeNullOrEmpty
    }
    It 'a marker with no budget field enforces nothing (older runs untouched)' {
        $wt  = script:NewWorktree 'budget-none' (script:Marker)
        $out = script:RunHook -Cwd $wt -Command 'npm run build'
        $out | Should -BeNullOrEmpty
    }
    It 'over budget, a WRITE outside the wrap-up surfaces is refused' {
        $wt  = script:NewWorktree 'budget-write' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Tool 'Write' -FilePath (Join-Path $wt 'src\app.ts')
        script:DecisionOf $out | Should -Be 'deny'
        $out | Should -Match 'BUDGET'
    }
    It 'over budget, writing the handoff file is allowed' {
        $wt  = script:NewWorktree 'budget-write-ok' (script:BudgetMarker 120 $script:SpentAt)
        $out = script:RunHook -Cwd $wt -Tool 'Write' -FilePath (Join-Path $wt 'HANDOFF.md')
        $out | Should -BeNullOrEmpty
    }
}

Describe 'Budget-only marker - a contract that does not brake on merge still gets its time limit (#564 round 2)' {
    It 'enforces the budget from a marker whose irreversible list has no merge' {
        $armedOld = (Get-Date).AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss')
        $mk  = "{`"issue`":7,`"irreversible`":[`"deploy`"],`"endToEnd`":false,`"armedAt`":`"$armedOld`",`"budgetMinutes`":60}"
        $wt  = script:NewWorktree 'budget-only' $mk
        $out = script:RunHook -Cwd $wt -Command 'npm run build'
        script:DecisionOf $out | Should -Be 'deny'
        $out | Should -Match 'BUDGET'
    }
}
