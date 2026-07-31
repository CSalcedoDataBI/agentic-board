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

Describe 'Brake hook — the ORDERED end-to-end run (#536)' {
    # Before this, the marker carried `endToEnd` and the hook never read it: the gated path was
    # refused identically, so an ordered run could not reach the only merge route that CHECKS
    # anything. The order opens that one path and nothing else.

    It 'lets the GATED merge script through when ordered' {
        $wt = script:NewWorktree 'e2e-gated' (script:Marker -EndToEnd $true)
        script:RunHook -Cwd $wt -Command 'pwsh plugins/agentic-board/scripts/Board-Merge.ps1 -PR 535' |
            Should -BeNullOrEmpty
    }
    It 'still denies the RAW merge when ordered' {
        $wt = script:NewWorktree 'e2e-raw' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'gh pr merge 535 --squash') | Should -Be 'deny'
    }
    It 'still denies the REST merge endpoint when ordered' {
        $wt = script:NewWorktree 'e2e-rest' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'curl -X PUT https://api.github.com/repos/o/r/pulls/9/merge') |
            Should -Be 'deny'
    }
    It 'still denies tampering with the marker when ordered' {
        $wt = script:NewWorktree 'e2e-tamper' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'rm .agentic-board/brake-armed.json') |
            Should -Be 'deny'
    }
    It 'still denies deploy and publish when ordered — the order is about CLOSING the work' {
        $wt = script:NewWorktree 'e2e-deploy' (script:Marker -EndToEnd $true)
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'wrangler deploy') | Should -Be 'deny'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'npm publish')     | Should -Be 'deny'
    }
    It 'treats the STRING "true" as no order at all' {
        # PowerShell casts any non-empty string to $true; a hand-edited marker must not be able to
        # grant the permission by writing it as text.
        $wt = script:NewWorktree 'e2e-strtrue' '{"issue":532,"irreversible":["merge"],"endToEnd":"true"}'
        script:DecisionOf (script:RunHook -Cwd $wt -Command 'pwsh scripts/Board-Merge.ps1 -PR 1') |
            Should -Be 'deny'
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
