#Requires -Modules Pester
<#  The release cut must not assert what nobody checked (#676).

    Two defects, both found while cutting v0.38.2:
      1. `-Bump` did what it was told. 0.39.0 was proposed for a batch containing only `### Fixed`
         entries ("big batch, bigger number") and nothing objected.
      2. The CHANGELOG fold delegated to "closed since the last version", which is not the same
         question as "this release fixed it": #661, closed as a duplicate of a month-old fix, was
         inserted under `### Added` as if it were a new feature - two errors in one line.

    The rule is not to take over the curation (this repo hand-curates [Unreleased]) but to stop the
    tooling agreeing with a wrong claim.  #>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path

    $env:ABIOS_RELEASE_DOTSOURCE = '1'
    . (Join-Path $script:ScriptsDir 'New-Release.ps1')
    $env:ABIOS_RELEASE_DOTSOURCE = ''

    $env:ABIOS_CHANGELOG_DOTSOURCE = '1'
    . (Join-Path $script:ScriptsDir 'Board-Changelog.ps1')
    $env:ABIOS_CHANGELOG_DOTSOURCE = ''
}

# ══ 1. the bump against [Unreleased] ═══════════════════════════════════════════════════════════

Describe 'Get-MinimumBump - the minimum comes from what is under [Unreleased]' {
    It 'only Fixed -> patch (the v0.38.2 batch that nearly shipped as 0.39.0)' {
        $b = "### Fixed`n- **A bug** (#1).`n- **Another** (#2).`n"
        (Get-MinimumBump -Block $b -Current '0.38.1').minimum | Should -Be 'patch'
    }
    It 'Security alone is a fix -> patch' {
        (Get-MinimumBump -Block "### Security`n- **x** (#1).`n" -Current '0.38.1').minimum | Should -Be 'patch'
    }
    It 'any Added -> minor, even beside many fixes' {
        $b = "### Fixed`n- a`n- b`n- c`n### Added`n- **A feature** (#9).`n"
        $r = Get-MinimumBump -Block $b -Current '0.38.1'
        $r.minimum | Should -Be 'minor'
        ($r.reasons -join ' ') | Should -Match '### Added'
    }
    It 'Changed, Deprecated and Removed -> minor' {
        foreach ($h in 'Changed', 'Deprecated', 'Removed') {
            (Get-MinimumBump -Block "### $h`n- x`n" -Current '0.38.1').minimum | Should -Be 'minor' -Because $h
        }
    }
    It 'a header the check does not know cannot be proven a fix -> minor' {
        (Get-MinimumBump -Block "### Performance`n- x`n" -Current '0.38.1').minimum | Should -Be 'minor'
    }
    It 'an EMPTY header (a leftover template) does not raise the bar' {
        $b = "### Added`n`n### Fixed`n- **a bug** (#1).`n"
        (Get-MinimumBump -Block $b -Current '0.38.1').minimum | Should -Be 'patch'
    }
    It 'a BREAKING marker -> major from 1.x' {
        $b = "### Changed`n- **BREAKING: the flag is gone** (#1).`n"
        (Get-MinimumBump -Block $b -Current '1.4.0').minimum | Should -Be 'major'
    }
    It 'a BREAKING marker in 0.x -> minor (a breaking change is a minor bump by convention there)' {
        $r = Get-MinimumBump -Block "### Changed`n- **BREAKING: x** (#1).`n" -Current '0.38.1'
        $r.minimum | Should -Be 'minor'
        $r.breaking | Should -BeTrue
    }
    It 'the word "breaking" in lower case is prose, not a marker' {
        (Get-MinimumBump -Block "### Fixed`n- stops breaking the hook (#1).`n" -Current '1.4.0').minimum | Should -Be 'patch'
    }
    It 'nothing under [Unreleased] -> no minimum' {
        (Get-MinimumBump -Block '' -Current '0.38.1').minimum | Should -BeNullOrEmpty
        (Get-MinimumBump -Block "### Added`n### Fixed`n" -Current '0.38.1').minimum | Should -BeNullOrEmpty
        (Get-MinimumBump -Block $null -Current '0.38.1').minimum | Should -BeNullOrEmpty
    }
}

