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

    # The FACTORY catalog, explicitly. Without this these tests call Get-ExpertRoles, which merges
    # whatever `.agentic-board/roles.json` the working directory happens to hold — so adding a
    # local role to any project broke the plugin's own suite. A unit test of the classification
    # logic must not depend on the checkout it runs in.
    $presets = Join-Path $PSScriptRoot '..' 'presets' 'roles.json' | Resolve-Path
    $pj = Get-Content -Raw -LiteralPath $presets | ConvertFrom-Json
    $script:Factory = @{
        qualityProfile = @($pj.qualityProfile)
        roles = @($pj.roles | ForEach-Object {
            @{ name = $_.name; keywords = @($_.keywords); skills = @($_.skills) }
        })
    }
}

Describe 'Get-DomainFromPlan' {
    It 'classifies a Power BI visual plan as powerbi-report' {
        Get-DomainFromPlan -Text 'Build a Power BI visual extension using Deneb' -Catalog $script:Factory | Should -Be 'powerbi-report'
    }
    It 'classifies a DAX/measure plan as semantic-model' {
        Get-DomainFromPlan -Text 'Add a DAX measure to the semantic model and validate TMDL' -Catalog $script:Factory | Should -Be 'semantic-model'
    }
    It 'classifies a Fabric lakehouse plan as fabric' {
        Get-DomainFromPlan -Text 'Create a Fabric lakehouse ingestion pipeline' -Catalog $script:Factory | Should -Be 'fabric'
    }
    It 'falls back to generic for unrelated text' {
        Get-DomainFromPlan -Text 'Refactor the logging helper for clarity' -Catalog $script:Factory | Should -Be 'generic'
    }
    It 'is unaffected by whatever local catalog the checkout holds' {
        # The regression guard for the defect this fix answers: a local role must not be able to
        # change the factory classification these tests assert.
        $local = @{ roles = @(@{ name='swallow-everything'; keywords=@('refactor','the','a'); skills=@() }) }
        Get-DomainFromPlan -Text 'Refactor the logging helper for clarity' -Catalog $local | Should -Be 'swallow-everything'
        Get-DomainFromPlan -Text 'Refactor the logging helper for clarity' -Catalog $script:Factory | Should -Be 'generic'
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

Describe 'Catalog-driven matching' {
    It 'matches a role that exists only in a supplied catalog' {
        $cat = @{
            qualityProfile = @()
            roles = @(
                @{ name='infra'; keywords=@('terraform','helm'); skills=@('iac') },
                @{ name='generic'; keywords=@(); skills=@() }
            )
        }
        Get-DomainFromPlan -Text 'Refactor the terraform modules' -Catalog $cat | Should -Be 'infra'
    }
    It 'falls back to generic when no role in the catalog matches' {
        $cat = @{ qualityProfile=@(); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        Get-DomainFromPlan -Text 'Write a haiku' -Catalog $cat | Should -Be 'generic'
    }
    It 'hooks skills from the supplied catalog role' {
        $cat = @{ qualityProfile=@(); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@('iac') }) }
        Get-HookedSkills -Domain 'infra' -Inventory @('team:iac-helpers','unrelated') -Catalog $cat |
            Should -Contain 'team:iac-helpers'
    }
    It 'takes the quality profile from the catalog, not from code' {
        $cat = @{ qualityProfile=@('second-opinion'); roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        $h = Get-HookedSkills -Domain 'infra' -Inventory @('second-opinion','skill-creator') -Catalog $cat
        $h | Should -Contain 'second-opinion'
        $h | Should -Not -Contain 'skill-creator'   # not in this catalog's quality profile
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

Describe 'Resolve-RolePersona' {
    BeforeAll {
        $script:AgentRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agents-" + [guid]::NewGuid().ToString('N'))
        $d = Join-Path $script:AgentRoot 'agents'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'deneb-reviewer.md') -Encoding utf8 -Value @"
---
name: deneb-reviewer
description: Review a Deneb visual spec before presenting it.
---
You never invent a field or dataset. You read the real data first.
"@
    }
    AfterAll { if (Test-Path $script:AgentRoot) { Remove-Item $script:AgentRoot -Recurse -Force } }

    It 'renders the agent body when the role names an installed agent' {
        $p = Resolve-RolePersona -Role @{ name='r'; agent='deneb-reviewer' } -SearchRoots @($script:AgentRoot)
        $p | Should -Match 'never invent a field'
    }
    It 'resolves a namespaced agent name by its file stem' {
        $p = Resolve-RolePersona -Role @{ name='r'; agent='reports:deneb-reviewer' } -SearchRoots @($script:AgentRoot)
        $p | Should -Match 'never invent a field'
    }
    It 'strips the frontmatter out of the persona' {
        $p = Resolve-RolePersona -Role @{ name='r'; agent='deneb-reviewer' } -SearchRoots @($script:AgentRoot)
        $p | Should -Not -Match 'description:'
    }
    It 'falls back to inline standards when the agent is not installed' {
        $p = Resolve-RolePersona -Role @{ name='r'; agent='nope'; standards=@('Be careful.') } -SearchRoots @($script:AgentRoot) -WarningAction SilentlyContinue
        $p | Should -Match 'Be careful'
    }
    It 'warns when the named agent is not installed' {
        $w = @()
        Resolve-RolePersona -Role @{ name='r'; agent='nope' } -SearchRoots @($script:AgentRoot) -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w.Count | Should -BeGreaterThan 0
    }
    It 'prefers the agent over inline standards when both are set' {
        $p = Resolve-RolePersona -Role @{ name='r'; agent='deneb-reviewer'; standards=@('Be careful.') } -SearchRoots @($script:AgentRoot)
        $p | Should -Match 'never invent a field'
        $p | Should -Not -Match 'Be careful'
    }
    It 'returns empty for a role with neither agent nor standards' {
        Resolve-RolePersona -Role @{ name='r' } -SearchRoots @($script:AgentRoot) | Should -BeNullOrEmpty
    }
}

Describe 'Format-RoleObjective persona' {
    It 'renders the supplied persona instead of the generic paragraph' {
        $b = Format-RoleObjective -Domain 'r' -HookedSkills @('x') -PlanGoal 'g' -Persona 'You read the data first.'
        $b | Should -Match 'You read the data first'
    }
    It 'renders the generic paragraph when no persona is supplied' {
        $b = Format-RoleObjective -Domain 'r' -HookedSkills @('x') -PlanGoal 'g'
        $b | Should -Match 'you research prior-art before building'
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
