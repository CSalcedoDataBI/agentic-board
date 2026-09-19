#Requires -Modules Pester
<#  auto-clean must never treat the MAIN working copy as a worktree to tear down (#555).

    Sessions from before the worktree flow ran `-Start` in the clone itself, so the registry names the
    clone (or a folder inside it) as the "worktree". Real git repos and a real registry file: what
    matters is what the teardown does to the disk. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
}

Describe 'Test-IsMainWorkingCopy (#555)' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'ismain'
        $script:Clone = Join-Path $script:Root 'clone'
        New-Item -ItemType Directory -Path (Join-Path $script:Clone 'plugins\x') -Force | Out-Null
        Push-Location $script:Clone
        git init -q -b main 2>&1 | Out-Null
        'a' | Set-Content (Join-Path $script:Clone 'plugins\x\f.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base 2>&1 | Out-Null
        git branch issue-5-wt 2>&1 | Out-Null
        $script:Linked = Join-Path $script:Root 'clone--issue-5'
        git worktree add -q $script:Linked issue-5-wt 2>&1 | Out-Null
        Pop-Location
    }
    It 'is true for the clone root'                       { Test-IsMainWorkingCopy $script:Clone | Should -BeTrue }
    It 'is true for a folder INSIDE the clone'            { Test-IsMainWorkingCopy (Join-Path $script:Clone 'plugins\x') | Should -BeTrue }
    It 'is false for a linked worktree'                   { Test-IsMainWorkingCopy $script:Linked | Should -BeFalse }
    It 'is false for a folder that is not in any repo'    {
        $plain = Join-Path $TestDrive 'plain'; New-Item -ItemType Directory -Path $plain | Out-Null
        Test-IsMainWorkingCopy $plain | Should -BeFalse
    }
    It 'is false for a path that does not exist'          { Test-IsMainWorkingCopy (Join-Path $TestDrive 'nope') | Should -BeFalse }
    It 'is false for an empty path'                       { Test-IsMainWorkingCopy '' | Should -BeFalse }
}

Describe 'Invoke-SessionCleanup never tears down the main working copy (#555)' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('cl' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Clone = Join-Path $script:Root 'clone'
        New-Item -ItemType Directory -Path (Join-Path $script:Clone 'plugins\agentic-board') -Force | Out-Null
        Push-Location $script:Clone
        git init -q -b main 2>&1 | Out-Null
        'source' | Set-Content (Join-Path $script:Clone 'plugins\agentic-board\code.ps1')
        'x' | Set-Content (Join-Path $script:Clone 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base 2>&1 | Out-Null
        git branch issue-30-legacy 2>&1 | Out-Null
        # A REAL registry file holding the legacy entry, so "the entry is pruned" is observable.
        $script:Reg = Join-Path $script:Root 'sessions.json'
        $reg = $script:Reg
        Mock Get-SessionRegistryPath -MockWith ([scriptblock]::Create("'$reg'"))
        Mock Find-WtTabShell { $null }
        function script:Set-Registry([string]$WorkPath) {
            @([pscustomobject]@{ issue = 30; branch = 'issue-30-legacy'; workPath = $WorkPath; sessionPid = 0; via = '' }) |
                ConvertTo-Json -Depth 4 -AsArray | Set-Content $script:Reg
        }
        function script:New-Legacy([string]$WorkPath) { [pscustomobject]@{ issue = 30; branch = 'issue-30-legacy'; workPath = $WorkPath; sessionPid = 0; via = '' } }
    }
    AfterEach { Pop-Location }

    It 'a folder INSIDE the clone is never deleted (this used to Remove-Item -Recurse it)' {
        $sub = Join-Path $script:Clone 'plugins\agentic-board'
        Set-Registry $sub
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $sub) -PrMerged)
        Test-Path (Join-Path $sub 'code.ps1') | Should -BeTrue
        ($acts -join ' ') | Should -Not -Match 'carpeta del worktree eliminada'
        ($acts -join ' ') | Should -Not -Match 'worktree remove'
        ($acts -join ' ') | Should -Match 'SKIP no toco'
    }
    It 'the clone root is skipped with a reason, and the legacy entry is PRUNED instead of retried forever' {
        Set-Registry $script:Clone
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $script:Clone) -PrMerged)
        ($acts -join ' ') | Should -Match 'SKIP no toco'
        ($acts -join ' ') | Should -Not -Match 'FAIL'
        ($acts -join ' ') | Should -Match 'prune #30'
        Test-Path (Join-Path $script:Clone 'a.txt') | Should -BeTrue
        (Get-Content $script:Reg -Raw) | Should -Not -Match '"issue"'
        (git branch --list 'issue-30-legacy') | Should -BeNullOrEmpty    # the merged branch still goes
    }
    It 'a clone with UNCOMMITTED files still drains (the dirty check must not strand the entry)' {
        'wip' | Set-Content (Join-Path $script:Clone 'wip.txt')
        Set-Registry $script:Clone
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $script:Clone))    # NOT merged
        ($acts -join ' ') | Should -Not -Match 'sin commitear'
        ($acts -join ' ') | Should -Match 'prune #30'
        Test-Path (Join-Path $script:Clone 'wip.txt') | Should -BeTrue
    }
    It '-ForceRemoveWorktree does NOT license removing the primary checkout' {
        Set-Registry $script:Clone
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $script:Clone) -ForceRemoveWorktree)
        ($acts -join ' ') | Should -Match 'SKIP no toco'
        ($acts -join ' ') | Should -Not -Match 'worktree remove'
        Test-Path (Join-Path $script:Clone 'a.txt') | Should -BeTrue
    }
    It '-DryRun previews the SKIP, not a worktree removal' {
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $script:Clone) -DryRun -PrMerged)
        ($acts -join ' ') | Should -Match 'SKIP no toco'
        ($acts -join ' ') | Should -Not -Match 'worktree remove'
    }
    It 'CONTROL: a genuine linked worktree is still torn down exactly as before' {
        $wt = Join-Path $script:Root 'clone--issue-30'
        git worktree add -q $wt issue-30-legacy 2>&1 | Out-Null
        Set-Registry $wt
        $acts = @(Invoke-SessionCleanup -Session (New-Legacy $wt) -PrMerged)
        ($acts -join ' ') | Should -Match 'git worktree remove --force'
        ($acts -join ' ') | Should -Not -Match 'SKIP no toco'
        Test-Path $wt | Should -BeFalse
        (git branch --list 'issue-30-legacy') | Should -BeNullOrEmpty
        (Get-Content $script:Reg -Raw) | Should -Not -Match '"issue"'
    }
}