Describe 'Get-UnreleasedBlock' {
    It 'returns the body of [Unreleased] up to the next version header' {
        $t = "# Changelog`n`n## [Unreleased]`n### Fixed`n- x`n`n## [0.1.0] - 2026-01-01`n### Added`n- old`n"
        $b = Get-UnreleasedBlock -Text $t
        $b | Should -Match 'Fixed'
        $b | Should -Not -Match 'old'
    }
    It 'is $null when there is no [Unreleased]' {
        Get-UnreleasedBlock -Text "# Changelog`n## [0.1.0] - 2026-01-01`n" | Should -BeNullOrEmpty
    }
}

Describe 'Get-BumpKind' {
    It 'classifies patch, minor and major' {
        Get-BumpKind -Current '0.38.4' -Next '0.38.5' | Should -Be 'patch'
        Get-BumpKind -Current '0.38.4' -Next '0.39.0' | Should -Be 'minor'
        Get-BumpKind -Current '0.38.4' -Next '1.0.0'  | Should -Be 'major'
    }
    It 'refuses a version that is not newer' {
        { Get-BumpKind -Current '0.38.4' -Next '0.38.4' } | Should -Throw -ExpectedMessage '*not newer*'
        { Get-BumpKind -Current '0.38.4' -Next '0.37.0' } | Should -Throw -ExpectedMessage '*not newer*'
    }
}

Describe 'Test-BumpChoice - smaller is refused, larger only warns' {
    BeforeAll {
        $script:FixOnly = Get-MinimumBump -Block "### Fixed`n- a`n" -Current '0.38.1'
        $script:HasAdded = Get-MinimumBump -Block "### Added`n- a`n" -Current '0.38.1'
    }
    It 'a fix-only batch bumped to minor is allowed but WARNS - the rejected 0.39.0 case' {
        $r = Test-BumpChoice -Chosen 'minor' -Minimum $script:FixOnly
        $r.ok | Should -BeTrue
        $r.warn | Should -BeTrue
        $r.message | Should -Match 'larger'
    }
    It 'a fix-only batch bumped to patch is clean' {
        $r = Test-BumpChoice -Chosen 'patch' -Minimum $script:FixOnly
        $r.ok | Should -BeTrue
        $r.warn | Should -BeFalse
    }
    It 'a batch with an Added entry bumped to patch is REFUSED' {
        $r = Test-BumpChoice -Chosen 'patch' -Minimum $script:HasAdded
        $r.ok | Should -BeFalse
        $r.message | Should -Match "smaller than what \[Unreleased\] contains"
        $r.message | Should -Match "minimum is 'minor'"
    }
    It 'nothing to compare against is not a failure' {
        (Test-BumpChoice -Chosen 'patch' -Minimum (Get-MinimumBump -Block '' -Current '0.1.0')).ok | Should -BeTrue
    }
}

