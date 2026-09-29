#Requires -Modules Pester
<#  Pester tests for Scan-Project.ps1 - `/scan` in one command (#738, #731).

    The plan half is pure and tested here in full: what counts as a finding, which preset label it
    gets, the Priority and the reason for it, dependencies, the order, the PR batches, and what apply
    would do. The scan itself runs against a throw-away git repo. The apply half only executes the
    steps Get-ScanApplySteps lists, and its -DryRun is exercised end to end with no token. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Scan-Project.ps1' | Resolve-Path
    $env:ABIOS_SCAN_DOTSOURCE = '1'
    try { . $script:Script } finally { $env:ABIOS_SCAN_DOTSOURCE = '' }
    function script:Item([string]$Title = 'Do a thing', [string]$Type = 'feature', [string]$Prio = 'P2', [string]$Path = 'src/a/x.ps1', [int[]]$Deps = @(), [string]$Kind = 'checklist') {
        $i = New-ScanItem -Kind $Kind -Path $Path -Line 1 -Text $Title
        $i.Type = $Type; $i.Priority = $Prio; $i.DependsOn = $Deps
        $i
    }
}

Describe 'ConvertFrom-MarkerGrep - only real debt markers are findings' {
    It 'reads TODO:, TODO(scope): and TODO ID-1: forms' {
        $r = @(ConvertFrom-MarkerGrep @(
            'src/a.ps1:3:# TODO: add retry to the upload',
            'src/b.ts:9:// TODO(F5): cache the token',
            'src/c.py:1:# TODO SM-107: support paging'))
        $r.Count | Should -Be 3
        $r[0].Title | Should -Be 'Add retry to the upload'
        $r[0].Source | Should -Be 'src/a.ps1:3'
        $r[1].Title | Should -Be 'Cache the token'
        $r[2].Title | Should -Be 'Support paging'
    }
    It 'ignores a marker with no colon, a marker inside an identifier and one with no text' {
        @(ConvertFrom-MarkerGrep @(
            'src/a.ps1:1:$x = "TODO es string"',
            'src/a.ps1:2:$MY_TODO: = 1',
            'src/a.ps1:3:# TODO:   ')).Count | Should -Be 0
    }
    It 'maps FIXME and BUG to bug, HACK and XXX to refactor' {
        $r = @(ConvertFrom-MarkerGrep @('a.ps1:1:# FIXME: off by one', 'a.ps1:2:# BUG: null ref', 'a.ps1:3:# HACK: sleep 2s', 'a.ps1:4:# XXX: temporary'))
        $r.Type | Should -Be @('bug', 'bug', 'refactor', 'refactor')
    }
}

Describe 'ConvertFrom-MarkdownScan - checklists, pending sections and plans' {
    It 'takes unchecked items, skips checked ones and anything inside a code fence' {
        $md = @('# Notes', '- [ ] Add the export button', '- [x] Done already', '```', '- [ ] not real', '```', '* [ ] Document the API')
        $r = @(ConvertFrom-MarkdownScan -Path 'README.md' -Content $md)
        $r.Title | Should -Be @('Add the export button', 'Document the API')
        $r[0].Source | Should -Be 'README.md:2'
        $r[1].Type | Should -Be 'docs'
    }
    It 'takes plain bullets under a pending / next steps heading, and stops at the next heading' {
        $md = @('## Next steps', '- Wire the refresh', '- [x] finished', '## Done', '- Not pending')
        $r = @(ConvertFrom-MarkdownScan -Path 'docs/x.md' -Content $md)
        $r.Title | Should -Be @('Wire the refresh')
        $r[0].Kind | Should -Be 'pending'
    }
    It 'a plan document is ONE plan item - its own checklist tracks its steps' {
        $md = @('# Billing migration', '- [ ] Move invoices', '- [ ] Step 2: run the test to verify it fails')
        $r = @(ConvertFrom-MarkdownScan -Path 'docs/plans/billing.md' -Content $md -IsPlan)
        $r.Count | Should -Be 1
        $r[0].Kind | Should -Be 'plan'
        $r[0].Title | Should -Be 'Plan: Billing migration'
        $r[0].Evidence | Should -Match '2 open item'
    }
    It 'any file with -PlanThreshold open items is one plan item too' {
        $md = @('# Launch') + (1..12 | ForEach-Object { "- [ ] task $_" })
        $r = @(ConvertFrom-MarkdownScan -Path 'apps/x/PLAN.md' -Content $md)
        $r.Count | Should -Be 1
        $r[0].Evidence | Should -Match '^Checklist document .*12 open item'
        @(ConvertFrom-MarkdownScan -Path 'apps/x/PLAN.md' -Content ($md | Select-Object -First 12)).Count | Should -Be 11
    }
    It 'test wording ("verify it fails", "error") is not a bug' {
        Get-ScanType 'checklist' '' 'Run the test to verify it fails' 'x' | Should -Not -Be 'bug'
        Get-ScanType 'checklist' '' 'Error boundary per section' 'x' | Should -Not -Be 'bug'
    }
}

