#Requires -Modules Pester
<#  Safe cleanup of old cached plugin builds (epic #711, task #715).

    The cleanup deletes directories, so these tests are about what it REFUSES to delete. Every case runs
    the real planning and deleting code over a fabricated Claude home: a build is removed only when it is
    not installed, no live process holds a marker in it, and its real path is strictly inside
    cache/<marketplace>/<plugin>/. Any doubt keeps it. A final pair of tests runs the real script as a
    process, to prove the default is a listing and only -Execute deletes.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Board-Work.ps1')
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    . (Join-Path $script:Scripts 'PluginState.ps1')
    $env:ABIOS_PLUGINCLEAN_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Remove-OldPluginVersions.ps1')
    $env:ABIOS_PLUGINCLEAN_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    function script:New-Fx { New-FakeHome -Root (Join-Path $TestDrive ("h" + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    # A fixture with plugin p@m: 2.0 installed, 1.0 an old build nobody holds.
    function script:New-CleanFx {
        $fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0')
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed)
        return $fx
    }
    function script:Get-Item-Of($plan, $ver) { @($plan.Items | Where-Object { $_.Version -eq $ver })[0] }
    $script:MyFt = Get-MyFileTimeText
    $script:Gone = New-FakeProcessTable @{}          # no process exists
}

Describe 'Get-VersionCleanupPlan - what may be removed' {
    It 'an old build nobody holds is removable; the installed build is kept' {
        $fx = New-CleanFx
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        $plan.Ok | Should -BeTrue
        (Get-Item-Of $plan '1.0').Action | Should -Be 'remove'
        (Get-Item-Of $plan '2.0').Action | Should -Be 'keep'
        (Get-Item-Of $plan '2.0').Category | Should -Be 'installed'
    }
    It 'the INSTALLED version is never removed - not even with dead markers and an old timestamp' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 555 -StartFt '134300000000000000'
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan '2.0').Action | Should -Be 'keep'
    }
    It 'the installed build is recognised by its real path even when the version label differs' {
        $fx = New-Fx
        $dir = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version 'abc123def456'
        $fx.Installed.Add([pscustomobject]@{ Key = 'p@m'; Scope = 'user'; InstallPath = $dir; Version = 'labelled-differently'; Sha = '' })
        Write-FakeRegistries $fx
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan 'abc123def456').Action | Should -Be 'keep'
    }
    It 'a build held by a LIVE process (pid and start time match) is kept' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId $PID -StartFt $script:MyFt
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
        (Get-Item-Of $plan '1.0').Category | Should -Be 'in-use'
    }
    It 'a marker of a RECYCLED pid (the number now belongs to a later process) does not hold the build' {
        $fx = New-CleanFx
        $earlier = [string]([datetime]::FromFileTime([long]$script:MyFt).AddHours(-5).ToFileTime())
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId $PID -StartFt $earlier
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root
        (Get-Item-Of $plan '1.0').Action | Should -Be 'remove'
    }
    It 'a STALE marker (its process is gone) does not hold the build' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4242 -StartFt '134300000000000000'
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan '1.0').Action | Should -Be 'remove'
    }
    It 'one live holder among many dead ones is enough to keep it' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4242 -StartFt '134300000000000000'
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4343 -StartFt '134300000000000000'
        $table = New-FakeProcessTable @{ [long]4343 = '134300000000000000' }
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $table
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
    }
    It 'an UNREADABLE marker keeps the build (any doubt = keep)' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4242 -StartFt '' -RawBody '{ not json'
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
        (Get-Item-Of $plan '1.0').Category | Should -Be 'unknown-holder'
    }
    It 'a marker with no start time keeps the build: without it a recycled pid cannot be told from the holder' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4242 -StartFt '' -RawBody '{"pid":4242}'
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
    }
    It 'a holder whose liveness cannot be confirmed keeps the build' {
        $fx = New-CleanFx
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 4242 -StartFt '134300000000000000'
        $guarded = { param($id) $o = [pscustomobject]@{}; $o | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'denied' }; $o }
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $guarded
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
    }
    It 'a build touched in the last hour is kept (an install in progress is not in the list yet)' {
        $fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed)
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version 'fresh' -AgeHours 0)
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan 'fresh').Action | Should -Be 'keep'
        (Get-Item-Of $plan 'fresh').Category | Should -Be 'recent'
    }
    It 'REFUSES everything when installed_plugins.json cannot be read' {
        $fx = New-CleanFx
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'installed_plugins.json'), '{ nope')
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        $plan.Ok | Should -BeFalse
        @($plan.Items).Count | Should -Be 0
    }
    It 'REFUSES everything when the installed list is empty (every build would look orphaned)' {
        $fx = New-CleanFx
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'installed_plugins.json'), '{"version":2,"plugins":{}}')
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        $plan.Ok | Should -BeFalse
    }
}

