#Requires -Modules Pester
<#  Tests for Expert-Config.ps1 — the /board expert `config` verb: build the contract with a
    synthesized role and persist it. Pure composition (New-ExpertConfig) behind
    ABIOS_EXPERTCONFIG_DOTSOURCE; it reuses ExpertContractIo + Expert-RoleSynthesis. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-Config.ps1' | Resolve-Path
    $env:ABIOS_EXPERTCONFIG_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTCONFIG_DOTSOURCE = ''
    $script:Inv = @('reports:deneb-visuals','svg-visuals','skill-creator')
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("expcfg-" + [guid]::NewGuid().ToString('N') + ".json")
}
AfterAll { if (Test-Path $script:Tmp) { Remove-Item $script:Tmp -Force } }

Describe 'New-ExpertConfig' {
    It 'produces a contract with a non-empty role synthesized from the plan' {
        $c = New-ExpertConfig -PlanText 'Build a Power BI Deneb visual' -PlanGoal 'Ship a bar chart' -Inventory $script:Inv
        $c.role | Should -Not -BeNullOrEmpty
        $c.role | Should -Match 'powerbi-report'
        $c.role | Should -Match 'Ship a bar chart'
    }
    It 'keeps the default contract settings (brake + evidence + budget)' {
        $c = New-ExpertConfig -PlanText 'whatever' -PlanGoal 'g' -Inventory $script:Inv
        $c.autonomy.irreversible | Should -Contain 'merge'
        $c.evidence.pr | Should -BeTrue
        $c.budget.maxIterations | Should -BeGreaterThan 0
    }
    It 'round-trips through the contract file' {
        $c = New-ExpertConfig -PlanText 'Add a DAX measure' -PlanGoal 'g' -Inventory $script:Inv
        Write-ExpertContract -Contract $c -Path $script:Tmp | Out-Null
        (Read-ExpertContract -Path $script:Tmp).role | Should -Match 'semantic-model'
    }
}

Describe 'New-ExpertConfig role selection' {
    It 'uses a role that exists only in a supplied catalog' {
        $cat = @{ qualityProfile=@(); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@('iac') }) }
        $c = New-ExpertConfig -PlanText 'Refactor the terraform modules' -PlanGoal 'g' `
                              -Inventory @('team:iac-helpers') -Catalog $cat
        $c.role | Should -Match 'infra'
        $c.role | Should -Match 'team:iac-helpers'
    }
    It 'reports when no role matched, so config can offer to synthesize one' {
        $cat = @{ qualityProfile=@(); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        $c = New-ExpertConfig -PlanText 'Write a haiku' -PlanGoal 'g' -Inventory @() -Catalog $cat
        $c.roleMatched | Should -BeFalse
    }
    It 'reports a match when one was found' {
        $cat = @{ qualityProfile=@(); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        $c = New-ExpertConfig -PlanText 'terraform work' -PlanGoal 'g' -Inventory @() -Catalog $cat
        $c.roleMatched | Should -BeTrue
    }
}

Describe 'Test-CodexRescueAvailable (#646)' {
    It 'is available when the plugin list contains "codex"' {
        Test-CodexRescueAvailable -InstalledPlugins @('board', 'codex', 'other') | Should -BeTrue
    }
    It 'is unavailable when the plugin list does not contain it' {
        Test-CodexRescueAvailable -InstalledPlugins @('board', 'other') | Should -BeFalse
    }
    It 'is unavailable on an empty list' {
        Test-CodexRescueAvailable -InstalledPlugins @() | Should -BeFalse
    }
    It 'matches case-insensitively' {
        Test-CodexRescueAvailable -InstalledPlugins @('CODEX') | Should -BeTrue
    }
}

Describe 'New-ExpertConfig - the codex-rescue opt-in never writes a silent lie (#646)' {
    It 'defaults preferCodexRescue to false when not requested' {
        $c = New-ExpertConfig -PlanText 'x' -PlanGoal 'g' -Inventory $script:Inv -InstalledPlugins @('codex')
        $c.review.preferCodexRescue | Should -BeFalse
    }
    It 'honours the opt-in when requested AND the plugin is available' {
        $c = New-ExpertConfig -PlanText 'x' -PlanGoal 'g' -Inventory $script:Inv `
                              -PreferCodexRescue $true -InstalledPlugins @('codex')
        $c.review.preferCodexRescue | Should -BeTrue
        $c.codexRescueAvailable     | Should -BeTrue
        $c.codexRescueRequestedButUnavailable | Should -BeFalse
    }
    It 'refuses to write true when requested but the plugin is NOT installed - reports why instead' {
        $c = New-ExpertConfig -PlanText 'x' -PlanGoal 'g' -Inventory $script:Inv `
                              -PreferCodexRescue $true -InstalledPlugins @()
        $c.review.preferCodexRescue | Should -BeFalse
        $c.codexRescueAvailable     | Should -BeFalse
        $c.codexRescueRequestedButUnavailable | Should -BeTrue
    }
    It 'not requesting it is never reported as "requested but unavailable", even when the plugin is absent' {
        $c = New-ExpertConfig -PlanText 'x' -PlanGoal 'g' -Inventory $script:Inv -InstalledPlugins @()
        $c.codexRescueRequestedButUnavailable | Should -BeFalse
    }
}

Describe 'Expert-Config.ps1 (CLI wiring)' {
    # The unit tests above call New-ExpertConfig directly, so they never exercise the script's own
    # argument handling or inventory resolution — where both #441 and #442 lived.
    BeforeAll {
        $script:CliOut  = Join-Path ([System.IO.Path]::GetTempPath()) ("expcli-" + [guid]::NewGuid().ToString('N') + ".json")
        $script:Stdout = & pwsh -NoProfile -File $script:Script `
            -PlanText 'Refactor the plugin CLI command surface' `
            -PlanGoal 'ZZZ-GOAL-MARKER' `
            -Path $script:CliOut 2>&1 | Out-String
        $script:Cli = if (Test-Path $script:CliOut) { Get-Content -Raw $script:CliOut | ConvertFrom-Json } else { $null }
    }
    AfterAll { if (Test-Path $script:CliOut) { Remove-Item $script:CliOut -Force } }

    It 'writes a contract file' {
        $script:Cli | Should -Not -BeNullOrEmpty
    }
    It 'carries the -PlanGoal through into the role objective' {
        # Regression #441: a dot-sourced param() block reset $PlanGoal in the caller's scope.
        $script:Cli.role | Should -Match 'ZZZ-GOAL-MARKER'
    }
    It 'hooks skills resolved from the real inventory' {
        # Regression #442: Get-SkillInventory was called as a function that does not exist,
        # so the swallowed error left the toolset permanently empty. Assert a NAMED skill —
        # asserting only the absence of the fallback text passes vacuously on a blank bullet.
        $script:Cli.role | Should -Match '(?m)^- \S'
    }
    It 'does not leak the inventory object into stdout' {
        $script:Stdout | Should -Not -Match 'byScope'
        $script:Stdout | Should -Not -Match 'is not recognized as a name of a cmdlet'
    }
    It 'defaults the review path to the CI-bot fallback when -PreferCodexRescue is never passed' {
        $script:Cli.review.preferCodexRescue | Should -BeFalse
    }
}

