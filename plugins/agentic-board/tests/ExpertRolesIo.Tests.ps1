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

Describe 'Select-ValidExpertRoles' {
    It 'keeps a well-formed role' {
        @(Select-ValidExpertRoles -Roles @(@{ name='a'; keywords=@('k'); skills=@() })).Count | Should -Be 1
    }
    It 'drops a role with no name and warns' {
        $w = @()
        @(Select-ValidExpertRoles -Roles @(@{ keywords=@('k'); skills=@() }) -WarningVariable w 3>$null).Count | Should -Be 0
        $w.Count | Should -BeGreaterThan 0
    }
    It 'drops a role missing keywords but keeps its siblings' {
        $r = @(@{ name='bad' }, @{ name='good'; keywords=@('k'); skills=@() })
        $kept = @(Select-ValidExpertRoles -Roles $r 3>$null)
        $kept.Count | Should -Be 1
        $kept[0].name | Should -Be 'good'
    }
    It 'keeps the last of two roles sharing a name' {
        $r = @(@{ name='dup'; keywords=@('one'); skills=@() }, @{ name='dup'; keywords=@('two'); skills=@() })
        $kept = @(Select-ValidExpertRoles -Roles $r 3>$null)
        $kept.Count | Should -Be 1
        $kept[0].keywords | Should -Be @('two')
    }
}

Describe 'Add-ExpertRole' {
    BeforeEach {
        Clear-ExpertRolesCache
        $script:New = Join-Path ([System.IO.Path]::GetTempPath()) ("roles-new-" + [guid]::NewGuid().ToString('N') + ".json")
    }
    AfterEach { if (Test-Path $script:New) { Remove-Item $script:New -Force } }

    It 'creates the file with the current schema version when it does not exist' {
        Add-ExpertRole -Role @{ name='infra'; keywords=@('terraform'); skills=@('iac') } -Path $script:New | Out-Null
        $j = Get-Content -Raw $script:New | ConvertFrom-Json
        $j.version | Should -Be 1
        @($j.roles).Count | Should -Be 1
    }
    It 'round-trips: what it writes, the loader reads back identically' {
        Add-ExpertRole -Role @{ name='infra'; keywords=@('terraform','helm'); skills=@('iac') } -Path $script:New | Out-Null
        $c = Get-ExpertRoles -LocalPath $script:New -NoCache
        $r = $c.roles | Where-Object { $_.name -eq 'infra' }
        $r.keywords | Should -Be @('terraform','helm')
        $r.skills   | Should -Be @('iac')
    }
    It 'appends to an existing file without losing the roles already there' {
        Add-ExpertRole -Role @{ name='one'; keywords=@('a'); skills=@() } -Path $script:New | Out-Null
        Add-ExpertRole -Role @{ name='two'; keywords=@('b'); skills=@() } -Path $script:New | Out-Null
        $c = Get-ExpertRoles -LocalPath $script:New -NoCache
        @($c.roles.name) | Should -Contain 'one'
        @($c.roles.name) | Should -Contain 'two'
    }
    It 'replaces a role of the same name rather than duplicating it' {
        Add-ExpertRole -Role @{ name='one'; keywords=@('a'); skills=@() } -Path $script:New | Out-Null
        Add-ExpertRole -Role @{ name='one'; keywords=@('z'); skills=@() } -Path $script:New | Out-Null
        $j = Get-Content -Raw $script:New | ConvertFrom-Json
        @($j.roles).Count | Should -Be 1
        @($j.roles)[0].keywords | Should -Be @('z')
    }
}

Describe 'Get-ExpertRoles (degraded local file)' {
    BeforeEach {
        Clear-ExpertRolesCache
        $script:Bad = Join-Path ([System.IO.Path]::GetTempPath()) ("roles-bad-" + [guid]::NewGuid().ToString('N') + ".json")
    }
    AfterEach { if (Test-Path $script:Bad) { Remove-Item $script:Bad -Force } }

    It 'falls back to the factory catalog when the local file is invalid JSON' {
        Set-Content -Path $script:Bad -Value '{ this is not json' -Encoding utf8
        $c = Get-ExpertRoles -LocalPath $script:Bad -NoCache 3>$null
        @($c.roles).Count | Should -Be 5
    }
    It 'falls back to the factory catalog on an unknown schema version' {
        Set-Content -Path $script:Bad -Encoding utf8 -Value '{ "version": 99, "roles": [ { "name": "x", "keywords": ["x"], "skills": [] } ] }'
        $c = Get-ExpertRoles -LocalPath $script:Bad -NoCache 3>$null
        @($c.roles.name) | Should -Not -Contain 'x'
        @($c.roles).Count | Should -Be 5
    }
    It 'keeps the valid roles of a file that also contains a broken one' {
        Set-Content -Path $script:Bad -Encoding utf8 -Value '{ "version": 1, "roles": [ { "name": "broken" }, { "name": "ok", "keywords": ["k"], "skills": [] } ] }'
        $c = Get-ExpertRoles -LocalPath $script:Bad -NoCache 3>$null
        @($c.roles.name) | Should -Contain 'ok'
        @($c.roles.name) | Should -Not -Contain 'broken'
    }
    It 'throws when the shipped preset itself is missing' {
        { Get-ExpertRoles -PresetPath 'C:\no\such\preset.json' -LocalPath 'C:\no\such\local.json' -NoCache } |
            Should -Throw '*broken install*'
    }
}
