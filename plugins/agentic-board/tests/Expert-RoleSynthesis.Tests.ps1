#Requires -Modules Pester
<#  Tests for Expert-RoleSynthesis.ps1 — the deterministic skeleton the auto-expert fills.

    The LLM does the actual prior-art research; this script gives the reproducible parts:
    map a plan to a domain, hook the installed skills/profiles relevant to that domain, and
    render the role-as-objective block. Pure (no gh) behind ABIOS_EXPERTROLE_DOTSOURCE. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-RoleSynthesis.ps1' | Resolve-Path
    $env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTROLE_DOTSOURCE = ''
    $script:Inv = @(
        'reports:deneb-visuals','reports:pbi-report-design','svg-visuals',
        'semantic-models:dax','tmdl-review','tabular-editor:bpa-rules',
        'fabric-cli:fabric-cli',
        'skill-creator','writing-skills','second-opinion'   # quality profile
    )
}

Describe 'Get-DomainFromPlan' {
    It 'classifies a Power BI visual plan as powerbi-report' {
        Get-DomainFromPlan -Text 'Build a Power BI visual extension using Deneb' | Should -Be 'powerbi-report'
    }
    It 'classifies a DAX/measure plan as semantic-model' {
        Get-DomainFromPlan -Text 'Add a DAX measure to the semantic model and validate TMDL' | Should -Be 'semantic-model'
    }
    It 'classifies a Fabric lakehouse plan as fabric' {
        Get-DomainFromPlan -Text 'Create a Fabric lakehouse ingestion pipeline' | Should -Be 'fabric'
    }
    It 'falls back to generic for unrelated text' {
        Get-DomainFromPlan -Text 'Refactor the logging helper for clarity' | Should -Be 'generic'
    }
}

Describe 'Get-HookedSkills' {
    It 'hooks report skills for powerbi-report and always adds the quality profile' {
        $h = Get-HookedSkills -Domain 'powerbi-report' -Inventory $script:Inv
        $h | Should -Contain 'reports:deneb-visuals'
        $h | Should -Contain 'skill-creator'          # quality profile always included
        $h | Should -Not -Contain 'fabric-cli:fabric-cli'
    }
    It 'hooks model skills for semantic-model' {
        $h = Get-HookedSkills -Domain 'semantic-model' -Inventory $script:Inv
        $h | Should -Contain 'semantic-models:dax'
        $h | Should -Contain 'tmdl-review'
    }
    It 'generic hooks only the quality profile present in inventory' {
        $h = Get-HookedSkills -Domain 'generic' -Inventory $script:Inv
        $h | Should -Contain 'writing-skills'
        $h | Should -Not -Contain 'reports:deneb-visuals'
    }
    It 'matches the skill name, not the plugin that ships it' {
        # 'skills-for-copilot-studio:add-action' must NOT be hooked by the 'skill' pattern:
        # the plugin namespace is not the skill. Real fallout — it dragged in 30 unrelated skills.
        $inv = @('skills-for-copilot-studio:add-action','agentic-board:skills-audit')
        $h = Get-HookedSkills -Domain 'extension' -Inventory $inv
        $h | Should -Contain 'agentic-board:skills-audit'
        $h | Should -Not -Contain 'skills-for-copilot-studio:add-action'
    }
    It 'deduplicates an inventory that lists the same skill twice' {
        # Worktrees and nested checkouts make the scanner report the same skill many times.
        $inv = @('agentic-board:skills-audit','agentic-board:skills-audit','skill-creator','skill-creator')
        $h = Get-HookedSkills -Domain 'extension' -Inventory $inv
        @($h).Count | Should -Be (@($h | Select-Object -Unique).Count)
    }
}

Describe 'Resolve-SkillInventory' {
    BeforeAll {
        # A real fixture tree — Get-SkillInventory.ps1 is run for real against it, no mocks.
        $script:Fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("expinv-" + [guid]::NewGuid().ToString('N'))
        foreach ($n in 'deneb-visuals','skill-creator') {
            $d = Join-Path $script:Fixture ".claude/skills/demo/$n"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -Path (Join-Path $d 'SKILL.md') -Encoding utf8 -Value @"
---
name: $n
description: Fixture skill $n. Use when testing the inventory resolver.
---
Body.
"@
        }
    }
    AfterAll { if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force } }

    It 'resolves the skill names actually present under a root' {
        $names = Resolve-SkillInventory -Root $script:Fixture -Scope project
        $names | Should -Contain 'deneb-visuals'
        $names | Should -Contain 'skill-creator'
    }
    It 'returns plain strings, not the inventory wrapper object' {
        $names = Resolve-SkillInventory -Root $script:Fixture -Scope project
        @($names).Count | Should -BeGreaterThan 0
        foreach ($n in $names) { $n | Should -BeOfType [string] }
    }
    It 'feeds Get-HookedSkills so a domain actually hooks something' {
        $names = Resolve-SkillInventory -Root $script:Fixture -Scope project
        Get-HookedSkills -Domain 'powerbi-report' -Inventory $names | Should -Contain 'deneb-visuals'
    }
    It 'returns an empty list for a root with no skills instead of throwing' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("expinv-none-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        try { @(Resolve-SkillInventory -Root $empty -Scope project).Count | Should -Be 0 }
        finally { Remove-Item $empty -Recurse -Force }
    }
}

Describe 'Format-RoleObjective' {
    It 'embeds the goal and the hooked skills' {
        $block = Format-RoleObjective -Domain 'powerbi-report' `
            -HookedSkills @('reports:deneb-visuals','skill-creator') -PlanGoal 'Ship a bar-chart visual'
        $block | Should -Match 'powerbi-report'
        $block | Should -Match 'Ship a bar-chart visual'
        $block | Should -Match 'reports:deneb-visuals'
    }
    It 'renders the no-skills fallback when nothing is hooked' {
        # @($null).Count is 1 in PowerShell, so a naive count check makes this branch unreachable
        # and emits a bare "- " bullet instead.
        Format-RoleObjective -Domain 'generic' -HookedSkills @() -PlanGoal 'g' | Should -Match 'none installed'
    }
    It 'renders the no-skills fallback when the hooked list is null' {
        Format-RoleObjective -Domain 'generic' -HookedSkills $null -PlanGoal 'g' | Should -Match 'none installed'
    }
    It 'never emits a blank bullet' {
        Format-RoleObjective -Domain 'generic' -HookedSkills $null -PlanGoal 'g' | Should -Not -Match '(?m)^- *$'
    }
}
