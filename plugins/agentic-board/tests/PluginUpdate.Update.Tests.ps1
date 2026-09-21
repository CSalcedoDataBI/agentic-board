#Requires -Modules Pester
<#  Update every installed plugin in one pass and report what changed (epic #711, task #712).

    The claude CLI is NEVER run here: Invoke-PluginUpdate takes an injectable runner, and these tests hand
    it a fake that records the commands it was given and, where the scenario says an update succeeded,
    really rewrites the fabricated installed_plugins.json. The verdict per plugin is derived from that file
    before and after, so a fake that "succeeds" without changing anything must read as unchanged, and a
    fake that fails must never read as up to date.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Board-Work.ps1')
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    . (Join-Path $script:Scripts 'PluginState.ps1')
    $env:ABIOS_PLUGINUPDATE_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Update-AllPlugins.ps1')
    $env:ABIOS_PLUGINUPDATE_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    function script:New-Fx { New-FakeHome -Root (Join-Path $TestDrive ("h" + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    function script:New-Run([int]$Code = 0, [string]$Out = 'ok', [bool]$TimedOut = $false) { [pscustomobject]@{ ExitCode = $Code; Output = $Out; TimedOut = $TimedOut } }

    # A runner that logs every command line and answers from $Behavior (command text -> answer). An answer
    # is a scriptblock returning a run, or a hashtable: @{ Bump = ...} makes the update REALLY change what is
    # installed (the same key now points at a new build directory), @{ Remove = ...} makes the plugin vanish.
    # (Plain scriptblocks on purpose: a closure could not see the helper functions of this file.)
    function script:New-FakeRunner {
        param([System.Collections.Generic.List[string]]$Log, [hashtable]$Behavior = @{})
        $script:RunnerLog = $Log
        $script:RunnerBehavior = $Behavior
        return { param($cliArgs)
            $key = ($cliArgs -join ' ')
            $script:RunnerLog.Add($key)
            $b = $script:RunnerBehavior[$key]
            if ($null -eq $b) { return (New-Run 0 'ok') }
            if ($b -is [scriptblock]) { return (& $b) }
            if ($b.ContainsKey('Bump'))   { return (Invoke-FakeBump $b.Bump $b.Key $b.Version $b.Sha $b.Changelog) }
            if ($b.ContainsKey('Remove')) { return (Invoke-FakeRemove $b.Remove $b.Key) }
            return (New-Run 0 'ok')
        }
    }
    function script:Invoke-FakeBump($Fx, [string]$Key, [string]$NewVersion, [string]$NewSha, [string]$Changelog) {
        $parts = $Key -split '@'
        $dir = Join-Path $Fx.Root 'plugins' 'cache' $parts[1] $parts[0] $NewVersion
        New-Item -ItemType Directory -Force -Path (Join-Path $dir '.claude-plugin') | Out-Null
        if ($Changelog) { [System.IO.File]::WriteAllText((Join-Path $dir 'CHANGELOG.md'), $Changelog) }
        Set-FakeInstalledBuild $Fx -Key $Key -Version $NewVersion -Sha $NewSha
        return (New-Run 0 "updated $Key")
    }
    function script:Invoke-FakeRemove($Fx, [string]$Key) {
        [void]$Fx.Installed.RemoveAll([Predicate[object]]{ param($e) $e.Key -eq $Key })
        Write-FakeRegistries $Fx
        return (New-Run 0 'ok')
    }
    function script:Get-Bump($Fx, [string]$Key, [string]$NewVersion, [string]$NewSha, [string]$Changelog = '') {
        return @{ Bump = $Fx; Key = $Key; Version = $NewVersion; Sha = $NewSha; Changelog = $Changelog }
    }
    # Three marketplaces (two git, one local directory) and four plugins.
    function script:New-UpdateFx {
        $fx = New-Fx
        Add-FakeMarketplace $fx -Name 'mk-a'
        Add-FakeMarketplace $fx -Name 'mk-b'
        Add-FakeMarketplace $fx -Name 'mk-dev' -Kind 'directory'
        [void](Add-FakeBuild $fx -Marketplace 'mk-a' -Plugin 'alpha' -Version '1.0.0' -Installed -Sha 'aaaaaaa1111111')
        [void](Add-FakeBuild $fx -Marketplace 'mk-a' -Plugin 'beta' -Version '2.0.0' -Installed -Sha 'ccccccc2222222')
        [void](Add-FakeBuild $fx -Marketplace 'mk-b' -Plugin 'gamma' -Version '3.0.0' -Installed -Sha 'ddddddd3333333')
        [void](Add-FakeBuild $fx -Marketplace 'mk-dev' -Plugin 'devp' -Version '0.1.0' -Installed)
        return $fx
    }
    function script:Get-PluginRow($r, $name) { @($r.Plugins | Where-Object Plugin -eq $name)[0] }
    function script:Get-ReportText($r) { (Format-PluginUpdateReport -Result $r | ForEach-Object Text) -join "`n" }
    $script:Gone = New-FakeProcessTable @{}
}

Describe 'Invoke-PluginUpdate - marketplaces first, then every plugin, verdict from the installed list' {
    It 'refreshes every marketplace, then updates every installed plugin, and reports old -> new with the commit' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = (Get-Bump $fx 'alpha@mk-a' '1.1.0' 'bbbbbbb9999999') }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        # marketplaces come before plugins, all three refreshed
        @($log | Where-Object { $_ -like 'plugin marketplace update*' }).Count | Should -Be 3
        $log.IndexOf('plugin update alpha@mk-a') | Should -BeGreaterThan $log.IndexOf('plugin marketplace update mk-dev')
        (Get-PluginRow $r 'alpha').Status | Should -Be 'updated'
        (Get-PluginRow $r 'beta').Status | Should -Be 'unchanged'
        $text = Get-ReportText $r
        $text | Should -Match 'alpha@mk-a: 1\.0\.0 \(aaaaaaa\) -> 1\.1\.0 \(bbbbbbb\)'
        $text | Should -Match 'Sin cambios .*beta'
        $r.ExitCode | Should -Be 0
    }
    It 'a failed update is FAILED with its reason, never "unchanged", and the exit code is non-zero' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update gamma@mk-b' = { New-Run 1 "boom`nfatal: could not reach the server" } }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        $g = Get-PluginRow $r 'gamma'
        $g.Status | Should -Be 'failed'
        $g.Failure | Should -BeTrue
        $g.Reason | Should -Match 'could not reach the server'
        $r.ExitCode | Should -Be 1
        $text = Get-ReportText $r
        $text | Should -Match 'NO se pudieron actualizar'
        $text | Should -Match 'gamma@mk-b: .*could not reach'
        ($text -split "`n" | Where-Object { $_ -match '^Sin cambios' }) | Should -Not -Match 'gamma'
    }
    It 'a timeout is a failure, not a success' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update beta@mk-a' = { New-Run -1 '' $true } }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'beta').Status | Should -Be 'failed'
        (Get-PluginRow $r 'beta').Reason | Should -Match 'tiempo'
        $r.ExitCode | Should -Be 1
    }
    It 'exit 0 with the installed list unchanged is "unchanged" even if the CLI output claims an update' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = { New-Run 0 'Updated alpha to 9.9.9!' } }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'alpha').Status | Should -Be 'unchanged'
    }
    It 'exit 0 but the plugin is missing from the installed list afterwards is FAILED (cannot vouch for it)' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = @{ Remove = $fx; Key = 'alpha@mk-a' } }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'alpha').Status | Should -Be 'failed'
        $r.ExitCode | Should -Be 1
    }
    It 'a marketplace that fails to refresh: its plugins are NOT updated, are skipped as failures, and never read as up to date' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin marketplace update mk-a' = { New-Run 1 'network unreachable' } }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        $log | Should -Not -Contain 'plugin update alpha@mk-a'
        $log | Should -Not -Contain 'plugin update beta@mk-a'
        $log | Should -Contain 'plugin update gamma@mk-b'
        foreach ($n in 'alpha', 'beta') {
            (Get-PluginRow $r $n).Status | Should -Be 'skipped'
            (Get-PluginRow $r $n).Failure | Should -BeTrue
        }
        $r.ExitCode | Should -Be 1
        $text = Get-ReportText $r
        $text | Should -Match 'NO se pudieron actualizar'
        $text | Should -Match 'network unreachable'
        ($text -split "`n" | Where-Object { $_ -match '^Sin cambios' }) | Should -Not -Match 'alpha|beta'
    }
    It 'a local-directory marketplace that fails to refresh is only a WARNING: its plugin is still updated and the run passes' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{
            'plugin marketplace update mk-dev' = { New-Run 1 'not a git checkout' }
            'plugin update devp@mk-dev' = (Get-Bump $fx 'devp@mk-dev' '0.2.0' '')
        }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'devp').Status | Should -Be 'updated'
        $r.ExitCode | Should -Be 0
        $text = Get-ReportText $r
        $text | Should -Match 'mk-dev \(carpeta local, solo aviso\)'
    }
    It 'does NOT pass --yes unless -AcceptMarketplaceCommands is given' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        [void](Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log) -GetProcess $script:Gone)
        @($log | Where-Object { $_ -match '--yes' }).Count | Should -Be 0
        $log2 = [System.Collections.Generic.List[string]]::new()
        [void](Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log2) -GetProcess $script:Gone -AcceptMarketplaceCommands)
        $log2 | Should -Contain 'plugin update alpha@mk-a --yes'
    }
    It 'a plugin installed only for a project scope is skipped without failing the run' {
        $fx = New-UpdateFx
        [void](Add-FakeBuild $fx -Marketplace 'mk-a' -Plugin 'projonly' -Version '1.0' -Installed -Scope 'project')
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        (Get-PluginRow $r 'projonly').Status | Should -Be 'skipped'
        (Get-PluginRow $r 'projonly').Failure | Should -BeFalse
        $log | Should -Not -Contain 'plugin update projonly@mk-a'
        $r.ExitCode | Should -Be 0
    }
    It 'a plugin whose marketplace is no longer registered is skipped, not "up to date"' {
        $fx = New-UpdateFx
        [void](Add-FakeBuild $fx -Marketplace 'ghost-market' -Plugin 'orphan' -Version '1.0' -Installed)
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        (Get-PluginRow $r 'orphan').Status | Should -Be 'skipped'
        (Get-PluginRow $r 'orphan').Reason | Should -Match 'ya no esta registrado'
    }
    It '-Only limits the run to that plugin and to the marketplace it belongs to' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Only 'gamma' -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        @($r.Plugins).Count | Should -Be 1
        $log | Should -Be @('plugin marketplace update mk-b', 'plugin update gamma@mk-b')
    }
    It '-Only accepts plugin@marketplace and is case-insensitive' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Only 'ALPHA@mk-a' -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        @($r.Plugins).Count | Should -Be 1
        (Get-PluginRow $r 'alpha') | Should -Not -BeNullOrEmpty
    }
    It '-Only that matches nothing is a failure, not a silent success' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Only 'nope' -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        $r.ExitCode | Should -Be 1
        $r.Fatal | Should -Match 'nope'
        $log.Count | Should -Be 0
    }
    It '-DryRun runs NOTHING (the runner is never called) and lists the commands' {
        $fx = New-UpdateFx
        $boom = { throw 'the runner must not be called in a dry run' }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -DryRun -Runner $boom -GetProcess $script:Gone
        $r.ExitCode | Should -Be 0
        $r.Commands | Should -Contain 'claude plugin update alpha@mk-a'
        $r.Commands | Should -Contain 'claude plugin marketplace update mk-dev'
        (Get-ReportText $r) | Should -Match 'SIMULACION'
        (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries | Where-Object Key -eq 'alpha@mk-a' | ForEach-Object Version | Should -Be '1.0.0'
    }
    It 'unreadable installed_plugins.json is a clear failure, not an empty success' {
        $fx = New-UpdateFx
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'installed_plugins.json'), '{ nope')
        $log = [System.Collections.Generic.List[string]]::new()
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log) -GetProcess $script:Gone
        $r.ExitCode | Should -Be 1
        $log.Count | Should -Be 0
        (Get-ReportText $r) | Should -Match 'No pude actualizar'
    }
}