Describe 'Expert-Config.ps1 (CLI wiring) - codex-rescue opt-in surfaced, not silent (#646)' {
    # Single-element arrays only: passing a MULTI-element array as CLI args through a nested
    # `pwsh -File` invocation collapses unreliably (a Windows/PowerShell native-argv quirk, proven
    # by hand while writing this test - a real array variable came through as a single joined
    # string, or lost elements, depending on quoting). One element is all this needs to prove the
    # CLI wiring: does a truthy -InstalledPlugins value reach Test-CodexRescueAvailable intact.
    BeforeAll {
        $script:OutAvail = Join-Path ([System.IO.Path]::GetTempPath()) ("expcli-avail-" + [guid]::NewGuid().ToString('N') + ".json")
        $script:StdoutAvail = & pwsh -NoProfile -File $script:Script `
            -PlanText 'x' -PlanGoal 'g' -Path $script:OutAvail -PreferCodexRescue -InstalledPlugins codex 2>&1 | Out-String
        $script:CliAvail = if (Test-Path $script:OutAvail) { Get-Content -Raw $script:OutAvail | ConvertFrom-Json } else { $null }

        $script:OutMissing = Join-Path ([System.IO.Path]::GetTempPath()) ("expcli-missing-" + [guid]::NewGuid().ToString('N') + ".json")
        $script:StdoutMissing = & pwsh -NoProfile -File $script:Script `
            -PlanText 'x' -PlanGoal 'g' -Path $script:OutMissing -PreferCodexRescue -InstalledPlugins none 2>&1 | Out-String
        $script:CliMissing = if (Test-Path $script:OutMissing) { Get-Content -Raw $script:OutMissing | ConvertFrom-Json } else { $null }
    }
    AfterAll {
        if (Test-Path $script:OutAvail)   { Remove-Item $script:OutAvail -Force }
        if (Test-Path $script:OutMissing) { Remove-Item $script:OutMissing -Force }
    }

    It 'writes the opt-in to the contract when the plugin is available' {
        $script:CliAvail.review.preferCodexRescue | Should -BeTrue
    }
    It 'says so in the printed summary, not only in the file' {
        $script:StdoutAvail | Should -Match '(?i)codex-rescue'
    }
    It 'does NOT write the opt-in when requested but the plugin is unavailable - refuses the silent lie' {
        $script:CliMissing.review.preferCodexRescue | Should -BeFalse
    }
    It 'tells the human WHY it was not enabled, instead of quietly falling back' {
        $script:StdoutMissing | Should -Match "(?i)asked for the stricter path"
        $script:StdoutMissing | Should -Match "(?i)isn't installed"
    }
}
