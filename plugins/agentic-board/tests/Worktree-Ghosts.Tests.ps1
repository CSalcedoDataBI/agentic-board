#Requires -Modules Pester
<#  Pester tests for Worktree-Ghosts.ps1 - the orphan-worktree classifier (#618).

    The bug being pinned: the doctor's original check trusted git's `prunable` marker, which
    only ever describes "metadata present, directory gone". The directory that SURVIVES while
    git forgets it is the inverse, and it was invisible - so the two directions are asserted
    side by side here, and a regression that collapses them fails loudly.

    The second thing pinned is the safety line: `orphan-content` must never be auto-removable.
    That single predicate is what stands between an automatic sweep and somebody's work.

    Everything under test is pure - facts arrive as arguments, so no git, no gh, no filesystem.
#>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Worktree-Ghosts.ps1' | Resolve-Path
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = ''

    $script:HookScript = Join-Path $PSScriptRoot '..' 'scripts' 'Worktree-SessionStartHook.ps1' | Resolve-Path
    $env:ABIOS_WORKTREE_HOOK_DOTSOURCE = '1'
    . $script:HookScript
    $env:ABIOS_WORKTREE_HOOK_DOTSOURCE = ''
}

Describe 'Get-WorktreeGhostClass - the two directions of "ghost"' {
    It 'calls a listed worktree whose directory is present ok' {
        Get-WorktreeGhostClass -KnownToGit $true -PathExists $true | Should -Be 'ok'
    }
    It 'calls a listed worktree whose directory is gone prunable (git can see this one)' {
        Get-WorktreeGhostClass -KnownToGit $true -PathExists $false | Should -Be 'prunable'
    }
    It 'calls an EMPTY directory git does not know orphan-empty (the case that was invisible)' {
        Get-WorktreeGhostClass -KnownToGit $false -PathExists $true -IsEmpty $true |
            Should -Be 'orphan-empty'
    }
    It 'calls a directory WITH FILES that git does not know orphan-content' {
        Get-WorktreeGhostClass -KnownToGit $false -PathExists $true -IsEmpty $false |
            Should -Be 'orphan-content'
    }
    It 'does not invent an orphan when neither git nor the filesystem has anything' {
        Get-WorktreeGhostClass -KnownToGit $false -PathExists $false | Should -Be 'ok'
    }
    It 'never confuses the two ghost directions' {
        $prunable = Get-WorktreeGhostClass -KnownToGit $true  -PathExists $false
        $orphan   = Get-WorktreeGhostClass -KnownToGit $false -PathExists $true -IsEmpty $true
        $prunable | Should -Not -Be $orphan
    }
}

Describe 'Test-WorktreeAutoRemovable - the safety line' {
    It 'allows exactly one class to be removed without asking' {
        Test-WorktreeAutoRemovable -Class 'orphan-empty' | Should -BeTrue
    }
    It 'REFUSES to auto-remove an orphan that holds files' {
        # If this ever passes, the sweep can eat uncommitted work. It is the whole point.
        Test-WorktreeAutoRemovable -Class 'orphan-content' | Should -BeFalse
    }
    It 'refuses every other class' {
        foreach ($c in @('ok', 'prunable', '', 'ORPHAN-EMPTY')) {
            Test-WorktreeAutoRemovable -Class $c | Should -BeFalse
        }
    }
}

Describe 'ConvertTo-ComparablePath' {
    It 'makes the porcelain forward slashes match a Windows filesystem path' {
        $git = ConvertTo-ComparablePath 'C:/repo/.claude/worktrees/thing'
        $fs  = ConvertTo-ComparablePath 'C:\repo\.claude\worktrees\thing'
        $git | Should -Be $fs
    }
    It 'ignores a trailing separator and casing' {
        ConvertTo-ComparablePath 'C:\Repo\WT\' | Should -Be (ConvertTo-ComparablePath 'c:/repo/wt')
    }
    It 'survives an empty or null path without throwing' {
        ConvertTo-ComparablePath ''   | Should -Be ''
        ConvertTo-ComparablePath $null | Should -Be ''
    }
}

Describe 'Get-WorktreePathsFromPorcelain' {
    It 'extracts every worktree path and ignores the other porcelain fields' {
        $p = @(
            'worktree C:/repo'
            'HEAD abc123'
            'branch refs/heads/main'
            ''
            'worktree C:/repo/.claude/worktrees/alpha'
            'HEAD def456'
            'detached'
        ) -join "`n"
        $paths = Get-WorktreePathsFromPorcelain $p
        @($paths).Count | Should -Be 2
        $paths | Should -Contain (ConvertTo-ComparablePath 'C:/repo/.claude/worktrees/alpha')
    }
    It 'returns nothing for empty input instead of throwing' {
        @(Get-WorktreePathsFromPorcelain '').Count | Should -Be 0
    }
}

