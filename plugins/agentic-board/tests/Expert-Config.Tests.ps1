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
}
