#Requires -Modules Pester
<#  Tests for how the grouped-PR setting is SHOWN (#681).

    Grouped PRs could be turned on or off with `-PreferGroupedPRs on|off|auto`, but nothing told
    the user the feature existed as a setting, which value the repo had, or where that value came
    from. These cover the three surfaces: `-PreferGroupedPRs show` (read-only, run by the /board
    menu), the per-group line the pending list prints, and the menu text itself. The end-to-end
    cases run the real script in a throw-away git repo with NO token reachable, like the #662
    integration tests. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    $script:Plugin = Join-Path $PSScriptRoot '..'

    function New-ThrowawayRepo([string]$Name) {
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        git -C $path init -q 2>&1 | Out-Null
        $path
    }
    # Run the real script inside $Dir with no token reachable.
    function Invoke-Setting([string]$Dir, [string]$Value) {
        $saved = $env:GH_TOKEN
        $env:GH_TOKEN = ''
        try {
            Push-Location $Dir
            $out = & $script:Script -PreferGroupedPRs $Value -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 6>&1 2>&1 | Out-String
            $code = $LASTEXITCODE
            Pop-Location
            [pscustomobject]@{ out = $out; code = $code }
        } finally { $env:GH_TOKEN = $saved }
    }
}

Describe 'Get-GroupingSetting: the value a user types, and where it came from' {
    It 'no decision recorded -> auto, from the default' {
        $s = Get-GroupingSetting (Get-BoardConfigDefaults)
        $s.value  | Should -Be 'auto'
        $s.source | Should -Be 'default'
        (Get-GroupingSetting $null).source | Should -Be 'default'
    }
    It 'true / false recorded -> on / off, from the repo config' {
        $on  = Get-GroupingSetting @{ preferGroupedPRs = $true }
        $off = Get-GroupingSetting @{ preferGroupedPRs = $false }
        $on.value  | Should -Be 'on';  $on.source  | Should -Be 'config'
        $off.value | Should -Be 'off'; $off.source | Should -Be 'config'
    }
    It 'hand-written string values are read the same way' {
        (Get-GroupingSetting @{ preferGroupedPRs = 'true'  }).value | Should -Be 'on'
        (Get-GroupingSetting @{ preferGroupedPRs = 'false' }).value | Should -Be 'off'
        $a = Get-GroupingSetting @{ preferGroupedPRs = 'auto' }
        $a.value | Should -Be 'auto'; $a.source | Should -Be 'config'
    }
    It 'an UNRECOGNISED stored value is the default, never "config del repo" (intent must not be reported as fact)' {
        foreach ($garbage in @('quizas', 42, 0, 1, @{ a = 1 }, @(1, 2), '', ' ')) {
            $s = Get-GroupingSetting @{ preferGroupedPRs = $garbage }
            $s.value   | Should -Be 'auto'    -Because "'$garbage' is not a decision, so the value in force is auto"
            $s.posture | Should -Be 'auto'
            $s.source  | Should -Be 'default' -Because "'$garbage' was never a decision the repo made"
            Format-GroupingSettingLabel $s | Should -Be 'auto (por defecto)'
        }
    }
    It 'a recognised string is still a recorded decision, whatever its case or padding' {
        (Get-GroupingSetting @{ preferGroupedPRs = ' TRUE ' }).source | Should -Be 'config'
        (Get-GroupingSetting @{ preferGroupedPRs = 'False'  }).source | Should -Be 'config'
        (Get-GroupingSetting @{ preferGroupedPRs = 'Auto'   }).source | Should -Be 'config'
    }
    It 'keeps the internal posture alongside, so nothing downstream has to re-derive it' {
        (Get-GroupingSetting @{ preferGroupedPRs = $true  }).posture | Should -Be 'always'
        (Get-GroupingSetting @{ preferGroupedPRs = $false }).posture | Should -Be 'never'
        (Get-GroupingSetting @{ }).posture                           | Should -Be 'auto'
    }
}

Describe 'Format-GroupingSettingLabel' {
    It 'reads as value + source in the tool''s language' {
        Format-GroupingSettingLabel ([pscustomobject]@{ value = 'on';   source = 'config'  }) | Should -Be 'on (config del repo)'
        Format-GroupingSettingLabel ([pscustomobject]@{ value = 'auto'; source = 'default' }) | Should -Be 'auto (por defecto)'
    }
}

Describe 'Show-GroupingOffer states which setting produced each proposed group (#681)' {
    BeforeAll {
        $script:Groups = @(
            [pscustomobject]@{ reason = 'file'; evidence = 'Board-Work.ps1'; issues = @(1, 2); dropped = @() },
            [pscustomobject]@{ reason = 'area'; evidence = 'Work';           issues = @(3, 4); dropped = @() }
        )
    }
    It 'prints the setting and its source under EVERY group, and how to change it' {
        $t = Show-GroupingOffer -Suggestions $script:Groups -Posture 'auto' -SettingLabel 'auto (por defecto)' 6>&1 | Out-String
        ([regex]::Matches($t, "propuesta de PR agrupado - ajuste 'PRs agrupados': auto \(por defecto\)")).Count | Should -Be 2
        $t | Should -Match 'Cambiarlo: /board work -PreferGroupedPRs on\|off\|auto'
    }
    It 'names a repo-recorded value as such' {
        $t = Show-GroupingOffer -Suggestions $script:Groups -Posture 'always' -SettingLabel 'on (config del repo)' 6>&1 | Out-String
        $t | Should -Match "ajuste 'PRs agrupados': on \(config del repo\)"
    }
    It 'says nothing about the setting when no label is given (older callers keep their output)' {
        $t = Show-GroupingOffer -Suggestions $script:Groups -Posture 'auto' 6>&1 | Out-String
        $t | Should -Not -Match 'PRs agrupados'
    }
    It 'the pending list passes the label from the repo config (script-level wiring)' {
        $src = Get-Content -LiteralPath $script:Script -Raw
        $src | Should -Match '(?s)Show-GroupingOffer -Suggestions \$groups -Posture \$posture -CurrentRepo \$hereRepo\s*`\s*-SettingLabel \(Format-GroupingSettingLabel \(Get-GroupingSetting \$cfgRead\.config\)\)'
    }
}