Describe 'New-Release.ps1 end to end - the bump rule on a real run' {
    BeforeAll {
        # A throwaway repo shaped like the real one: the script finds plugin.json beside itself and
        # the marketplace + CHANGELOG under the repo root, so a copy behaves exactly like the original.
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('rel-' + [guid]::NewGuid().ToString('N'))
        $pluginDir = Join-Path $script:Root 'plugins' 'agentic-board'
        New-Item -ItemType Directory -Path (Join-Path $pluginDir 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $pluginDir '.claude-plugin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root '.claude-plugin') -Force | Out-Null
        Copy-Item (Join-Path $script:ScriptsDir 'New-Release.ps1') (Join-Path $pluginDir 'scripts')
        Copy-Item (Join-Path $script:ScriptsDir 'Board-Changelog.ps1') (Join-Path $pluginDir 'scripts')
        $realPlugin = Join-Path $script:ScriptsDir '..' '.claude-plugin' 'plugin.json' | Resolve-Path
        $realMarket = Join-Path $script:ScriptsDir '..' '..' '..' '.claude-plugin' 'marketplace.json' | Resolve-Path
        Copy-Item $realPlugin (Join-Path $pluginDir '.claude-plugin')
        Copy-Item $realMarket (Join-Path $script:Root '.claude-plugin')
        $script:PluginJson = Join-Path $pluginDir '.claude-plugin' 'plugin.json'
        $script:Rel = Join-Path $pluginDir 'scripts' 'New-Release.ps1'
        $script:Cl = Join-Path $script:Root 'CHANGELOG.md'
        $script:Ver = ([regex]::Match([System.IO.File]::ReadAllText($script:PluginJson), '"version"\s*:\s*"([^"]+)"')).Groups[1].Value

        function script:Set-Unreleased([string]$Body) {
            Set-Content -LiteralPath $script:Cl -Value ("# Changelog`n`n## [Unreleased]`n$Body`n## [0.0.1] - 2026-01-01`n### Added`n- first`n") -Encoding UTF8
        }
        function script:Run-Rel([string[]]$Args2) {
            # From INSIDE the throwaway tree: the script asks git for the repo root first, and from the
            # test's own directory that would be the real repository (and its real CHANGELOG).
            Push-Location $script:Root
            try {
                $out = & pwsh -NoProfile -File $script:Rel @Args2 2>&1 | Out-String
                [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $out }
            } finally { Pop-Location }
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'fix-only [Unreleased] + -Bump minor: allowed, WARNS' {
        Set-Unreleased "### Fixed`n- **a bug** (#1).`n"
        $r = Run-Rel @('-Bump', 'minor', '-DryRun')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'WARN.*larger'
    }
    It 'fix-only [Unreleased] + -Bump patch: clean' {
        Set-Unreleased "### Fixed`n- **a bug** (#1).`n"
        $r = Run-Rel @('-Bump', 'patch', '-DryRun')
        $r.Exit | Should -Be 0
        $r.Text | Should -Not -Match 'WARN|REFUSED'
    }
    It 'an Added entry + -Bump patch: REFUSED under -DryRun, exit 1' {
        Set-Unreleased "### Added`n- **a feature** (#1).`n"
        $r = Run-Rel @('-Bump', 'patch', '-DryRun')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "REFUSED.*smaller than what \[Unreleased\] contains"
    }
    It 'a refused real run writes NOTHING - plugin.json keeps its version' {
        Set-Unreleased "### Added`n- **a feature** (#1).`n"
        $before = [System.IO.File]::ReadAllText($script:PluginJson)
        $r = Run-Rel @('-Bump', 'patch', '-NoChangelog')
        $r.Exit | Should -Be 1
        [System.IO.File]::ReadAllText($script:PluginJson) | Should -Be $before
    }
    It 'an explicit -Version is judged too (a patch-sized -Version over an Added entry is refused)' {
        Set-Unreleased "### Added`n- **a feature** (#1).`n"
        $parts = $script:Ver -split '\.'
        $patchVer = "$($parts[0]).$($parts[1]).$([int]$parts[2] + 1)"
        (Run-Rel @('-Version', $patchVer, '-DryRun')).Exit | Should -Be 1
    }
    It '-Check with no planned bump only REPORTS the minimum' {
        Set-Unreleased "### Added`n- **a feature** (#1).`n"
        $r = Run-Rel @('-Check')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match "implies at least a 'minor'"
    }
    It '-Check with a planned bump that is too small FAILS' {
        Set-Unreleased "### Added`n- **a feature** (#1).`n"
        $r = Run-Rel @('-Check', '-Bump', 'patch')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'FAIL.*smaller than what \[Unreleased\] contains'
    }
    It '-Check with a larger planned bump warns and passes' {
        Set-Unreleased "### Fixed`n- **a bug** (#1).`n"
        $r = Run-Rel @('-Check', '-Bump', 'minor')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'WARN'
    }
    It 'with nothing under [Unreleased] there is no minimum to enforce' {
        Set-Content -LiteralPath $script:Cl -Value "# Changelog`n`n## [0.0.1] - 2026-01-01`n### Added`n- first`n" -Encoding UTF8
        $r = Run-Rel @('-Check', '-Bump', 'patch')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'nothing under \[Unreleased\]'
    }
}

# ══ 2. the fold: what belongs in THIS release ══════════════════════════════════════════════════

Describe 'Get-CitedIssueNumbers - ranges are citations too' {
    It 'collects single citations' {
        (Get-CitedIssueNumbers -Text 'Fixed (#12) and (#40).') | Should -Be @(12, 40)
    }
    It 'expands an en-dash range: the middle of #423-#430 counts as cited' {
        $c = Get-CitedIssueNumbers -Text "(#422; #423$([char]0x2013)#430)"
        foreach ($n in 423..430) { $c | Should -Contain $n }
    }
    It 'expands hyphen, em dash and dots' {
        (Get-CitedIssueNumbers -Text '#10-#13') | Should -Contain 12
        (Get-CitedIssueNumbers -Text "#20$([char]0x2014)#22") | Should -Contain 21
        (Get-CitedIssueNumbers -Text '#30..#32') | Should -Contain 31
    }
    It 'needs a # on BOTH ends: "#12 - 30 files" is not a range' {
        $c = Get-CitedIssueNumbers -Text 'see #12 - 30 files changed'
        $c | Should -Be @(12)
    }
    It 'ignores a backwards or absurd range instead of citing half the tracker' {
        (Get-CitedIssueNumbers -Text '#50-#10') | Should -Not -Contain 30
        (Get-CitedIssueNumbers -Text '#5-#900') | Should -Not -Contain 400
    }
    It 'handles text with no citations' {
        @(Get-CitedIssueNumbers -Text 'nothing here').Count | Should -Be 0
        @(Get-CitedIssueNumbers -Text '').Count | Should -Be 0
    }
}

Describe 'Test-IssueInRelease - only an issue closed BY a merged PR of this release' {
    BeforeAll {
        $script:Since = [datetime]::Parse('2026-09-01', [Globalization.CultureInfo]::InvariantCulture)
        function script:Iss($state, $reason, $prs) { [pscustomobject]@{ state = $state; stateReason = $reason
            closedByPullRequestsReferences = [pscustomobject]@{ nodes = @($prs) } } }
        function script:Pr($merged, $at) { [pscustomobject]@{ number = 1; state = $(if ($merged) { 'MERGED' } else { 'CLOSED' }); merged = $merged; mergedAt = $at } }
    }
    It 'closed as NOT PLANNED is never release content - the #661 case (a duplicate)' {
        $v = Test-IssueInRelease -Issue (Iss 'CLOSED' 'NOT_PLANNED' @()) -SinceDt $script:Since
        $v.include | Should -BeFalse
        $v.reason | Should -Be 'not-planned'
    }
    It 'closed as DUPLICATE is never release content, even with a merged PR attached' {
        (Test-IssueInRelease -Issue (Iss 'CLOSED' 'DUPLICATE' @((Pr $true '2026-09-05T10:00:00Z'))) -SinceDt $script:Since).include | Should -BeFalse
    }
    It 'closed by a merged PR after the last release -> included' {
        $v = Test-IssueInRelease -Issue (Iss 'CLOSED' 'COMPLETED' @((Pr $true '2026-09-05T10:00:00Z'))) -SinceDt $script:Since
        $v.include | Should -BeTrue
        $v.reason | Should -Be 'ok'
    }
    It 'closed with NO merged PR (by hand, or a commit) -> not included, reason says why' {
        $v = Test-IssueInRelease -Issue (Iss 'CLOSED' 'COMPLETED' @()) -SinceDt $script:Since
        $v.include | Should -BeFalse
        $v.reason | Should -Be 'no-merged-pr'
    }
    It 'a PR that was closed WITHOUT merging does not count' {
        (Test-IssueInRelease -Issue (Iss 'CLOSED' 'COMPLETED' @((Pr $false $null))) -SinceDt $script:Since).reason | Should -Be 'no-merged-pr'
    }
    It 'the merged PR predates the last release -> it shipped before, not in this one' {
        $v = Test-IssueInRelease -Issue (Iss 'CLOSED' 'COMPLETED' @((Pr $true '2026-07-01T10:00:00Z'))) -SinceDt $script:Since
        $v.include | Should -BeFalse
        $v.reason | Should -Be 'pr-before-release'
    }
    It 'an open issue is not content' {
        (Test-IssueInRelease -Issue (Iss 'OPEN' '' @()) -SinceDt $script:Since).reason | Should -Be 'not-closed'
    }
    It 'an older issue with no stateReason at all is decided by its PR, not waved through' {
        (Test-IssueInRelease -Issue (Iss 'CLOSED' $null @()) -SinceDt $script:Since).include | Should -BeFalse
    }
}

Describe 'Resolve-ChangelogSection - no default heading' {
    It 'maps Type and labels as before' {
        Resolve-ChangelogSection -Type 'Feature' -Labels @() | Should -Be 'Added'
        Resolve-ChangelogSection -Type 'Bug' -Labels @() | Should -Be 'Fixed'
        Resolve-ChangelogSection -Type 'Chore' -Labels @() | Should -Be 'Changed'
        Resolve-ChangelogSection -Type $null -Labels @('bug') | Should -Be 'Fixed'
        Resolve-ChangelogSection -Type $null -Labels @('Docs') | Should -Be 'Changed'
        Resolve-ChangelogSection -Type $null -Labels @('enhancement') | Should -Be 'Added'
    }
    It 'an issue with no Type and no known label has NO heading - it is not filed under Added' {
        Resolve-ChangelogSection -Type $null -Labels @() | Should -BeNullOrEmpty
        Resolve-ChangelogSection -Type $null -Labels @('tool-improvement', 'P2') | Should -BeNullOrEmpty
    }
}

Describe 'Select-ChangelogItems - the fold on a board with the v0.38.2 traps in it' {
    BeforeAll {
        $script:Since = [datetime]::Parse('2026-09-01', [Globalization.CultureInfo]::InvariantCulture)
        function script:Node($n, $title, $reason, $prs, $type = $null, $labels = @(), $closedAt = '2026-09-10T10:00:00Z', $url = $null, $state = 'CLOSED', $typename = 'Issue') {
            [pscustomobject]@{
                fieldValues = [pscustomobject]@{ nodes = @($(if ($type) { [pscustomobject]@{ field = [pscustomobject]@{ name = 'Type' }; name = $type } })) }
                content = [pscustomobject]@{
                    __typename = $typename; number = $n; title = $title; state = $state; stateReason = $reason; closedAt = $closedAt
                    url = $(if ($url) { $url } else { "https://github.com/o/r/issues/$n" })
                    labels = [pscustomobject]@{ nodes = @($labels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                    closedByPullRequestsReferences = [pscustomobject]@{ nodes = @($prs) } }
            }
        }
        $script:MergedPr = @([pscustomobject]@{ number = 900; state = 'MERGED'; merged = $true; mergedAt = '2026-09-10T09:00:00Z' })
        $script:Cited = @{}
        foreach ($n in (Get-CitedIssueNumbers -Text "shipped (#423$([char]0x2013)#430)")) { $script:Cited[$n] = $true }
        $script:Nodes = @(
            (Node 661 'Board-ReviewGate returns exit 0 when the only review is a quota-blocked Copilot review' 'NOT_PLANNED' @() 'Bug')
            (Node 700 'A real bug fixed by this release' 'COMPLETED' $script:MergedPr 'Bug')
            (Node 704 'A real feature of this release' 'COMPLETED' $script:MergedPr 'Feature')
            (Node 701 'Closed by hand with no PR' 'COMPLETED' @() 'Bug')
            (Node 424 'Inside the cited range' 'COMPLETED' $script:MergedPr 'Bug')
            (Node 703 'No type and no label' 'COMPLETED' $script:MergedPr)
            (Node 705 'Long ago' 'COMPLETED' $script:MergedPr 'Bug' @() '2026-06-01T10:00:00Z')
            (Node 706 'Other repository' 'COMPLETED' $script:MergedPr 'Bug' @() '2026-09-10T10:00:00Z' 'https://github.com/x/y/issues/706')
            (Node 707 'Still open' '' @() 'Bug' @() $null 'https://github.com/o/r/issues/707' 'OPEN')
            (Node 708 'A pull request' 'COMPLETED' $script:MergedPr 'Bug' @() '2026-09-10T10:00:00Z' $null 'CLOSED' 'PullRequest')
        )
        $script:Sel = Select-ChangelogItems -Nodes $script:Nodes -Repo 'o/r' -AlreadyCited $script:Cited -SinceDt $script:Since
        function script:Reason($n) { ($script:Sel.Skipped | Where-Object number -eq $n).reason }
        $script:All = @($script:Sel.Sections.Values | ForEach-Object { $_ }) -join "`n"
    }
    It 'THE #661 CASE: an issue closed as not planned never reaches the fold, under any heading' {
        $script:All | Should -Not -Match '#661'
        Reason 661 | Should -Be 'not-planned'
    }
    It 'a bug closed by a merged PR of this release lands under Fixed, a feature under Added' {
        $script:Sel.Sections['Fixed'] | Should -Contain '- **A real bug fixed by this release** (#700)'
        $script:Sel.Sections['Added'] | Should -Contain '- **A real feature of this release** (#704)'
    }
    It 'a bug is NEVER under Added by default' {
        (@($script:Sel.Sections['Added']) -join "`n") | Should -Not -Match '#700'
    }
    It 'closed by hand with no merged PR is left out, with its reason, for a human to place' {
        $script:All | Should -Not -Match '#701'
        Reason 701 | Should -Be 'no-merged-pr'
    }
    It 'an issue in the middle of a cited RANGE is already cited' {
        $script:All | Should -Not -Match '#424'
        Reason 424 | Should -Be 'already-cited'
    }
    It 'an issue with no Type or label is left out as unclassified - not defaulted to Added' {
        $script:All | Should -Not -Match '#703'
        Reason 703 | Should -Be 'unclassified'
    }
    It 'closed long before the last release, other-repo, open issues and pull requests never appear' {
        $script:All | Should -Not -Match '#705|#706|#707|#708'
        Reason 705 | Should -Be 'older'
        Reason 706 | Should -Be 'other-repo'
        Reason 707 | Should -BeNullOrEmpty
        Reason 708 | Should -BeNullOrEmpty
    }
    It 'counts exactly the two entries that belong' {
        $script:Sel.Included | Should -Be 2
    }
}

Describe 'Board-Changelog.ps1 asks GitHub for what the rules need' {
    # The fake gh in the end-to-end test below returns a canned body whatever it is asked, so the
    # QUERY itself is pinned here: without stateReason and the closing PRs the rules have nothing to
    # judge, and without includeClosedPrs GitHub returns only OPEN PRs, i.e. never a merged one.
    BeforeAll { $script:ClSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'Board-Changelog.ps1') -Raw }
    It 'requests stateReason' { $script:ClSrc | Should -Match 'number title state stateReason closedAt' }
    It 'requests the closing PRs INCLUDING merged ones' {
        $script:ClSrc | Should -Match 'closedByPullRequestsReferences\(first:5, includeClosedPrs:true\)'
    }
    It 'builds the cited set through Get-CitedIssueNumbers (ranges), not a bare #n scan' {
        $script:ClSrc | Should -Match 'Get-CitedIssueNumbers -Text \$clText'
    }
    It 'selects through the tested function' {
        $script:ClSrc | Should -Match 'Select-ChangelogItems -Nodes \$nodes'
    }
}

Describe 'Board-Changelog.ps1 end to end - a fake gh serves the board' {
    BeforeAll {
        $script:Tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('cl-e2e-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp2 -Force | Out-Null
        $item = {
            param($n, $title, $reason, $type, $prMerged)
            $prs = if ($prMerged) { @(@{ number = 900; state = 'MERGED'; merged = $true; mergedAt = '2026-09-10T09:00:00Z' }) } else { @() }
            @{ fieldValues = @{ nodes = @($(if ($type) { @{ field = @{ name = 'Type' }; name = $type } })) }
               content = @{ __typename = 'Issue'; number = $n; title = $title; state = 'CLOSED'; stateReason = $reason; closedAt = '2026-09-10T10:00:00Z'
                            url = "https://github.com/o/r/issues/$n"; labels = @{ nodes = @() }
                            closedByPullRequestsReferences = @{ nodes = $prs } } }
        }
        $nodes = @(
            (& $item 661 'Board-ReviewGate returns exit 0 when the only review is a quota-blocked Copilot review' 'NOT_PLANNED' 'Bug' $false),
            (& $item 700 'A real bug fixed by this release' 'COMPLETED' 'Bug' $true),
            (& $item 424 'Inside a cited range' 'COMPLETED' 'Bug' $true),
            (& $item 703 'Unclassified work' 'COMPLETED' $null $true)
        )
        $resp = @{ data = @{ user = @{ projectV2 = @{ id = 'P1'; items = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = $nodes } } } } }
        $resp | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $script:Tmp2 'gh-response.json') -Encoding UTF8
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            Set-Content -LiteralPath (Join-Path $script:Tmp2 'gh.cmd') -Encoding ASCII -Value @('@echo off', 'type "%~dp0gh-response.json"')
        } else {
            $g = Join-Path $script:Tmp2 'gh'
            Set-Content -LiteralPath $g -Value @('#!/bin/sh', 'cat "$(dirname "$0")/gh-response.json"')
            chmod +x $g
        }
        $script:ClPath = Join-Path $script:Tmp2 'CHANGELOG.md'
        Set-Content -LiteralPath $script:ClPath -Encoding UTF8 -Value @('# Changelog', '', '## [Unreleased]', '### Fixed', "- hand written (#422; #423$([char]0x2013)#430).", '', '## [0.1.0] - 2026-09-01', '### Added', '- first (#1).')
        $script:OldPath = $env:PATH
        $script:OldTok = $env:GH_TOKEN
        $env:PATH = $script:Tmp2 + [System.IO.Path]::PathSeparator + $env:PATH
        $env:GH_TOKEN = 'not-a-real-token'   # the stand-in gh never reads it; keeps the script off the registry
        $script:Out = (& pwsh -NoProfile -File (Join-Path $script:ScriptsDir 'Board-Changelog.ps1') -Owner o -ProjectNum 1 -Repo 'o/r' -Version 9.9.9 -Date 2026-09-18 -ChangelogPath $script:ClPath 2>&1 | Out-String)
    }
    AfterAll {
        $env:PATH = $script:OldPath; $env:GH_TOKEN = $script:OldTok
        Remove-Item -LiteralPath $script:Tmp2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'proposes the real fix and nothing else in the block' {
        $script:Out | Should -Match '\(#700\)'
        $script:Out | Should -Not -Match '\(#661\)'
        $script:Out | Should -Not -Match '\(#424\)'
        $script:Out | Should -Not -Match '\(#703\)'
    }
    It 'does not invent an Added section for an issue it could not classify' {
        $script:Out | Should -Not -Match '### Added'
    }
    It 'names the classified-out issue for a human, with the reason' {
        $script:Out | Should -Match '#703.*sin Type ni label'
    }
    It 'reports the duplicate as not planned and the ranged one as already cited in the summary' {
        $script:Out | Should -Match '1 ya-citados'
        $script:Out | Should -Match '1 no-planeados'
    }
}