Describe 'the report ends with how many open sessions still run old builds' {
    It 'counts an open session that loaded the old build of a plugin the run just updated' {
        $fx = New-UpdateFx
        $ft = '134344744676615681'
        [void](Add-FakeSession $fx -ProcId 111 -StartFt $ft -Name 'Open session')
        Add-FakeMarker $fx -Marketplace 'mk-a' -Plugin 'alpha' -Version '1.0.0' -ProcId 111 -StartFt $ft
        $table = New-FakeProcessTable @{ [long]111 = $ft }
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = (Get-Bump $fx 'alpha@mk-a' '1.1.0' 'bbbbbbb9999999') }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $table
        $r.Sessions.Stale | Should -Be 1
        $text = Get-ReportText $r
        $text | Should -Match 'Sesiones abiertas: 1\. 1 siguen con una version vieja'
        $text | Should -Match '/board plugins sessions'
    }
    It 'a session with no record of what it loaded is reported as "sin datos", not as up to date' {
        $fx = New-UpdateFx
        $ft = '134344744676615681'
        [void](Add-FakeSession $fx -ProcId 111 -StartFt $ft -Name 'Blind')
        $table = New-FakeProcessTable @{ [long]111 = $ft }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner ([System.Collections.Generic.List[string]]::new())) -GetProcess $table
        $r.Sessions.NoData | Should -Be 1
        (Get-ReportText $r) | Should -Match '0 al dia, 1 sin datos'
    }
}

