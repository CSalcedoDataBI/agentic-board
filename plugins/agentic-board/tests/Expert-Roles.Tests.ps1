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
    It 'labels a role only the global (~/.agentic-board) file declares' {
        $global = @{ roles=@(@{ name='powerbi'; keywords=@('dax'); skills=@() }) }
        Get-RoleSource -Role @{name='powerbi'} -Factory $script:Factory -Global $global -Local @{ roles=@() } |
            Should -Be 'global'
    }
    It 'labels a role the global file overrides in the factory' {
        $global = @{ roles=@(@{ name='powerbi-report'; keywords=@('pbi'); skills=@() }) }
        Get-RoleSource -Role @{name='powerbi-report'} -Factory $script:Factory -Global $global -Local @{ roles=@() } |
            Should -Be 'global (overrides factory)'
    }
    It 'labels a role the project overrides that only the global file also declares' {
        $global = @{ roles=@(@{ name='infra'; keywords=@('terraform'); skills=@() }) }
        $local  = @{ roles=@(@{ name='infra'; keywords=@('helm'); skills=@() }) }
        Get-RoleSource -Role @{name='infra'} -Factory $script:Factory -Global $global -Local $local |
            Should -Be 'local (overrides global)'
    }
    It 'labels a role the project overrides that both global and factory also declare' {
        $global = @{ roles=@(@{ name='powerbi-report'; keywords=@('pbi'); skills=@() }) }
        $local  = @{ roles=@(@{ name='powerbi-report'; keywords=@('metabase'); skills=@() }) }
        Get-RoleSource -Role @{name='powerbi-report'} -Factory $script:Factory -Global $global -Local $local |
            Should -Be 'local (overrides global, factory)'
    }
}

Describe 'Get-RoleMatchTrace' {
    It 'names the role and the highest-scoring keyword that decided the match' {
        $t = Get-RoleMatchTrace -Text 'Build a Deneb chart' -Catalog $script:Factory
        $t.role    | Should -Be 'powerbi-report'
        $t.keyword | Should -Be 'deneb'
    }
    It 'reports generic with no keyword when nothing matches' {
        $t = Get-RoleMatchTrace -Text 'Write a haiku' -Catalog $script:Factory
        $t.role    | Should -Be 'generic'
        $t.keyword | Should -BeNullOrEmpty
    }
    It 'lists all roles evaluated in precedence order' {
        $t = Get-RoleMatchTrace -Text 'Write a haiku' -Catalog $script:Factory
        $t.evaluated | Should -Be @('powerbi-report','generic')
    }
    It 'evaluates all roles to find the best score' {
        # The new algorithm scores all roles — it does not stop at the first hit.
        # For a plan that matches only powerbi-report, both roles still appear in evaluated.
        $t = Get-RoleMatchTrace -Text 'Build a Deneb chart' -Catalog $script:Factory
        $t.evaluated | Should -Contain 'powerbi-report'
        $t.evaluated | Should -Contain 'generic'
    }
    It 'returns runner-up roles and their scores alongside the winner' {
        # Factory: powerbi-report (deneb keyword) scores >0; generic scores 0.
        # runnerUps must list every non-winning role with its score.
        $t = Get-RoleMatchTrace -Text 'Build a Deneb chart' -Catalog $script:Factory
        $t.role     | Should -Be 'powerbi-report'
        $t.score    | Should -BeGreaterThan 0
        $t.runnerUps | Should -Not -BeNullOrEmpty
        $runner = @($t.runnerUps) | Where-Object { $_.role -eq 'generic' }
        $runner | Should -Not -BeNullOrEmpty
        $runner.score | Should -Be 0
    }
    It 'runner-up includes roles that partially match but score lower than the winner' {
        # Two-role catalog where the second role has some keyword hits but fewer/shorter than the first.
        $cat = @{ qualityProfile=@(); roles=@(
            @{ name='first';  keywords=@('alpha','beta','gamma'); skills=@() },
            @{ name='second'; keywords=@('alpha'); skills=@() }
        )}
        $t = Get-RoleMatchTrace -Text 'alpha beta gamma' -Catalog $cat
        $t.role  | Should -Be 'first'
        $runner  = @($t.runnerUps) | Where-Object { $_.role -eq 'second' }
        $runner  | Should -Not -BeNullOrEmpty
        $runner.score | Should -BeGreaterThan 0
        $runner.score | Should -BeLessThan $t.score
    }
}