Describe 'Get-ScanType - preset labels, never ad-hoc type:* ones (#731)' {
    It 'every type is a label of presets/labels.json' {
        $preset = (Get-Content (Join-Path $PSScriptRoot '..' 'presets' 'labels.json') -Raw | ConvertFrom-Json).labels.name
        foreach ($t in @(
            (Get-ScanType 'checklist' '' 'Investigate the slow query' 'x'),
            (Get-ScanType 'checklist' '' 'Fix the broken link' 'x'),
            (Get-ScanType 'checklist' '' 'Update the README' 'x'),
            (Get-ScanType 'checklist' '' 'Refactor the loader' 'x'),
            (Get-ScanType 'checklist' '' 'Add a filter' 'x'),
            (Get-ScanType 'checklist' '' 'Bump the version' 'x'))) {
            $preset | Should -Contain $t
        }
    }
    It 'research wording is a spike' { Get-ScanType 'marker' 'TODO' 'investigate why it retries' 'x' | Should -Be 'spike' }
    It 'a plan document is a feature epic' { Get-ScanType 'plan' '' 'Plan: billing' 'x' | Should -Be 'feature' }
}

Describe 'Get-ScanPriority - a proposal with its reason' {
    It 'P0 for a risk to data, security or uptime, naming the word that triggered it' {
        $p = Get-ScanPriority 'chore' 'checklist' '' 'Rotate the leaked credential'
        $p.Priority | Should -Be 'P0'
        $p.Reason | Should -Match 'leaked'
    }
    It 'P1 for bugs and plans, P2 for features and spikes, P3 for docs and refactors' {
        (Get-ScanPriority 'bug' 'marker' 'FIXME' 'off by one').Priority | Should -Be 'P1'
        (Get-ScanPriority 'feature' 'plan' '' 'Plan: x').Priority | Should -Be 'P1'
        (Get-ScanPriority 'feature' 'checklist' '' 'add x').Priority | Should -Be 'P2'
        (Get-ScanPriority 'spike' 'checklist' '' 'investigate x').Priority | Should -Be 'P2'
        (Get-ScanPriority 'docs' 'checklist' '' 'document x').Priority | Should -Be 'P3'
        (Get-ScanPriority 'refactor' 'marker' 'HACK' 'x').Priority | Should -Be 'P3'
    }
    It 'P1 for anything with a date, in English or Spanish' {
        (Get-ScanPriority 'chore' 'checklist' '' 'VENCIDO: migrar el chat').Priority | Should -Be 'P1'
        (Get-ScanPriority 'chore' 'checklist' '' 'Renew the cert before the deadline').Reason | Should -Match 'deadline'
    }
    It 'reads Spanish wording too' {
        Get-ScanType 'checklist' '' 'Revisar si hay un template nuevo' 'x' | Should -Be 'spike'
        Get-ScanType 'checklist' '' 'Documentar el API' 'x' | Should -Be 'docs'
        Get-ScanType 'checklist' '' 'Agregar un filtro' 'x' | Should -Be 'feature'
    }
    It 'every proposal has a reason' {
        foreach ($t in 'bug', 'feature', 'chore', 'docs', 'refactor', 'spike') {
            (Get-ScanPriority $t 'checklist' '' 'x').Reason | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-ScanDependencies - what an item says it waits on' {
    It 'reads blocked by / depends on / after / requires / waits on #n' {
        Get-ScanDependencies 'Ship it, blocked by #12 and depends on #7' | Should -Be @(12, 7)
        Get-ScanDependencies 'after #3' | Should -Be @(3)
        Get-ScanDependencies 'waits on #4' | Should -Be @(4)
    }
    It 'a bare issue mention is not a dependency' {
        @(Get-ScanDependencies 'see #12 for context').Count | Should -Be 0
    }
}

Describe 'Set-ScanTracked and Select-UniqueScanItem - never propose what is already tracked' {
    It 'marks an item whose title an open issue already has' {
        $items = @(script:Item 'Add the export button')
        Set-ScanTracked -Items $items -OpenIssues @([pscustomobject]@{ number = 5; title = 'add the export button!'; body = '' }) | Out-Null
        $items[0].Tracked | Should -Match '#5'
    }
    It 'marks a plan document an open issue cites by path' {
        $p = New-ScanItem -Kind 'plan' -Path 'docs/plans/x.md' -Line 0 -Text 'Plan: X'
        Set-ScanTracked -Items @($p) -OpenIssues @([pscustomobject]@{ number = 9; title = 'epic'; body = 'see docs/plans/x.md' }) | Out-Null
        $p.Tracked | Should -Match '#9 cites'
    }
    It 'leaves alone an item an earlier apply already created' {
        $i = script:Item 'Add the export button'; $i.Issue = 40
        Set-ScanTracked -Items @($i) -OpenIssues @([pscustomobject]@{ number = 40; title = 'Add the export button'; body = '' }) | Out-Null
        $i.Tracked | Should -BeNullOrEmpty
    }
    It 'one title is one item, listing the other files it was found in' {
        $r = @(Select-UniqueScanItem @((script:Item 'A' -Path 'x.md'), (script:Item 'a' -Path 'x.md'), (script:Item 'A' -Path 'y.md'), (script:Item 'B' -Path 'y.md')))
        $r.Count | Should -Be 2
        $r[0].AlsoIn | Should -Be @('y.md:1')
        New-ScanIssueBody $r[0] | Should -Match 'Also in:\*\* `y.md:1`'
    }
}

Describe 'Set-ScanOrder - unblocked first, then priority, plans before their children' {
    It 'orders and numbers rows' {
        $blocked = script:Item 'Blocked one' -Prio 'P0' -Deps @(3)
        $p2 = script:Item 'Later' -Prio 'P2'
        $p1 = script:Item 'Sooner' -Prio 'P1'
        $plan = script:Item 'Plan: X' -Prio 'P1' -Kind 'plan'
        $r = @(Set-ScanOrder @($blocked, $p2, $p1, $plan))
        $r.Title | Should -Be @('Plan: X', 'Sooner', 'Later', 'Blocked one')
        $r.Row | Should -Be @(1, 2, 3, 4)
    }
}

Describe 'Get-ScanBatches - PR groups' {
    BeforeAll {
        $script:Items = @(
            (script:Item 'a1' -Path 'src/a/1.ps1' -Prio 'P2'),
            (script:Item 'a2' -Path 'src/a/2.ps1' -Prio 'P1'),
            (script:Item 'a3' -Path 'src/a/3.ps1'),
            (script:Item 'b1' -Path 'src/b/1.ps1' -Prio 'P3'),
            (script:Item 'w1' -Path 'src/a/9.ps1' -Deps @(12)),
            (script:Item 'Plan: X' -Path 'docs/plans/x.md' -Kind 'plan'))
        $script:Items = @(Set-ScanOrder $script:Items)
    }
    It 'groups one area into one PR, capped at -Max, and orders by the most urgent item' {
        $b = @(Get-ScanBatches -Items $script:Items -Max 2)
        $b[0].Area | Should -Be 'src/a'
        $b[0].Rows.Count | Should -Be 2
        ($b | Where-Object Area -eq 'src/a' | Where-Object { -not $_.Waits.Count }).Count | Should -Be 2
    }
    It 'an item that waits on an issue gets its own batch, last, naming the blocker' {
        $b = @(Get-ScanBatches -Items $script:Items -Max 4)
        $b[-1].Waits | Should -Be @(12)
        $b[-1].Title | Should -Match 'waits on #12'
    }
    It 'a plan document is an epic, never a PR' {
        $plan = $script:Items | Where-Object Kind -eq 'plan'
        @(Get-ScanBatches -Items $script:Items) | ForEach-Object { $_.Rows | Should -Not -Contain $plan.Row }
    }
}

Describe 'Issue and epic bodies' {
    It 'the issue body carries the source, the evidence, the priority reason and the blocker' {
        $i = script:Item 'Ship it' -Deps @(12)
        $b = New-ScanIssueBody $i
        $b | Should -Match 'src/a/x.ps1:1'
        $b | Should -Match 'Proposed priority:\*\* P2 - '
        $b | Should -Match 'Blocked by:\*\* #12'
    }
    It 'the epic lists items in order with their issue numbers, then the PRs' {
        $items = @(Set-ScanOrder @((script:Item 'one' -Prio 'P1'), (script:Item 'two')))
        $items[0].Issue = 101; $items[1].Issue = 102
        $b = New-ScanEpicBody -Items $items -Batches @(Get-ScanBatches $items)
        $b | Should -Match '(?s)- \[ \] #101 One.*- \[ \] #102 Two'
        $b | Should -Match '## Proposed PRs'
        $b | Should -Match '#101, #102'
    }
}

Describe 'Get-ScanApplySteps - what one confirmation does' {
    BeforeAll {
        $script:A = @(Set-ScanOrder @((script:Item 'one'), (script:Item 'two' -Deps @(4)), (script:Item 'three'), (script:Item 'Investigate it' -Type 'spike')))
        ($script:A | Where-Object Title -eq 'Three').Tracked = '#9 has the same title'
    }
    It 'lists board, labels, one line per new issue, the epic and the fill' {
        $s = (Get-ScanApplySteps -Items $script:A).Steps
        $s[0] | Should -Match '^board: .*with the standard fields'
        $s[1] | Should -Match '^labels: '
        @($s | Where-Object { $_ -like 'issue:*' }).Count | Should -Be 3
        $s | Should -Contain 'fill: Board-Fill -Auto fills what is still empty (Status, Size, Type, assignee)'
        ($s | Where-Object { $_ -like 'epic:*' }) | Should -Match '3 item'
    }
    It 'a blocked item gets the blocked label and Status Blocked' {
        ((Get-ScanApplySteps -Items $script:A).Steps | Where-Object { $_ -like "*'Two'*" }) | Should -Match 'blocked\].*Status Blocked'
    }
    It 'never creates a tracked item or one created before, and honours -Rows' {
        $one = $script:A | Where-Object Title -eq 'One'; $one.Issue = 50
        try {
            $r = Get-ScanApplySteps -Items $script:A
            $r.New.Title | Should -Not -Contain 'One'
            $r.New.Title | Should -Not -Contain 'Three'
            (Get-ScanApplySteps -Items $script:A -Rows @(3)).New.Row | Should -Be @(3)
        } finally { $one.Issue = 0 }
    }
    It '-BareBoard and -NoFill show in the steps' {
        $s = (Get-ScanApplySteps -Items $script:A -BareBoard -NoFill).Steps
        $s[0] | Should -Match 'WITHOUT'
        $s | Where-Object { $_ -like 'fill:*' } | Should -BeNullOrEmpty
    }
}

Describe 'Scan-Project.ps1 end to end in a throw-away repo (no token)' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'docs' 'plans') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'node_modules' 'x') -Force | Out-Null
        Set-Content (Join-Path $script:Repo 'src' 'a.ps1') "# FIXME: crash on empty input`n# TODO: add paging, blocked by #3"
        Set-Content (Join-Path $script:Repo 'node_modules' 'x' 'b.js') '// TODO: vendored noise'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'plugins' 'p' 'skills' 's') -Force | Out-Null
        Set-Content (Join-Path $script:Repo 'plugins' 'p' 'skills' 's' 'SKILL.md') '- [ ] skill content'
        Set-Content (Join-Path $script:Repo 'README.md') "# Proj`n- [ ] Document the setup"
        Set-Content (Join-Path $script:Repo 'docs' 'plans' 'p.md') "# Billing`n- [ ] Move invoices"
        git -C $script:Repo init -q 2>&1 | Out-Null
        git -C $script:Repo add -A 2>&1 | Out-Null
        $script:PlanPath = Join-Path $TestDrive 'scan-plan.json'
        $saved = $env:GH_TOKEN; $env:GH_TOKEN = ''
        try {
            $script:Out = & $script:Script -Root $script:Repo -Repo 'me/proj' -PlanFile $script:PlanPath -Json -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
        } finally { $env:GH_TOKEN = $saved }
        $script:Plan = Get-Content $script:PlanPath -Raw | ConvertFrom-Json
    }
    It 'finds the markers, the checklist and the plan, and skips node_modules' {
        $t = @($script:Plan.items.Title)
        $t | Should -Contain 'Crash on empty input'
        $t | Should -Contain 'Add paging, blocked by #3'
        $t | Should -Contain 'Document the setup'
        $t | Should -Contain 'Plan: Billing'
        $t | Should -Not -Contain 'Move invoices'
        $t | Should -Not -Contain 'Vendored noise'
        $t | Should -Not -Contain 'Skill content'
    }
    It 'proposes P0 for the crash, carries the dependency, and records that duplicates were not checked' {
        ($script:Plan.items | Where-Object Title -eq 'Crash on empty input').Priority | Should -Be 'P0'
        @(($script:Plan.items | Where-Object Title -like 'Add paging*').DependsOn) | Should -Be @(3)
        $script:Plan.dedupeChecked | Should -BeFalse
    }
    It 'apply -DryRun lists the steps and writes nothing' {
        $before = (Get-FileHash $script:PlanPath).Hash
        $out = & $script:Script -Root $script:Repo -Repo 'me/proj' -PlanFile $script:PlanPath -Apply -DryRun 6>&1 | Out-String
        $out | Should -Match 'rehearsal, nothing is written'
        $out | Should -Match 'issue: row 1 '
        (Get-FileHash $script:PlanPath).Hash | Should -Be $before
    }
    It 'apply refuses a plan made for another repo' {
        { & $script:Script -Root $script:Repo -Repo 'me/other' -PlanFile $script:PlanPath -Apply -DryRun 6>&1 | Out-Null } | Should -Throw '*is for me/proj*'
    }
}