Describe 'the "what is new" excerpt is bounded, optional and plain' {
    It 'takes the section of the NEW version from the plugin''s own changelog' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $cl = "# Changelog`n`n## [1.1.0] - 2026-09-01`n### Added`n- Faster refresh`n- New chart`n`n## [1.0.0] - 2026-08-01`n- Old thing`n"
        $beh = @{ 'plugin update alpha@mk-a' = (Get-Bump $fx 'alpha@mk-a' '1.1.0' 'bbbbbbb9999999' $cl) }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        $ex = (Get-PluginRow $r 'alpha').Excerpt
        $ex | Should -Match 'Faster refresh'
        $ex | Should -Match 'New chart'
        $ex | Should -Not -Match 'Old thing'
        (Get-ReportText $r) | Should -Match 'Que hay de nuevo'
    }
    It 'no changelog at all is fine: no excerpt, no failure' {
        $fx = New-UpdateFx
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = (Get-Bump $fx 'alpha@mk-a' '1.1.0' 'bbbbbbb9999999') }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'alpha').Status | Should -Be 'updated'
        (Get-PluginRow $r 'alpha').Excerpt | Should -Be ''
        $r.ExitCode | Should -Be 0
    }
    It 'falls back to the marketplace checkout when the plugin folder ships no notes (monorepo layout)' {
        $fx = New-UpdateFx
        $mk = (Get-KnownMarketplaces -ClaudeHome $fx.Root).Items | Where-Object Name -eq 'mk-a'
        [System.IO.File]::WriteAllText((Join-Path $mk.InstallLocation 'CHANGELOG.md'), "## [1.1.0] - d`n- from the repo root`n")
        $log = [System.Collections.Generic.List[string]]::new()
        $beh = @{ 'plugin update alpha@mk-a' = (Get-Bump $fx 'alpha@mk-a' '1.1.0' 'bbbbbbb9999999') }
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner $log $beh) -GetProcess $script:Gone
        (Get-PluginRow $r 'alpha').Excerpt | Should -Match 'from the repo root'
    }
    It 'is bounded in lines and characters, and strips control characters' {
        $long = (1..40 | ForEach-Object { "- item $_ " + ('x' * 300) }) -join "`n"
        $section = "## [2.0.0]`n$long`n"
        $dir = Join-Path $TestDrive 'ex1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'CHANGELOG.md'), ("## [2.0.0]`n- evil " + [char]27 + '[31mred' + [char]7 + "`n" + $long))
        $ex = Get-WhatsNewExcerpt -SearchDirs @($dir) -Version '2.0.0'
        @($ex -split "`n").Count | Should -BeLessOrEqual 6
        $ex.Length | Should -BeLessOrEqual 480
        $ex | Should -Not -Match "[\x00-\x08\x0b\x1b\x07]"
        $ex | Should -Match 'evil'
    }
    It 'the line limit binds on its own: many short lines are cut to 6' {
        $dir = Join-Path $TestDrive 'ex2'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'CHANGELOG.md'), ("## [2.0.0]`n" + ((1..40 | ForEach-Object { "- n$_" }) -join "`n")))
        @((Get-WhatsNewExcerpt -SearchDirs @($dir) -Version '2.0.0') -split "`n").Count | Should -Be 6
    }
    It 'Get-ChangelogVersionSection: 0.39.1 does not match the 0.39.10 heading, and accepts several heading styles' {
        (Get-ChangelogVersionSection -Text "## [0.39.10] - d`n- ten`n" -Version '0.39.1') | Should -Be ''
        (Get-ChangelogVersionSection -Text "## 0.39.1`n- plain`n" -Version '0.39.1') | Should -Match 'plain'
        (Get-ChangelogVersionSection -Text "# v0.39.1`n- vstyle`n## other`n- no" -Version '0.39.1') | Should -Match 'vstyle'
        (Get-ChangelogVersionSection -Text "## [Unreleased]`n- x`n" -Version '0.39.1') | Should -Be ''
    }
}

