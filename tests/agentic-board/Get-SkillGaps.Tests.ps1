#Requires -Modules Pester
<#  Pester tests for Get-SkillGaps.ps1 — profile catalogs + gap detection against injected
    install sets (skill-clone by name, plugin by detect/marketplace). #>

BeforeAll {
    $script:Gaps      = Join-Path $PSScriptRoot '..' 'scripts' 'Get-SkillGaps.ps1' | Resolve-Path
    $script:Quality   = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' 'quality.json' | Resolve-Path
    $script:Bi        = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' 'bi.json' | Resolve-Path
}

Describe 'Get-SkillGaps — profiles' {
    It "defaults to the 'quality' profile" {
        $r = & $script:Gaps -InstalledNames @() -InstalledPlugins @()
        $r.profile | Should -Be 'quality'
        $r.summary.recommended | Should -Be (@(Get-Content $script:Quality -Raw | ConvertFrom-Json).Count)
    }
    It "resolves a named profile to its toolkits catalog file" {
        $r = & $script:Gaps -Profile bi -InstalledNames @() -InstalledPlugins @()
        $r.profile | Should -Be 'bi'
        $r.gaps.repo | Should -Contain 'microsoft/skills-for-fabric'
    }
    It "throws on an unknown profile" {
        { & $script:Gaps -Profile does-not-exist -InstalledNames @() -InstalledPlugins @() } | Should -Throw
    }
}

Describe 'Get-SkillGaps — skill-clone detection (quality)' {
    It 'reports every entry as a gap when nothing is installed' {
        $r = & $script:Gaps -CatalogPath $script:Quality -InstalledNames @() -InstalledPlugins @()
        $r.summary.installed | Should -Be 0
        $r.summary.gaps | Should -Be $r.summary.recommended
    }
    It 'detects an installed skill by name (case-insensitive), never a gap' {
        $r = & $script:Gaps -CatalogPath $script:Quality -InstalledNames @('Skill-Creator') -InstalledPlugins @()
        $r.installed.name | Should -Contain 'skill-creator'
        $r.gaps.name      | Should -Not -Contain 'skill-creator'
    }
    It 'counts installed + gaps to the full catalog (no double-count)' {
        $r = & $script:Gaps -CatalogPath $script:Quality -InstalledNames @('writing-skills','second-opinion') -InstalledPlugins @()
        ($r.summary.installed + $r.summary.gaps) | Should -Be $r.summary.recommended
        $r.summary.installed | Should -Be 2
    }
    It 'produces valid JSON' {
        $json = & $script:Gaps -CatalogPath $script:Quality -InstalledNames @() -InstalledPlugins @() -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Get-SkillGaps — plugin detection (bi)' {
    It 'detects the Fabric plugin by its detect/marketplace id, not by name' {
        # The installed skill inventory never contains "skills-for-fabric"; the marketplace does.
        $r = & $script:Gaps -Profile bi -InstalledNames @() -InstalledPlugins @('fabric-collection')
        $r.installed.repo | Should -Contain 'microsoft/skills-for-fabric'
        $r.gaps.repo      | Should -Not -Contain 'microsoft/skills-for-fabric'
    }
    It 'a matching skill name does NOT falsely satisfy a plugin entry' {
        $r = & $script:Gaps -Profile bi -InstalledNames @('skills-for-fabric') -InstalledPlugins @()
        $r.gaps.repo | Should -Contain 'microsoft/skills-for-fabric'
    }
}
