#Requires -Modules Pester
<#  The plugin-update verb is reachable and documented (epic #711, docs half of #716).

    A verb nobody can find does not exist: /board must list it, route it to its reference, the reference
    must name the scripts that really ship, and the README catalog derived from the command frontmatter
    must be current. These are the assertions that fail if one of those links is dropped.  #>

BeforeAll {
    $script:Plugin = Join-Path $PSScriptRoot '..' | Resolve-Path
    $script:Board = Get-Content (Join-Path $script:Plugin 'commands' 'board.md') -Raw
    $script:Skill = Get-Content (Join-Path $script:Plugin 'skills' 'projects-admin' 'SKILL.md') -Raw
    $script:Ref = Get-Content (Join-Path $script:Plugin 'skills' 'projects-admin' 'references' 'verbs-plugins.md') -Raw
}

Describe '/board plugins is discoverable' {
    It 'is a numbered entry in the /board menu' {
        $script:Board | Should -Match '(?m)^23\.\s+plugins\s'
    }
    It 'is named in the /board description (the generated README catalog reads it)' {
        $script:Board | Should -Match '(?m)^description:.*/plugins\.'
    }
    It 'routes to its reference from /board and from the projects-admin skill' {
        $script:Board | Should -Match 'references/verbs-plugins\.md'
        $script:Skill | Should -Match 'references/verbs-plugins\.md'
    }
    It 'documents all three actions' {
        $script:Ref | Should -Match '/board plugins sessions'
        $script:Ref | Should -Match '/board plugins clean'
        $script:Ref | Should -Match '(?m)^\|\s*`/board plugins`'
    }
    It 'the README catalog is current with the command frontmatter' {
        $out = pwsh -NoProfile -File (Join-Path $script:Plugin 'scripts' 'Update-Docs.ps1') -Check 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'dot-sourcing Board-Work.ps1 cannot silently reset a parameter of these scripts' {
    # The scripts load Board-Work.ps1 (for Test-SessionStartConsistent) with its documented guard. Its
    # param() block runs in the caller's scope, so a parameter name shared with it would be reset - and only
    # the ones the caller passed are replayed afterwards. This pins the precondition: the only shared name is
    # DryRun, which is a switch with the same default on both sides.
    It 'shares no parameter name with Board-Work.ps1 except DryRun' {
        $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
        $bw = @((Get-Command (Join-Path $script:Plugin 'scripts' 'Board-Work.ps1')).Parameters.Keys | Where-Object { $common -notcontains $_ })
        foreach ($n in 'Update-AllPlugins.ps1', 'Get-PluginSessionMap.ps1', 'Remove-OldPluginVersions.ps1') {
            $own = @((Get-Command (Join-Path $script:Plugin 'scripts' $n)).Parameters.Keys | Where-Object { $common -notcontains $_ })
            $shared = @($own | Where-Object { $bw -contains $_ -and $_ -ne 'DryRun' })
            $shared | Should -BeNullOrEmpty -Because "$n would have '$($shared -join ', ')' reset by dot-sourcing Board-Work.ps1"
        }
    }
    It 'the one shared name, DryRun, is a switch in both' {
        (Get-Command (Join-Path $script:Plugin 'scripts' 'Board-Work.ps1')).Parameters['DryRun'].ParameterType.Name | Should -Be 'SwitchParameter'
        (Get-Command (Join-Path $script:Plugin 'scripts' 'Update-AllPlugins.ps1')).Parameters['DryRun'].ParameterType.Name | Should -Be 'SwitchParameter'
    }
}

Describe 'the reference tells the truth about the code' {
    It 'every script it names exists' {
        $names = [regex]::Matches($script:Ref, 'scripts/([A-Za-z][A-Za-z0-9-]+\.(?:ps1|cmd))') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        @($names).Count | Should -BeGreaterOrEqual 4  # the four verb scripts and the cmd shim
        foreach ($n in $names) { Test-Path -LiteralPath (Join-Path $script:Plugin 'scripts' $n) | Should -BeTrue -Because "$n is named in verbs-plugins.md" }
    }
    It 'every flag it documents is a real parameter of its script' {
        $flags = @{
            'Update-AllPlugins.ps1'        = @('DryRun', 'Only', 'Clean', 'AcceptMarketplaceCommands', 'ClaudeHome')
            'Remove-OldPluginVersions.ps1' = @('Execute', 'ShowKept', 'GraceMinutes', 'ClaudeHome')
            'Get-PluginSessionMap.ps1'     = @('Json', 'ClaudeHome')
        }
        foreach ($script in $flags.Keys) {
            $params = (Get-Command (Join-Path $script:Plugin 'scripts' $script)).Parameters.Keys
            foreach ($f in $flags[$script]) { $params | Should -Contain $f -Because "$script must have -$f" }
        }
        foreach ($f in '-DryRun', '-Only', '-Clean', '-AcceptMarketplaceCommands', '-Execute', '-ShowKept', '-GraceMinutes') {
            $script:Ref | Should -Match ([regex]::Escape($f))
        }
    }
    It 'states the honest limits: /reload-plugins is the user''s to type, MCP needs a new session, and only new-enough sessions show the notice' {
        $script:Ref | Should -Match '/reload-plugins'
        $script:Ref | Should -Match '(?i)does not reconnect plugin MCP servers|MCP servers'
        $script:Ref | Should -Match '(?i)Honest limit'
    }
    It 'documents the cmd shim in front of the notice hook: what it reads, its fail direction, and that the shim file exists' {
        $script:Ref | Should -Match 'PluginStale-NoticePreCheck\.cmd'
        $script:Ref | Should -Match '(?i)only the first payload line'
        $script:Ref | Should -Match '(?i)fc /b'
        $script:Ref | Should -Match '(?i)only ever \*skips\* work when the stamp provably'
        $script:Ref | Should -Match '(?i)inconclusive check .* is never\s+remembered'
        Test-Path -LiteralPath (Join-Path $script:Plugin 'scripts' 'PluginStale-NoticePreCheck.cmd') | Should -BeTrue
    }
    It 'says -AcceptMarketplaceCommands is off by default' {
        $script:Ref | Should -Match '(?i)off by default'
    }
    It 'forbids running a real claude plugin command while developing or testing it' {
        $script:Ref | Should -Match '(?i)Never run a real'
    }
}
