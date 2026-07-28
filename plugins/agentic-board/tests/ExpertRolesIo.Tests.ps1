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

Describe 'Merge-ExpertRoles' {
    BeforeAll {
        $script:Factory = @{
            qualityProfile = @('skill-creator','second-opinion')
            roles = @(
                @{ name='powerbi-report'; keywords=@('deneb','chart'); skills=@('report') },
                @{ name='generic';        keywords=@();               skills=@() }
            )
        }
    }

    It 'adds a role the factory does not know' {
        $local = @{ roles = @(@{ name='infra'; keywords=@('terraform'); skills=@('iac') }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        @($m.roles.name) | Should -Contain 'infra'
        @($m.roles.name) | Should -Contain 'powerbi-report'
    }
    It 'places local roles before factory roles' {
        $local = @{ roles = @(@{ name='infra'; keywords=@('terraform'); skills=@('iac') }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        @($m.roles.name)[0] | Should -Be 'infra'
    }
    It 'unions keywords and skills into a factory role of the same name' {
        $local = @{ roles = @(@{ name='powerbi-report'; keywords=@('metabase'); skills=@('viz') }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        $r = $m.roles | Where-Object { $_.name -eq 'powerbi-report' }
        $r.keywords | Should -Contain 'deneb'      # factory kept
        $r.keywords | Should -Contain 'metabase'   # local added
        $r.skills   | Should -Contain 'report'
        $r.skills   | Should -Contain 'viz'
    }
    It 'gives the merged role the local position, not the factory one' {
        $local = @{ roles = @(@{ name='powerbi-report'; keywords=@('metabase'); skills=@() }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        @($m.roles.name)[0] | Should -Be 'powerbi-report'
        @($m.roles).Count   | Should -Be 2          # merged, not duplicated
    }
    It 'replace:true drops the factory keywords instead of unioning' {
        $local = @{ roles = @(@{ name='powerbi-report'; keywords=@('metabase'); skills=@('viz'); replace=$true }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        $r = $m.roles | Where-Object { $_.name -eq 'powerbi-report' }
        $r.keywords | Should -Be @('metabase')
        $r.keywords | Should -Not -Contain 'deneb'
    }
    It 'replaces agent, standards and knowledgeDomain wholesale' {
        $f = @{ qualityProfile=@(); roles=@(@{ name='r'; keywords=@('k'); skills=@(); standards=@('old') }) }
        $local = @{ roles = @(@{ name='r'; keywords=@(); skills=@(); agent='my-agent' }) }
        $m = Merge-ExpertRoles -Factory $f -Local $local
        $r = $m.roles | Where-Object { $_.name -eq 'r' }
        $r.agent | Should -Be 'my-agent'
        $r.standards | Should -BeNullOrEmpty      # setting agent clears inherited standards
    }
    It 'lets a local qualityProfile replace the factory one entirely' {
        $local = @{ roles=@(); qualityProfile = @('second-opinion') }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        $m.qualityProfile | Should -Be @('second-opinion')
    }
    It 'keeps the factory qualityProfile when the local file is silent about it' {
        $local = @{ roles = @(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $local
        $m.qualityProfile | Should -Contain 'skill-creator'
    }
    It 'returns the factory catalog untouched when there is no local file' {
        $m = Merge-ExpertRoles -Factory $script:Factory -Local $null
        @($m.roles).Count | Should -Be 2
    }
}
