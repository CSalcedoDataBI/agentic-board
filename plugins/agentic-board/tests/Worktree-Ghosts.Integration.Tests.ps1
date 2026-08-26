#Requires -Modules Pester
<#  Integration tests for Worktree-Ghosts.ps1 against a REAL git repo (#618).

    WHY THIS FILE EXISTS, separate from the pure suite. Two bugs shipped past a fully green pure
    suite because every pure test supplied the porcelain by hand:

      1. Absolute-path comparison. Git prints the path it recorded; the filesystem returns the
         alias you walked in through (8.3 short name, junction, subst drive). A LIVE worktree was
         classified as an orphan.
      2. `[string]$Porcelain` defaulting. An unbound [string] parameter is '', never $null, so the
         "should I call git?" guard never fired, the known-set stayed empty, and EVERY worktree
         looked orphaned.

    Both are invisible to a test that hands the function its inputs. The only thing that catches
    them is walking a real repo through the real entry point - so that is what this does.

    Skipped wholesale when git is unavailable, so the pure suite still runs anywhere.
#>

# Evaluated during DISCOVERY, which is when Pester 5 reads every -Skip: expression - a full
# phase before any BeforeAll runs. Computing this inside BeforeAll leaves the flag $null at
# discovery, `-not $null` is $true, and the whole file silently skips while reporting success.
$HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$IsWindowsHost = ($env:OS -eq 'Windows_NT')

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Worktree-Ghosts.ps1' | Resolve-Path
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = ''

    $script:HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

    if ($script:HasGit) {
        $script:Repo = Join-Path ([IO.Path]::GetTempPath()) ("abios-wt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null

        Push-Location $script:Repo
        git init -q .                          2>&1 | Out-Null
        git config user.email 'test@example.invalid'
        git config user.name  'test'
        git config commit.gpgsign false
        Set-Content -Path (Join-Path $script:Repo 'a.txt') -Value 'seed'
        git add .                              2>&1 | Out-Null
        git commit -qm 'seed'                  2>&1 | Out-Null

        $wtRoot = Join-Path $script:Repo '.claude/worktrees'
        New-Item -ItemType Directory -Path $wtRoot -Force | Out-Null

        # A worktree git genuinely manages.
        git worktree add -q (Join-Path $wtRoot 'live') -b live-branch 2>&1 | Out-Null
        # An orphan with nothing in it - the sweepable class.
        New-Item -ItemType Directory -Path (Join-Path $wtRoot 'orphan-empty') -Force | Out-Null
        # An orphan holding a file - must never be swept.
        $withWork = Join-Path $wtRoot 'orphan-with-work'
        New-Item -ItemType Directory -Path $withWork -Force | Out-Null
        Set-Content -Path (Join-Path $withWork 'uncommitted.txt') -Value 'work nobody wants to lose'
        Pop-Location
    }
}

AfterAll {
    if ($script:Repo -and (Test-Path $script:Repo)) {
        Push-Location $script:Repo
        git worktree remove --force (Join-Path $script:Repo '.claude/worktrees/live') 2>&1 | Out-Null
        Pop-Location
        Remove-Item -LiteralPath $script:Repo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-WorktreeGhosts against a real repo' -Skip:(-not $HasGit) {

    It 'does NOT report the worktree git is managing' {
        # Bug #1 and #2 both surfaced right here: `live` came back as an orphan.
        $g = @(Get-WorktreeGhosts -RepoRoot $script:Repo)
        ($g | Where-Object { $_.Name -eq 'live' }) | Should -BeNullOrEmpty
    }

    It 'finds the empty orphan and marks it auto-removable' {
        $g = @(Get-WorktreeGhosts -RepoRoot $script:Repo) | Where-Object { $_.Name -eq 'orphan-empty' }
        $g              | Should -Not -BeNullOrEmpty
        $g.Class        | Should -Be 'orphan-empty'
        $g.AutoRemovable| Should -BeTrue
    }

    It 'finds the orphan holding a file and refuses to mark it auto-removable' {
        $g = @(Get-WorktreeGhosts -RepoRoot $script:Repo) | Where-Object { $_.Name -eq 'orphan-with-work' }
        $g              | Should -Not -BeNullOrEmpty
        $g.Class        | Should -Be 'orphan-content'
        $g.AutoRemovable| Should -BeFalse
    }

    It 'calls git when no porcelain is supplied (an unbound [string] is "", not $null)' {
        # Pin the exact defaulting bug: omitting -Porcelain must mean "go ask git", never
        # "assume there are no worktrees" - the latter orphans everything.
        $g = @(Get-WorktreeGhosts -RepoRoot $script:Repo)
        @($g).Count | Should -Be 2      # the two orphans, and never `live`
    }

    It 'reaches the same verdict through an 8.3-shortened path' -Skip:(-not $IsWindowsHost) {
        # The alias trap, exercised for real: same directory, different string.
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($script:Repo).ShortPath
        if ($short -and $short -ne $script:Repo) {
            $g = @(Get-WorktreeGhosts -RepoRoot $short)
            ($g | Where-Object { $_.Name -eq 'live' }) | Should -BeNullOrEmpty
            @($g).Count | Should -Be 2
        }
    }
}

Describe 'Remove-EmptyWorktreeOrphan is guarded by the filesystem' -Skip:(-not $HasGit) {

    It 'refuses a directory that holds a file, and leaves the file untouched' {
        $withWork = Join-Path $script:Repo '.claude/worktrees/orphan-with-work'
        $file     = Join-Path $withWork 'uncommitted.txt'
        Remove-EmptyWorktreeOrphan -Path $withWork | Should -BeFalse
        Test-Path $withWork | Should -BeTrue
        Test-Path $file     | Should -BeTrue
        Get-Content $file   | Should -Be 'work nobody wants to lose'
    }

    It 'removes an empty orphan' {
        $empty = Join-Path $script:Repo '.claude/worktrees/orphan-empty'
        Remove-EmptyWorktreeOrphan -Path $empty | Should -BeTrue
        Test-Path $empty | Should -BeFalse
    }
}
