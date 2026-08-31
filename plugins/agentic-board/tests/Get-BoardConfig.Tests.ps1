#Requires -Modules Pester
<#  Pester tests for Get-BoardConfig.ps1 - the per-repo preference file (#662).

    The script is pure at load (functions only), so it is dot-sourced directly.
    Every filesystem test runs inside a fresh TestDrive path - no repo state is touched. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-BoardConfig.ps1' | Resolve-Path
    . $script:Script
}

Describe 'Read-BoardConfig' {
    It 'returns the defaults, ok, when the file does not exist' {
        $p = Join-Path $TestDrive 'missing.json'
        $r = Read-BoardConfig -Path $p
        $r.ok     | Should -BeTrue
        $r.exists | Should -BeFalse
        $r.config['preferGroupedPRs'] | Should -BeNullOrEmpty
    }

    It 'returns the defaults, ok, when no path can be resolved' {
        $r = Read-BoardConfig -Path ''
        $r.ok     | Should -BeTrue
        $r.exists | Should -BeFalse
    }

    It 'reads a recorded true' {
        $p = Join-Path $TestDrive 'true.json'
        '{ "preferGroupedPRs": true }' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok | Should -BeTrue
        $r.config['preferGroupedPRs'] | Should -BeTrue
    }

    It 'reads a recorded false - a decision, not an absence' {
        $p = Join-Path $TestDrive 'false.json'
        '{ "preferGroupedPRs": false }' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok | Should -BeTrue
        $r.config['preferGroupedPRs'] | Should -BeFalse
    }

    It 'keeps unrecognised keys out of the returned config without failing' {
        $p = Join-Path $TestDrive 'extra.json'
        '{ "preferGroupedPRs": true, "somethingNewer": 42 }' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok | Should -BeTrue
        $r.config['preferGroupedPRs'] | Should -BeTrue
        $r.config.ContainsKey('somethingNewer') | Should -BeFalse
    }

    It 'reports invalid JSON instead of silently returning the defaults' {
        $p = Join-Path $TestDrive 'bad.json'
        '{ not json' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok     | Should -BeFalse
        $r.exists | Should -BeTrue
        $r.error  | Should -Match 'JSON'
    }

    It 'reports an empty file as unreadable, not as an empty decision' {
        $p = Join-Path $TestDrive 'empty.json'
        '' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'vacio'
    }

    It 'reports a JSON scalar (not an object) as unreadable' {
        $p = Join-Path $TestDrive 'scalar.json'
        '"just a string"' | Set-Content -LiteralPath $p
        $r = Read-BoardConfig -Path $p
        $r.ok | Should -BeFalse
    }
}

Describe 'Set-BoardConfigValue' {
    It 'creates the file and the key when neither exists' {
        $p = Join-Path $TestDrive 'new' 'config.json'
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $true | Out-Null
        (Read-BoardConfig -Path $p).config['preferGroupedPRs'] | Should -BeTrue
    }

    It 'overwrites the key on a second write' {
        $p = Join-Path $TestDrive 'flip.json'
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $true  | Out-Null
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $false | Out-Null
        (Read-BoardConfig -Path $p).config['preferGroupedPRs'] | Should -BeFalse
    }

    It 'preserves keys it does not recognise - a newer version must survive an older write' {
        $p = Join-Path $TestDrive 'preserve.json'
        '{ "somethingNewer": 42 }' | Set-Content -LiteralPath $p
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $true | Out-Null
        $raw = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $raw.somethingNewer   | Should -Be 42
        $raw.preferGroupedPRs | Should -BeTrue
    }

    It 'does NOT absorb the .NET properties of a JSON scalar as config keys' {
        # `"just a string"` parses fine - it is valid JSON, just not an object. The old writer
        # accepted it as one and enumerated the STRING's properties, producing
        # {"Length": 13, "preferGroupedPRs": true} in the repo's committed config file.
        $p = Join-Path $TestDrive 'scalar-write.json'
        '"just a string"' | Set-Content -LiteralPath $p
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $true | Out-Null
        $raw = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $raw.PSObject.Properties.Name | Should -Be @('preferGroupedPRs')
        $raw.preferGroupedPRs | Should -BeTrue
    }

    It 'does NOT absorb the properties of a JSON array either' {
        $p = Join-Path $TestDrive 'array-write.json'
        '[1, 2, 3]' | Set-Content -LiteralPath $p
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $false | Out-Null
        $raw = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $raw.PSObject.Properties.Name | Should -Be @('preferGroupedPRs')
    }

    It 'writes readable JSON over a corrupt file rather than refusing forever' {
        $p = Join-Path $TestDrive 'wascorrupt.json'
        '{ not json' | Set-Content -LiteralPath $p
        Set-BoardConfigValue -Path $p -Key 'preferGroupedPRs' -Value $true | Out-Null
        $r = Read-BoardConfig -Path $p
        $r.ok | Should -BeTrue
        $r.config['preferGroupedPRs'] | Should -BeTrue
    }
}

Describe 'Resolve-GroupingPosture' {
    It 'is auto when nothing was recorded' {
        Resolve-GroupingPosture (Get-BoardConfigDefaults) | Should -BeExactly 'auto'
    }
    It 'is auto for a null config object' {
        Resolve-GroupingPosture $null | Should -BeExactly 'auto'
    }
    It 'is always for true' {
        Resolve-GroupingPosture @{ preferGroupedPRs = $true } | Should -BeExactly 'always'
    }
    It 'is never for false - the repo said one PR per issue, and that must not read as no answer' {
        Resolve-GroupingPosture @{ preferGroupedPRs = $false } | Should -BeExactly 'never'
    }
    It 'accepts the strings a hand-edited file is likely to carry' {
        Resolve-GroupingPosture @{ preferGroupedPRs = 'true'  } | Should -BeExactly 'always'
        Resolve-GroupingPosture @{ preferGroupedPRs = 'false' } | Should -BeExactly 'never'
        Resolve-GroupingPosture @{ preferGroupedPRs = 'auto'  } | Should -BeExactly 'auto'
    }
    It 'falls back to auto on a value it cannot read, never to a silent never' {
        Resolve-GroupingPosture @{ preferGroupedPRs = 'quizas' } | Should -BeExactly 'auto'
    }
}