Describe 'cleanup after an update: counted always, deleted only with -Clean' {
    BeforeEach {
        $script:fx = New-UpdateFx
        [void](Add-FakeBuild $fx -Marketplace 'mk-a' -Plugin 'alpha' -Version '0.9.0')      # an old build nobody holds
    }
    It 'without -Clean it only counts the removable builds' {
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Runner (New-FakeRunner ([System.Collections.Generic.List[string]]::new())) -GetProcess $script:Gone
        $r.Cleanup.Candidates | Should -Be 1
        $r.Cleanup.Ran | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'mk-a' 'alpha' '0.9.0') | Should -BeTrue
        (Get-ReportText $r) | Should -Match 'No se borra nada solo'
    }
    It '-Clean deletes exactly the removable builds' {
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Clean -Runner (New-FakeRunner ([System.Collections.Generic.List[string]]::new())) -GetProcess $script:Gone
        $r.Cleanup.Removed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'mk-a' 'alpha' '0.9.0') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'mk-a' 'alpha' '1.0.0') | Should -BeTrue
    }
    It '-Clean together with -DryRun still deletes nothing' {
        $r = Invoke-PluginUpdate -ClaudeHome $fx.Root -Clean -DryRun -Runner { throw 'no' } -GetProcess $script:Gone
        $r.Cleanup.Ran | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Root 'plugins' 'cache' 'mk-a' 'alpha' '0.9.0') | Should -BeTrue
    }
}

