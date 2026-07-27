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