Describe 'Invoke-ScanApply - the whole sequence with GitHub mocked' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-Gh.ps1' | Resolve-Path)
        function script:New-ApplyPlan {
            $items = @(Set-ScanOrder @((script:Item 'Add paging' -Prio 'P1'), (script:Item 'Ship it' -Deps @(3)), (script:Item 'Investigate cache' -Type 'spike')))
            [pscustomobject]@{ repo = 'me/proj'; items = $items; batches = @(Get-ScanBatches $items); board = 0; epic = 0 }
        }
    }
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:NextIssue = 100
        Mock Invoke-SuiteScript {
            $script:Calls.Add("suite $Name")
            if ($Name -eq 'Resolve-Board.ps1') { '7' }
        }
        Mock Invoke-Gh {
            $script:Calls.Add(($GhArgs -join ' '))
            switch ("$($GhArgs[0]) $($GhArgs[1])") {
                'issue create' { $script:NextIssue++; return "https://github.com/me/proj/issues/$($script:NextIssue)" }
                'project view' { return [pscustomobject]@{ id = 'PVT_1' } }
                'project field-list' {
                    return [pscustomobject]@{ fields = @(
                        [pscustomobject]@{ id = 'F_PRIO'; name = 'Priority'; options = @([pscustomobject]@{ id = 'O_P1'; name = 'P1' }, [pscustomobject]@{ id = 'O_P2'; name = 'P2' }) },
                        [pscustomobject]@{ id = 'F_STATUS'; name = 'Status'; options = @([pscustomobject]@{ id = 'O_BLOCKED'; name = 'Blocked' }) },
                        [pscustomobject]@{ id = 'F_TYPE'; name = 'Task Type'; options = @([pscustomobject]@{ id = 'O_SPIKE'; name = 'Spike' }) }) }
                }
                'project item-add' { return [pscustomobject]@{ id = "ITEM_$($script:NextIssue)" } }
                default { if ($GhArgs[0] -eq 'api' -and $GhArgs[1] -like 'repos/*/issues/*') { return '555' } }
            }
        }
    }
    It 'board, labels, one issue per row with its fields, the epic with sub-issues, then fill' {
        $plan = script:New-ApplyPlan
        $saves = [System.Collections.Generic.List[int]]::new()
        $r = Invoke-ScanApply -Plan $plan -Steps (Get-ScanApplySteps -Items $plan.items) -Repo 'me/proj' -Owner 'me' -Save { param($p) $saves.Add(1) } 6>$null
        $r.board | Should -Be 7
        @($r.created) | Should -Be @(101, 102, 103)
        $r.epic | Should -Be 104
        @($r.failed).Count | Should -Be 0
        $script:Calls[0] | Should -Be 'suite Resolve-Board.ps1'
        $script:Calls[1] | Should -Be 'suite Apply-LabelPreset.ps1'
        $script:Calls[-1] | Should -Be 'suite Board-Fill.ps1'
        @($script:Calls | Where-Object { $_ -like 'issue create*' -and $_ -match '--label scan,feature$' }).Count | Should -Be 1
        @($script:Calls | Where-Object { $_ -like 'issue create*--label scan,feature,blocked*' }).Count | Should -Be 1
        @($script:Calls | Where-Object { $_ -like '*--single-select-option-id O_BLOCKED*' }).Count | Should -Be 1
        @($script:Calls | Where-Object { $_ -like '*--single-select-option-id O_SPIKE*' }).Count | Should -Be 1
        @($script:Calls | Where-Object { $_ -like 'api -X POST repos/me/proj/issues/104/sub_issues*' }).Count | Should -Be 3
        $saves.Count | Should -BeGreaterOrEqual 3
    }
    It 'a second run creates nothing twice: it only updates the epic' {
        $plan = script:New-ApplyPlan
        Invoke-ScanApply -Plan $plan -Steps (Get-ScanApplySteps -Items $plan.items) -Repo 'me/proj' -Owner 'me' -NoFill 6>$null | Out-Null
        $script:Calls.Clear()
        $r = Invoke-ScanApply -Plan $plan -Steps (Get-ScanApplySteps -Items $plan.items) -Repo 'me/proj' -Owner 'me' -NoFill 6>$null
        @($r.created).Count | Should -Be 0
        @($script:Calls | Where-Object { $_ -like 'issue create*' }).Count | Should -Be 0
        @($script:Calls | Where-Object { $_ -like 'issue edit 104*' }).Count | Should -Be 1
        $script:Calls | Should -Not -Contain 'suite Board-Fill.ps1'
    }
    It 'one failing issue is reported and the rest still go through' {
        Mock Invoke-Gh { throw 'HTTP 422' } -ParameterFilter { $GhArgs[0] -eq 'issue' -and $GhArgs[1] -eq 'create' -and ($GhArgs -join ' ') -like '*Ship it*' }
        $plan = script:New-ApplyPlan
        $r = Invoke-ScanApply -Plan $plan -Steps (Get-ScanApplySteps -Items $plan.items) -Repo 'me/proj' -Owner 'me' -NoFill 6>$null
        @($r.created).Count | Should -Be 2
        @($r.failed) | Should -Match 'HTTP 422'
    }
    It '-BareBoard reaches Resolve-Board as -SkipPreset' {
        $plan = script:New-ApplyPlan
        Invoke-ScanApply -Plan $plan -Steps (Get-ScanApplySteps -Items $plan.items) -Repo 'me/proj' -Owner 'me' -BareBoard -NoFill 6>$null | Out-Null
        Should -Invoke Invoke-SuiteScript -ParameterFilter { $Name -eq 'Resolve-Board.ps1' -and $Arguments.SkipPreset } -Times 1 -Exactly
    }
}

Describe 'Board-Fill maps the spike label to Task Type Spike (#731)' {
    It 'has the mapping' {
        Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Fill.ps1') -Raw | Should -Match '\$labels -contains "spike"\)\s*\{ \$detectedType = "Spike" \}'
    }
}