Describe 'Invoke-ClaudeCli - the real runner, pointed at a harmless program' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'returns the exit code and the output' {
        $r = Invoke-ClaudeCli -Executable $script:Pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output hello; exit 3')
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'hello'
        $r.TimedOut | Should -BeFalse
    }
    It 'closes stdin, so a command that wants to ask a question ends instead of hanging' {
        $r = Invoke-ClaudeCli -Executable $script:Pwsh -Arguments @('-NoProfile', '-Command', '$x = [Console]::In.ReadToEnd(); Write-Output ("read=" + $x.Length)') -TimeoutSec 60
        $r.TimedOut | Should -BeFalse
        $r.Output | Should -Match 'read=0'
    }
    It 'kills a command that exceeds the timeout and says so' {
        $r = Invoke-ClaudeCli -Executable $script:Pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSec 2
        $r.TimedOut | Should -BeTrue
    }
    It 'does not hang past the timeout when a grandchild keeps the output pipes open' {
        $cmd = '$psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, ''-NoProfile -Command Start-Sleep -Seconds 30''); $psi.UseShellExecute = $false; [void][System.Diagnostics.Process]::Start($psi); exit 0'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ClaudeCli -Executable $script:Pwsh -Arguments @('-NoProfile', '-Command', $cmd) -TimeoutSec 60
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 25
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
    }
    It 'refuses to hand a .cmd shim an argument with cmd.exe metacharacters, and runs it with plain ones' {
        if (-not $IsWindows) { Set-ItResult -Skipped -Because '.cmd shims are a Windows matter'; return }
        $shim = Join-Path $TestDrive 'shim.cmd'
        [System.IO.File]::WriteAllText($shim, "@echo off`r`necho ran> `"%~dp0ran.txt`"`r`n")
        $bad = Invoke-ClaudeCli -Executable $shim -Arguments @('plugin', 'update', 'x&echo pwned>%~dp0pwned.txt')
        $bad.ExitCode | Should -Not -Be 0
        $bad.Output | Should -Match 'caracteres no permitidos'
        Test-Path -LiteralPath (Join-Path $TestDrive 'ran.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'pwned.txt') | Should -BeFalse
        $ok = Invoke-ClaudeCli -Executable $shim -Arguments @('plugin', 'update', 'alpha@mk-a', '--yes', 'scope/plugin')
        $ok.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'ran.txt') | Should -BeTrue
    }
    It 'a program that cannot start is a failed run with a reason, not an exception' {
        $r = Invoke-ClaudeCli -Executable (Join-Path $TestDrive 'no-such-program.exe') -Arguments @('x')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'no pude ejecutar'
    }
}