Describe 'links and paths outside the cache are refused' {
    BeforeAll {
        # A link to a directory holding a file that must survive. Symlinks need a privilege on Windows,
        # so fall back to a junction; skip when neither can be created.
        function script:New-DirLink([string]$Link, [string]$Target) {
            try { New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }
            try { New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }
            return $false
        }
    }
    It 'a build directory that is a LINK to somewhere else is kept, and its target is untouched by cleanup' {
        $fx = New-CleanFx
        $outside = Join-Path $TestDrive ("outside" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outside 'precious.txt'), 'keep me')
        $link = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' 'linked'
        if (-not (New-DirLink $link $outside)) { Set-ItResult -Skipped -Because 'cannot create a symlink or junction here'; return }
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan 'linked').Action | Should -Be 'keep'
        (Get-Item-Of $plan 'linked').Category | Should -Be 'link'
        [void](Invoke-PluginCleanup -Plan $plan -ClaudeHome $fx.Root)
        Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
        Test-Path -LiteralPath $link | Should -BeTrue
        # and the deleting function itself refuses the link even when handed it directly
        (Remove-PluginVersionDir -Path $link -ClaudeHome $fx.Root).Removed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
    }
    It 'a build directory with a link INSIDE it is kept' {
        $fx = New-CleanFx
        $outside = Join-Path $TestDrive ("outside" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outside 'precious.txt'), 'keep me')
        $old = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0'
        if (-not (New-DirLink (Join-Path $old 'inner-link') $outside)) { Set-ItResult -Skipped -Because 'cannot create a symlink or junction here'; return }
        (Get-Item (Join-Path $old 'inner-link') -Force).LastWriteTime = (Get-Date).AddHours(-48)
        $plan = Get-VersionCleanupPlan -ClaudeHome $fx.Root -GetProcess $script:Gone
        (Get-Item-Of $plan '1.0').Action | Should -Be 'keep'
        (Get-Item-Of $plan '1.0').Category | Should -Be 'link'
    }
    It 'Remove-PluginVersionDir refuses a path OUTSIDE the cache' {
        $fx = New-CleanFx
        $outside = Join-Path $TestDrive ("victim" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $outside 'a' 'b') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outside 'a' 'b' 'f.txt'), 'x')
        $r = Remove-PluginVersionDir -Path (Join-Path $outside 'a' 'b') -ClaudeHome $fx.Root
        $r.Removed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'a' 'b' 'f.txt') | Should -BeTrue
    }
    It 'Remove-PluginVersionDir refuses a ..-traversal that lands outside <m>/<p>' {
        $fx = New-CleanFx
        # A traversal that climbs out of the cache entirely and lands on the sessions folder.
        $climb = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0' '..' '..' '..' '..' '..' 'sessions'
        (Remove-PluginVersionDir -Path $climb -ClaudeHome $fx.Root).Removed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'sessions') | Should -BeTrue
    }
    It 'Remove-PluginVersionDir refuses the plugin folder, the marketplace folder, the cache root and the Claude home' {
        $fx = New-CleanFx
        foreach ($p in @(
            (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p'),
            (Join-Path $fx.Root 'plugins' 'cache' 'm'),
            (Join-Path $fx.Root 'plugins' 'cache'),
            $fx.Root)) {
            (Remove-PluginVersionDir -Path $p -ClaudeHome $fx.Root).Removed | Should -BeFalse -Because "$p is not a build folder"
            Test-Path -LiteralPath $p | Should -BeTrue
        }
    }
    It 'Remove-PluginVersionDir removes a genuine build folder' {
        $fx = New-CleanFx
        $old = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0'
        (Remove-PluginVersionDir -Path $old -ClaudeHome $fx.Root).Removed | Should -BeTrue
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '2.0') | Should -BeTrue
    }
    It 'Test-PathStrictlyInside: a sibling with the same name prefix is not inside; the parent itself is not inside' {
        $fx = New-Fx
        $a = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p'
        $b = Join-Path $fx.Root 'plugins' 'cache' 'm' 'p2'
        New-Item -ItemType Directory -Force -Path (Join-Path $a 'v'), $b | Out-Null
        Test-PathStrictlyInside -Child (Join-Path $a 'v') -Parent $a | Should -BeTrue
        Test-PathStrictlyInside -Child $b -Parent $a | Should -BeFalse
        Test-PathStrictlyInside -Child $a -Parent $a | Should -BeFalse
        Test-PathStrictlyInside -Child (Join-Path $a 'v') -Parent $a -DirectChild | Should -BeTrue
        Test-PathStrictlyInside -Child (Join-Path $a 'v') -Parent (Split-Path $a -Parent) -DirectChild | Should -BeFalse
    }
    It 'Test-PathStrictlyInside sees through an 8.3 short name (string compare would not)' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because '8.3 short names exist only on Windows'; return }
        $short = $env:TEMP
        if ($short -notmatch '~') { Set-ItResult -Skipped -Because 'TEMP has no 8.3 short form on this machine'; return }
        $fx = New-Fx
        $child = Join-Path $fx.Root 'x'
        New-Item -ItemType Directory -Force -Path $child | Out-Null
        $shortChild = $child.Replace((Get-Item -LiteralPath $env:TEMP).FullName, $short)
        if ($shortChild -eq $child) { Set-ItResult -Skipped -Because 'could not build a short-name spelling'; return }
        Test-PathStrictlyInside -Child $shortChild -Parent $fx.Root | Should -BeTrue
    }
}

Describe 'the script: default is a listing, only -Execute deletes' {
    BeforeAll {
        $script:Script = Join-Path $script:Scripts 'Remove-OldPluginVersions.ps1'
    }
    It 'without -Execute it deletes nothing, says so, and exits 0' {
        $fx = New-CleanFx
        $out = pwsh -NoProfile -File $script:Script -ClaudeHome $fx.Root 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'NO se ha borrado nada'
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0') | Should -BeTrue
    }
    It 'with -Execute it deletes the unused build and keeps the installed one' {
        $fx = New-CleanFx
        # a live holder (this very process) on a third build
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version 'held')
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version 'held' -ProcId $PID -StartFt $script:MyFt
        $out = pwsh -NoProfile -File $script:Script -ClaudeHome $fx.Root -Execute 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '2.0') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' 'held') | Should -BeTrue
        $out | Should -Match 'Borradas: 1'
    }
}
