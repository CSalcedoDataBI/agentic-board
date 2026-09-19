#Requires -Modules Pester
<#  Board-Doctor -Fix sweep (#548), the main working copy is never a teardown target (#555), and
    the installed-plugin drift check (#482).

    Real git, real worktrees, a real held file handle: the whole bug is what the OS and git do to
    each other, so a mock would only re-assert an assumption. #>

BeforeAll {
    $script:DoctorScript = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Doctor.ps1' | Resolve-Path
    $env:ABIOS_DOCTOR_DOTSOURCE = '1'
    . $script:DoctorScript
    $env:ABIOS_DOCTOR_DOTSOURCE = ''

    function script:New-SweepRepo {
        $root = Join-Path $TestDrive ('sw' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root | Out-Null
        $repo = Join-Path $root 'repo'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Push-Location $repo
        git init -q -b main 2>&1 | Out-Null
        'x' | Set-Content (Join-Path $repo 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base 2>&1 | Out-Null
        return @{ Root = $root; Repo = $repo }
    }
    function script:New-BranchWithWorktree {
        param($Ctx, [string]$Name)
        git branch $Name 2>&1 | Out-Null
        $wt = Join-Path $Ctx.Root $Name
        git worktree add -q $wt $Name 2>&1 | Out-Null
        return $wt
    }
    function script:New-Row { param($Branch, $Path = '') [pscustomobject]@{ Branch = $Branch; WorktreePath = $Path; Dirty = 'clean'; Pr = 1 } }
}

Describe 'Remove-BranchAndWorktree never aborts the sweep (#548)' {
    BeforeEach {
        $script:DoctorSkipped = @()
        $script:DoctorDeleted = 0
        $here = ''
        $DryRun = $false
        $script:Ctx = New-SweepRepo
        $script:Handle = $null
    }
    AfterEach {
        if ($script:Handle) { $script:Handle.Close(); $script:Handle = $null }
        Pop-Location
    }

    It 'skips the branch whose worktree cannot be removed and DELETES the ones queued after it' {
        # The failing removal is REAL: a deny-share handle inside the worktree, like a shell or an
        # indexer holding a file. Native failures are made fatal the way Windows PowerShell 5.1 makes
        # them under $ErrorActionPreference='Stop' (PS 7 spells it $PSNativeCommandUseErrorActionPreference).
        $wt1 = New-BranchWithWorktree $script:Ctx 'issue-1-stuck'
        git branch issue-2-plain 2>&1 | Out-Null
        $wt3 = New-BranchWithWorktree $script:Ctx 'issue-3-free'
        $script:Handle = [System.IO.File]::Open((Join-Path $wt1 'a.txt'), 'Open', 'Read', 'None')
        $rows = @((New-Row 'issue-1-stuck' $wt1), (New-Row 'issue-2-plain'), (New-Row 'issue-3-free' $wt3))

        $prevEap = $ErrorActionPreference; $prevNative = $PSNativeCommandUseErrorActionPreference
        $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
        try {
            { foreach ($r in $rows) { Remove-BranchAndWorktree -Row $r -BranchFlag '-D' | Out-Null } } | Should -Not -Throw
        } finally { $ErrorActionPreference = $prevEap; $PSNativeCommandUseErrorActionPreference = $prevNative }

        (git branch --list 'issue-2-plain') | Should -BeNullOrEmpty     # queued AFTER the stuck one
        # No exception was swallowed on the way: the failure was handled, not caught after the fact.
        @($script:DoctorSkipped | Where-Object { $_.Reason -match 'error inesperado' }).Count | Should -Be 0
        (git branch --list 'issue-3-free')  | Should -BeNullOrEmpty     # ...and after that
        $script:DoctorDeleted | Should -BeGreaterOrEqual 2
    }

    It 'a branch whose worktree git still registers is KEPT and named in the skip list' {
        $wt1 = New-BranchWithWorktree $script:Ctx 'issue-1-locked'
        git branch issue-2-plain 2>&1 | Out-Null
        git worktree lock $wt1 2>&1 | Out-Null
        try {
            $prevEap = $ErrorActionPreference; $prevNative = $PSNativeCommandUseErrorActionPreference
            $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
            try {
                { foreach ($r in @((New-Row 'issue-1-locked' $wt1), (New-Row 'issue-2-plain'))) { Remove-BranchAndWorktree -Row $r -BranchFlag '-D' | Out-Null } } | Should -Not -Throw
            } finally { $ErrorActionPreference = $prevEap; $PSNativeCommandUseErrorActionPreference = $prevNative }
            (git branch --list 'issue-1-locked') | Should -Not -BeNullOrEmpty   # kept: git still registers it
            (git branch --list 'issue-2-plain')  | Should -BeNullOrEmpty         # the sweep went on
            @($script:DoctorSkipped | Where-Object { $_.Branch -eq 'issue-1-locked' }).Count | Should -Be 1
        } finally { git worktree unlock $wt1 2>&1 | Out-Null }
    }

    It 'a failing `git branch -D` is recorded, not thrown, and the sweep continues' {
        # Deleting the branch checked out in the MAIN working copy fails in git itself.
        git branch issue-9-after 2>&1 | Out-Null
        $prevEap = $ErrorActionPreference; $prevNative = $PSNativeCommandUseErrorActionPreference
        $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
        try {
            { foreach ($r in @((New-Row 'main'), (New-Row 'issue-9-after'))) { Remove-BranchAndWorktree -Row $r -BranchFlag '-D' | Out-Null } } | Should -Not -Throw
        } finally { $ErrorActionPreference = $prevEap; $PSNativeCommandUseErrorActionPreference = $prevNative }
        (git branch --list 'main') | Should -Not -BeNullOrEmpty
        (git branch --list 'issue-9-after') | Should -BeNullOrEmpty
        @($script:DoctorSkipped | Where-Object { $_.Branch -eq 'main' }).Count | Should -Be 1
    }

    It 'does not retry a worktree an earlier run left HALF-REMOVED: skips it with the command that clears it' {
        # Half-removed: git dropped the worktree's `.git` link (so it lists it `prunable`) but the
        # folder is still there with content.
        $wt1 = New-BranchWithWorktree $script:Ctx 'issue-1-half'
        git branch issue-2-plain 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $wt1 '.git') -Force
        ((git worktree list --porcelain) -join "`n") | Should -Match 'prunable'
        Test-Path $wt1 | Should -BeTrue
        $log = ''
        foreach ($r in @((New-Row 'issue-1-half' $wt1), (New-Row 'issue-2-plain'))) { $log += (Remove-BranchAndWorktree -Row $r -BranchFlag '-D' *>&1 | Out-String) }
        # Detected UP FRONT (SKIP), not discovered by failing the same removal again (FAIL).
        $log | Should -Match 'SKIP'
        $log | Should -Not -Match 'FAIL'
        (git branch --list 'issue-1-half')  | Should -Not -BeNullOrEmpty
        (git branch --list 'issue-2-plain') | Should -BeNullOrEmpty
        $skip = @($script:DoctorSkipped | Where-Object { $_.Branch -eq 'issue-1-half' })
        $skip.Count | Should -Be 1
        $skip[0].Reason | Should -Match 'a medio borrar'
        $skip[0].Reason | Should -Match 'robocopy|rm -rf'
    }

    It 'still deletes an ordinary merged branch and its worktree (the happy path is not broken)' {
        $wt1 = New-BranchWithWorktree $script:Ctx 'issue-1-ok'
        $did = @(Remove-BranchAndWorktree -Row (New-Row 'issue-1-ok' $wt1) -BranchFlag '-D')
        (git branch --list 'issue-1-ok') | Should -BeNullOrEmpty
        Test-Path $wt1 | Should -BeFalse
        $script:DoctorSkipped.Count | Should -Be 0
        $script:DoctorDeleted | Should -Be 1
        ($did -join ' ') | Should -Match 'branch -D issue-1-ok'
    }

    It '-DryRun changes nothing and still plans the half-removed skip' {
        $DryRun = $true
        $wt1 = New-BranchWithWorktree $script:Ctx 'issue-1-dry'
        $did = @(Remove-BranchAndWorktree -Row (New-Row 'issue-1-dry' $wt1) -BranchFlag '-D')
        (git branch --list 'issue-1-dry') | Should -Not -BeNullOrEmpty
        Test-Path $wt1 | Should -BeTrue
        ($did -join ' ') | Should -Match 'worktree remove'
    }
}

Describe 'the same sweep under a REAL Windows PowerShell 5.1 host (#548)' {
    BeforeAll {
        $script:WinPs = @(
            Join-Path $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    }
    It 'does not abort when the first worktree cannot be removed' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'))) {
        $harness = Join-Path $TestDrive 'harness51.ps1'
        @'
param([string]$Doctor)
$ErrorActionPreference = 'Stop'
$env:ABIOS_DOCTOR_DOTSOURCE = '1'
. $Doctor
$env:ABIOS_DOCTOR_DOTSOURCE = ''
$root = Join-Path ([IO.Path]::GetTempPath()) ('abios51-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$repo = Join-Path $root 'repo'; New-Item -ItemType Directory -Path $repo | Out-Null
Set-Location $repo
git init -q 2>&1 | Out-Null
git config user.email t@t; git config user.name t
'x' | Set-Content a.txt; git add -A 2>&1 | Out-Null; git commit -q -m base 2>&1 | Out-Null
git branch issue-1-stuck; git branch issue-2-after
$wt = Join-Path $root 'wt1'
git worktree add -q $wt issue-1-stuck 2>&1 | Out-Null
$h = [IO.File]::Open((Join-Path $wt 'a.txt'), 'Open', 'Read', 'None')
$here = ''; $DryRun = $false
try {
    foreach ($b in @(@{ n = 'issue-1-stuck'; p = $wt }, @{ n = 'issue-2-after'; p = '' })) {
        Remove-BranchAndWorktree -Row ([pscustomobject]@{ Branch = $b.n; WorktreePath = $b.p; Dirty = 'clean'; Pr = 1 }) -BranchFlag '-D' | Out-Null
    }
    'RESULT after-branch-exists=' + [bool](git branch --list 'issue-2-after')
} catch {
    'RESULT ABORTED: ' + $_.Exception.Message.Split([char]10)[0]
} finally {
    $h.Close(); Set-Location $env:TEMP
    git -C $repo worktree prune 2>&1 | Out-Null
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
        $out = & $script:WinPs -NoProfile -ExecutionPolicy Bypass -File $harness -Doctor $script:DoctorScript 2>&1 | Out-String
        $out | Should -Match 'RESULT after-branch-exists=False'
    }
}

Describe 'Get-HalfRemovedWorktrees / Get-DoctorFixSummary (#548)' {
    It 'finds only a prunable worktree whose folder is still on disk' {
        $recs = @(
            [pscustomobject]@{ Path = 'C:/a'; Branch = 'x'; Prunable = 'gitdir file points to non-existent location' },
            [pscustomobject]@{ Path = 'C:/b'; Branch = 'y'; Prunable = 'gitdir file points to non-existent location' },
            [pscustomobject]@{ Path = 'C:/c'; Branch = 'z'; Prunable = '' })
        $half = @(Get-HalfRemovedWorktrees -Records $recs -PathExists { param($p) $p -eq 'C:/a' })
        $half.Count | Should -Be 1
        $half[0].Path | Should -Be 'C:/a'
    }
    It 'names every skipped branch and its reason in the summary, so the run is not read as a no-op' {
        $s = Get-DoctorFixSummary -Deleted 7 -Skipped @([pscustomobject]@{ Branch = 'issue-8-x'; Reason = 'worktree bloqueado' })
        $s.HadSkips | Should -BeTrue
        ($s.Lines -join "`n") | Should -Match '7 rama\(s\) borradas, 1 omitida'
        ($s.Lines -join "`n") | Should -Match 'issue-8-x\s+worktree bloqueado'
    }
    It 'reports a clean run as such' {
        $s = Get-DoctorFixSummary -Deleted 3
        $s.HadSkips | Should -BeFalse
        ($s.Lines -join "`n") | Should -Match '3 rama\(s\) borradas, 0 omitida'
    }
}

Describe 'Get-PluginDrift (#482) - content, not the version string' {
    BeforeAll {
        # A "published" repo: the plugin files committed LF under plugins/agentic-board.
        $script:Pub = Join-Path $TestDrive 'published'
        New-Item -ItemType Directory -Path $script:Pub | Out-Null
        $base = Join-Path $script:Pub 'plugins/agentic-board'
        foreach ($d in '.claude-plugin', 'scripts', 'hooks') { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $base '.claude-plugin/plugin.json'), "{`n  `"name`": `"agentic-board`",`n  `"version`": `"0.27.0`"`n}`n")
        [System.IO.File]::WriteAllText((Join-Path $base 'scripts/Brake-Guard.ps1'), "# brake`nfunction Test-Brake { 'released' }`n")
        [System.IO.File]::WriteAllText((Join-Path $base 'hooks/h.json'), "{}`n")
        [System.IO.File]::WriteAllBytes((Join-Path $base 'hooks/logo.bin'), [byte[]](0, 1, 2, 13, 3, 4))
        Push-Location $script:Pub
        git init -q -b main 2>&1 | Out-Null
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m pub 2>&1 | Out-Null
        $script:Sha = (git rev-parse HEAD)
        Pop-Location

        function script:New-Install {
            param([string]$Name, [switch]$Crlf)
            $dst = Join-Path $TestDrive $Name
            Copy-Item -LiteralPath (Join-Path $script:Pub 'plugins/agentic-board') -Destination $dst -Recurse
            if ($Crlf) {
                foreach ($f in (Get-ChildItem $dst -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.json' })) {
                    $t = [System.IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n" -replace "`n", "`r`n"
                    [System.IO.File]::WriteAllText($f.FullName, $t)
                }
            }
            New-Item -ItemType Directory -Path (Join-Path $dst '.in_use') | Out-Null
            'x' | Set-Content (Join-Path $dst '.in_use/12345')
            return $dst
        }
        function script:New-InstalledJson {
            param([string]$Path, [string]$Sha = $script:Sha, [string]$Version = '0.27.0')
            $json = Join-Path $TestDrive ('inst-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            @{ version = 2; plugins = @{ 'agentic-board@agentic-board' = @(@{ scope = 'user'; installPath = $Path; version = $Version; gitCommitSha = $Sha }) } } |
                ConvertTo-Json -Depth 6 | Set-Content $json
            return $json
        }
    }

    It 'a pristine install reports CLEAN (the direction that makes the check usable)' {
        $inst = New-Install 'pristine'
        $d = Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)
        $d.Status | Should -Be 'clean'
        $d.Modified.Count | Should -Be 0
        $d.InstalledVersion | Should -Be '0.27.0'
        $d.PublishedVersion | Should -Be '0.27.0'
    }
    It 'a pristine install whose text files were checked out CRLF is still CLEAN' {
        $inst = New-Install 'crlf' -Crlf
        (Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)).Status | Should -Be 'clean'
    }
    It 'a hand-patched file is DRIFTED and named - even though the version strings agree' {
        $inst = New-Install 'patched'
        Add-Content -LiteralPath (Join-Path $inst 'scripts/Brake-Guard.ps1') -Value "function Test-Brake { 'hand-patched' }"
        $d = Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)
        $d.Status | Should -Be 'drifted'
        $d.Modified | Should -Contain 'scripts/Brake-Guard.ps1'
        $d.InstalledVersion | Should -Be $d.PublishedVersion     # the 0.27.0-vs-0.27.0 incident
    }
    It 'a hand-ADDED file alone makes it drifted' {
        $inst = New-Install 'added'
        'extra' | Set-Content (Join-Path $inst 'scripts/Injected.ps1')
        $d = Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)
        $d.Status | Should -Be 'drifted'
        $d.Extra  | Should -Contain 'scripts/Injected.ps1'
        $d.Modified.Count | Should -Be 0
        $d.Missing.Count  | Should -Be 0
    }
    It 'a DELETED file alone makes it drifted' {
        $inst = New-Install 'deleted'
        Remove-Item (Join-Path $inst 'hooks/h.json')
        $d = Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)
        $d.Status  | Should -Be 'drifted'
        $d.Missing | Should -Contain 'hooks/h.json'
        $d.Extra.Count | Should -Be 0
    }
    It 'ignores the runtime .in_use markers (they are not plugin content)' {
        $inst = New-Install 'inuse'
        (Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub)).Extra | Should -Not -Contain '.in_use/12345'
    }
    It 'says UNVERIFIABLE, never clean, when no local clone holds the recorded commit' {
        $inst = New-Install 'nosha'
        $d = Get-PluginDrift -InstalledJson (New-InstalledJson $inst -Sha ('a' * 40)) -CandidateRepos @($script:Pub)
        $d.Status | Should -Be 'unverifiable'
        $d.Reason | Should -Match 'no esta en ningun clon local'
    }
    It 'says UNVERIFIABLE when the install records no commit at all' {
        $inst = New-Install 'nocommit'
        (Get-PluginDrift -InstalledJson (New-InstalledJson $inst -Sha '') -CandidateRepos @($script:Pub)).Status | Should -Be 'unverifiable'
    }
    It 'reports not-installed when the plugin is not in installed_plugins.json' {
        (Get-PluginDrift -PluginName 'nonexistent-plugin' -InstalledJson (New-InstalledJson (Join-Path $TestDrive 'x')) -CandidateRepos @($script:Pub)).Status | Should -Be 'not-installed'
    }
    It 'the report names the differing file and both versions' {
        $inst = New-Install 'report'
        Add-Content -LiteralPath (Join-Path $inst 'scripts/Brake-Guard.ps1') -Value '# patched'
        $lines = Format-PluginDrift -Drift (Get-PluginDrift -InstalledJson (New-InstalledJson $inst) -CandidateRepos @($script:Pub))
        ($lines -join "`n") | Should -Match 'scripts/Brake-Guard.ps1'
        ($lines -join "`n") | Should -Match 'instalado 0\.27\.0'
        ($lines -join "`n") | Should -Match 'publicado en ese commit: 0\.27\.0'
    }
    It 'Compare-PluginTree: a file whose content differs matches neither spelling' {
        $pub = @{ 'a.ps1' = (Get-GitBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes("one`n"))) }
        $same = @{ 'a.ps1' = @{ Raw = $pub['a.ps1']; Lf = $pub['a.ps1'] } }
        $diff = @{ 'a.ps1' = @{ Raw = 'deadbeef'; Lf = 'deadbeef' } }
        (Compare-PluginTree -Installed $same -Published $pub).Modified.Count | Should -Be 0
        (Compare-PluginTree -Installed $diff -Published $pub).Modified | Should -Contain 'a.ps1'
    }
}
