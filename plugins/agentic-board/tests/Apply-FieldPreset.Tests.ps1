#Requires -Modules Pester
<#  Tests for Apply-FieldPreset.ps1 - the field-list read must FAIL CLOSED (#313, part of #303).

    This is the exact repro named in #303: `$existing = (gh project field-list ... |
    ConvertFrom-Json).fields.name`. A 401 there makes $existing empty, the script concludes the
    board has NO fields, and it proceeds to CREATE every field of the preset on a board that in
    fact already has them. After #313 the read goes through Invoke-Gh, so a gh failure THROWS
    before the field-create loop.

    `gh` is mocked at the executable seam (exit 1, empty stdout). A regression to bare gh would
    not throw here, so `Should -Throw` + `field-create -Times 0 -Exactly` is what pins the fix. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Apply-FieldPreset.ps1' | Resolve-Path
}

Describe 'Apply-FieldPreset fails closed when the field-list read fails (#313)' {

    It 'THROWS instead of CREATING every field when the field-list read fails' {
        Mock gh { $global:LASTEXITCODE = 1 }
        # -Yes so the run would be non-interactive if it ever got past the read (it must not).
        { & $script:Script -Number 13 -Owner 'X' -Yes } | Should -Throw
        Should -Invoke gh -ParameterFilter { $args -contains 'field-create' } -Times 0 -Exactly
    }
}

Describe 'Apply-FieldPreset invocation ergonomics (#297)' {

    It 'accepts -ProjectNum as an alias of -Number (suite consistency)' {
        (Get-Command $script:Script).Parameters['Number'].Aliases | Should -Contain 'ProjectNum'
    }

    It 'accepts -Preset as an alias of -Lang (docs call the value a "preset")' {
        (Get-Command $script:Script).Parameters['Lang'].Aliases | Should -Contain 'Preset'
    }

    It 'the missing-preset error names the RESOLVED file path, not the raw -Lang value' {
        # A nonexistent -PresetPath is checked BEFORE any gh call, so no mock is needed. The
        # message must point at the file (so "en" never looks like an unknown preset name). #297
        $missing = Join-Path $TestDrive 'does-not-exist.json'
        { & $script:Script -Number 13 -Owner 'X' -PresetPath $missing } |
            Should -Throw -ExpectedMessage "*Preset file not found: $missing*"
    }
}