Describe 'Board-Work.ps1 -PreferGroupedPRs show (read-only, no token)' {
    It 'a repo with nothing recorded says auto, from the default, and writes nothing' {
        $repo = New-ThrowawayRepo 'show-default'
        $r = Invoke-Setting $repo 'show'
        $r.code | Should -Be 0
        $r.out  | Should -Match 'PRs agrupados: auto \(por defecto\)'
        $r.out  | Should -Match 'Cambiarlo: /board work -PreferGroupedPRs on\|off\|auto'
        (Test-Path (Join-Path $repo '.agentic-board' 'config.json')) | Should -BeFalse -Because 'show must never create the config'
    }
    It 'reads back what was recorded: on, off, and back to auto' {
        $repo = New-ThrowawayRepo 'show-recorded'
        Invoke-Setting $repo 'on'  | Out-Null
        (Invoke-Setting $repo 'show').out | Should -Match 'PRs agrupados: on \(config del repo\)'
        Invoke-Setting $repo 'off' | Out-Null
        (Invoke-Setting $repo 'show').out | Should -Match 'PRs agrupados: off \(config del repo\)'
        Invoke-Setting $repo 'auto' | Out-Null
        (Invoke-Setting $repo 'show').out | Should -Match 'PRs agrupados: auto \(por defecto\)'
    }
    It 'does not change the file it reads' {
        $repo = New-ThrowawayRepo 'show-readonly'
        Invoke-Setting $repo 'on' | Out-Null
        $cfg = Join-Path $repo '.agentic-board' 'config.json'
        $before = (Get-FileHash $cfg).Hash
        Invoke-Setting $repo 'show' | Out-Null
        (Get-FileHash $cfg).Hash | Should -Be $before
    }
    It 'outside a git repo it still answers (default) instead of failing' {
        $plain = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $r = Invoke-Setting $plain 'show'
        $r.code | Should -Be 0
        $r.out  | Should -Match 'PRs agrupados: auto \(por defecto\)'
    }
    It 'a garbage stored value shows as the default end to end, not as a repo decision' {
        $repo = New-ThrowawayRepo 'show-garbage'
        New-Item -ItemType Directory -Path (Join-Path $repo '.agentic-board') -Force | Out-Null
        '{"preferGroupedPRs": 42}' | Set-Content (Join-Path $repo '.agentic-board' 'config.json')
        $r = Invoke-Setting $repo 'show'
        $r.out | Should -Match 'PRs agrupados: auto \(por defecto\)'
        $r.out | Should -Not -Match 'config del repo'
    }
    It 'a corrupt config still yields a first line with the value in force, and says it could not read it' {
        $repo = New-ThrowawayRepo 'show-corrupt'
        New-Item -ItemType Directory -Path (Join-Path $repo '.agentic-board') -Force | Out-Null
        '{not json' | Set-Content (Join-Path $repo '.agentic-board' 'config.json')
        $r = Invoke-Setting $repo 'show'
        ($r.out -split "`n")[0] | Should -Match 'PRs agrupados: auto \(por defecto\)'
        $r.out | Should -Match 'No pude leer la preferencia'
    }
}

Describe 'the /board menu shows the setting (#681)' {
    BeforeAll {
        $script:Board = Get-Content -LiteralPath (Join-Path $script:Plugin 'commands' 'board.md') -Raw
        $script:Menu  = [regex]::Match($script:Board, '(?s)```\r?\n¿Qué quieres hacer con el board\?.*?```').Value
    }
    It 'has a sub-line under work naming the setting, its current value slot and how to change it' {
        $script:Menu | Should -Match '(?m)^1\. work .*\r?\n\s+PRs agrupados en este repo: <valor del repo>'
        $script:Menu | Should -Match 'work -PreferGroupedPRs on\|off\|auto'
    }
    It 'tells the model to read the value first with the read-only command, and what to print on failure' {
        $script:Board | Should -Match 'scripts/Board-Work\.ps1 -PreferGroupedPRs show'
        $script:Board | Should -Match 'print\s+`auto \(por defecto\)`'
    }
    It 'the menu keeps its 23 numbered entries (the sub-line is not a 24th option)' {
        @([regex]::Matches($script:Menu, '(?m)^\d+\. ')).Count | Should -Be 23
    }
    It 'the work reference documents show and the three values in one place' {
        $ref = Get-Content -LiteralPath (Join-Path $script:Plugin 'skills' 'projects-admin' 'references' 'verbs-work.md') -Raw
        $ref | Should -Match 'PreferGroupedPRs show'
        $ref | Should -Match 'por\s+defecto'
        ($ref -match '`on` = group whatever overlaps') | Should -BeTrue
    }
}
