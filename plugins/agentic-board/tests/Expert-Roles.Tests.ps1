#Requires -Modules Pester
<#  Tests for Expert-Roles.ps1 — the `roles list` / `roles why` verb: show the effective catalog
    and explain which role a plan resolves to. Pure behind ABIOS_EXPERTROLESCMD_DOTSOURCE. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-Roles.ps1' | Resolve-Path
    $env:ABIOS_EXPERTROLESCMD_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTROLESCMD_DOTSOURCE = ''
    $script:Factory = @{ qualityProfile=@(); roles=@(
        @{ name='powerbi-report'; keywords=@('deneb'); skills=@('report') },
        @{ name='generic'; keywords=@(); skills=@() }) }
}

Describe 'Get-RoleSource' {
    It 'labels a role only the factory declares' {
        $local = @{ roles=@() }
        Get-RoleSource -Role @{name='powerbi-report'} -Factory $script:Factory -Local $local | Should -Be 'factory'
    }
    It 'labels a role only the project declares' {
        $local = @{ roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        Get-RoleSource -Role @{name='infra'} -Factory $script:Factory -Local $local | Should -Be 'local'
    }
    It 'labels a role the project overrides' {
        $local = @{ roles=@(@{ name='powerbi-report'; keywords=@('metabase'); skills=@() }) }
        Get-RoleSource -Role @{name='powerbi-report'} -Factory $script:Factory -Local $local |
            Should -Be 'local (overrides factory)'
    }
}

Describe 'Get-RoleMatchTrace' {
    It 'names the role and the exact keyword that decided the match' {
        $t = Get-RoleMatchTrace -Text 'Build a Deneb chart' -Catalog $script:Factory
        $t.role    | Should -Be 'powerbi-report'
        $t.keyword | Should -Be 'deneb'
    }
    It 'reports generic with no keyword when nothing matches' {
        $t = Get-RoleMatchTrace -Text 'Write a haiku' -Catalog $script:Factory
        $t.role    | Should -Be 'generic'
        $t.keyword | Should -BeNullOrEmpty
    }
    It 'lists the roles it evaluated, in precedence order' {
        $t = Get-RoleMatchTrace -Text 'Write a haiku' -Catalog $script:Factory
        $t.evaluated | Should -Be @('powerbi-report','generic')
    }
    It 'stops evaluating at the first hit' {
        $t = Get-RoleMatchTrace -Text 'Build a Deneb chart' -Catalog $script:Factory
        $t.evaluated | Should -Be @('powerbi-report')
    }
}