Describe 'Get-KnownWorktreeNames - the path-aliasing trap' {
    # Regression: the first version compared ABSOLUTE paths. Git prints the path it recorded,
    # the filesystem returns whatever alias you walked in through, the strings differ for the
    # same directory - and a LIVE worktree was classified orphan-content. Had it been empty the
    # hook would have deleted a worktree in use. Found by running it, not by reading it.
    It 'matches a live worktree even when git and the filesystem disagree on the prefix' {
        $porcelain = 'worktree C:/Users/Cristobal/repo/.claude/worktrees/sano'
        $names = Get-KnownWorktreeNames -Porcelain $porcelain
        $names | Should -Contain 'sano'
        # The disk side supplies only the leaf, so the 8.3 / junction prefix cannot break it.
        Get-WorktreeGhostClass -KnownToGit ($names -contains 'sano') -PathExists $true -IsEmpty $true |
            Should -Be 'ok'
    }
    It 'ignores worktrees that live outside the managed directory' {
        $porcelain = @(
            'worktree C:/repo'
            'worktree C:/repo--worktrees/manual-one'
            'worktree C:/repo/.claude/worktrees/managed-one'
        ) -join "`n"
        $names = Get-KnownWorktreeNames -Porcelain $porcelain
        $names | Should -Contain 'managed-one'
        $names | Should -Not -Contain 'manual-one'
        @($names).Count | Should -Be 1
    }
    It 'tolerates backslashes from a Windows-shaped porcelain' {
        $names = Get-KnownWorktreeNames -Porcelain 'worktree C:\repo\.claude\worktrees\alpha'
        $names | Should -Contain 'alpha'
    }
    It 'returns nothing when no worktree is managed' {
        @(Get-KnownWorktreeNames -Porcelain 'worktree C:/repo').Count | Should -Be 0
    }
}

Describe 'Select-StaleRegistryEntries - the machine-wide half' {
    It 'flags an entry whose path no longer exists' {
        $entries = @([pscustomobject]@{ Name = 'gone'; Path = 'C:/other-repo/.claude/worktrees/gone' })
        $map = @{ (ConvertTo-ComparablePath 'C:/other-repo/.claude/worktrees/gone') = $false }
        @(Select-StaleRegistryEntries -Entries $entries -ExistsMap $map).Count | Should -Be 1
    }
    It 'leaves an entry whose path is still there' {
        $entries = @([pscustomobject]@{ Name = 'live'; Path = 'C:/other-repo/.claude/worktrees/live' })
        $map = @{ (ConvertTo-ComparablePath 'C:/other-repo/.claude/worktrees/live') = $true }
        @(Select-StaleRegistryEntries -Entries $entries -ExistsMap $map).Count | Should -Be 0
    }
    It 'treats an unknown path as stale rather than silently assuming it is fine' {
        $entries = @([pscustomobject]@{ Name = 'unmapped'; Path = 'C:/x/y' })
        @(Select-StaleRegistryEntries -Entries $entries -ExistsMap @{}).Count | Should -Be 1
    }
    It 'skips entries with no path at all' {
        $entries = @([pscustomobject]@{ Name = 'broken'; Path = '' })
        @(Select-StaleRegistryEntries -Entries $entries -ExistsMap @{}).Count | Should -Be 0
    }
    It 'returns nothing for an empty registry' {
        @(Select-StaleRegistryEntries -Entries @() -ExistsMap @{}).Count | Should -Be 0
    }
}

Describe 'Worktree-SessionStartHook gating' {
    It 'sweeps after a session ended - startup and resume' {
        Test-ShouldSweepWorktrees 'startup' | Should -BeTrue
        Test-ShouldSweepWorktrees 'resume'  | Should -BeTrue
    }
    It 'does NOT sweep on compact, where the worktrees are still in use' {
        Test-ShouldSweepWorktrees 'compact' | Should -BeFalse
    }
    It 'does not sweep on an unknown or empty source' {
        Test-ShouldSweepWorktrees ''        | Should -BeFalse
        Test-ShouldSweepWorktrees 'unknown' | Should -BeFalse
    }
}

Describe 'Get-SweepContext' {
    It 'says nothing when nothing was removed - silence is the normal outcome' {
        Get-SweepContext @() | Should -BeNullOrEmpty
    }
    It 'names every removed path, so a delete is never invisible to the user' {
        $ctx = Get-SweepContext @('C:/repo/.claude/worktrees/alpha', 'C:/repo/.claude/worktrees/beta')
        $ctx | Should -Match 'alpha'
        $ctx | Should -Match 'beta'
        $ctx | Should -Match '2 empty orphan'
    }
    It 'uses the singular for one directory' {
        Get-SweepContext @('C:/repo/.claude/worktrees/solo') | Should -Match '1 empty orphan worktree directory'
    }
}
