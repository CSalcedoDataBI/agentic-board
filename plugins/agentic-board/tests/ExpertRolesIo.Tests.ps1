#Requires -Modules Pester
<#  Tests for ExpertRolesIo.ps1 — loads the shipped role preset plus the optional project-local
    roles.json, validates both, and merges them into the effective catalog. Pure filesystem IO
    (no gh) behind ABIOS_EXPERTROLES_DOTSOURCE. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'ExpertRolesIo.ps1' | Resolve-Path
    $env:ABIOS_EXPERTROLES_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTROLES_DOTSOURCE = ''
}

Describe 'Get-ExpertRolePresetPath' {
    It 'points at a preset file that exists' {
        Test-Path (Get-ExpertRolePresetPath) | Should -BeTrue
    }
}

Describe 'Get-ExpertRoles (factory only)' {
    BeforeEach { Clear-ExpertRolesCache }

    It 'returns the five factory roles' {
        $c = Get-ExpertRoles -LocalPath 'C:\does\not\exist\roles.json'
        @($c.roles).Count | Should -Be 5
        @($c.roles.name) | Should -Contain 'powerbi-report'
        @($c.roles.name) | Should -Contain 'semantic-model'
        @($c.roles.name) | Should -Contain 'fabric'
        @($c.roles.name) | Should -Contain 'extension'
        @($c.roles.name) | Should -Contain 'generic'
    }
    It 'preserves the declared order, most specific first' {
        $c = Get-ExpertRoles -LocalPath 'C:\does\not\exist\roles.json'
        @($c.roles.name)[0] | Should -Be 'powerbi-report'
        @($c.roles.name)[-1] | Should -Be 'generic'
    }
    It 'carries the quality profile out of the preset, not out of code' {
        $c = Get-ExpertRoles -LocalPath 'C:\does\not\exist\roles.json'
        $c.qualityProfile | Should -Contain 'skill-creator'
        $c.qualityProfile | Should -Contain 'second-opinion'
    }
    It 'keeps the factory keywords byte-for-byte' {
        $c = Get-ExpertRoles -LocalPath 'C:\does\not\exist\roles.json'
        $pbi = $c.roles | Where-Object { $_.name -eq 'powerbi-report' }
        $pbi.keywords | Should -Be @('deneb','visual','chart','dashboard','report','pbir','svg')
    }
}
