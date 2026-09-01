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

Describe 'Apply-FieldPreset never reports a field it failed to create (#649)' {

    # The lie this pins: `gh project field-create` was called RAW and its exit code was never
    # read, so `created: <name>` printed whether the field was created or refused. GitHub now
    # rejects a custom field named "Type" ("Name cannot have a reserved value"), which makes it
    # fire on every fresh English board - reported four separate times (#649, #654, #658, #667)
    # because the run reads clean. `gh` is mocked at the executable seam: the field-list read
    # succeeds and returns an empty board, every field-create fails.

    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Apply-FieldPreset.ps1' | Resolve-Path

        # All streams to a FILE, and the terminating error swallowed. The run is SUPPOSED to end
        # in an error now, and `... | Out-String` inside a throwing pipeline never assigns - which
        # would fail these tests on the very behaviour they exist to prove. A file is written as
        # the run goes, so everything printed before the error survives it.
        function script:Get-RunOutput {
            param([string]$LogDir)
            $log = Join-Path $LogDir ([guid]::NewGuid().ToString('N') + '.log')
            try { & $script:Script -Number 13 -Owner 'X' -Lang en -Yes *> $log } catch { }
            if (Test-Path $log) { return (Get-Content $log -Raw) }
            return ''
        }
    }

    BeforeEach {
        Mock gh {
            if ($args -contains 'field-list')   { $global:LASTEXITCODE = 0; return '{"fields":[]}' }
            # The colour pass reads each single-select field back. On an empty board the honest
            # answer is "no such field yet" - a graphql body with a null field and NO errors[],
            # which Invoke-Gh accepts (absent) rather than rejecting (failed).
            if ($args -contains 'graphql') {
                $global:LASTEXITCODE = 0
                return '{"data":{"user":{"projectV2":{"field":null}}}}'
            }
            if ($args -contains 'field-create') {
                $global:LASTEXITCODE = 1
                # -ErrorAction Continue on purpose: the script runs under
                # $ErrorActionPreference='Stop', where a plain Write-Error in the mock would
                # TERMINATE the run and make these tests fail for the wrong reason - the script
                # would never reach the reporting code under test. A real native gh does not
                # throw either; it writes to stderr and exits non-zero.
                Write-Error -ErrorAction Continue 'GraphQL: Name cannot have a reserved value, Name has already been taken (createProjectV2Field)'
                return
            }
            $global:LASTEXITCODE = 0
        }
    }

    It 'does NOT print "created:" for a field the API refused' {
        script:Get-RunOutput -LogDir $TestDrive | Should -Not -Match 'created:\s*Type'
    }

    It 'prints a FAILED line naming the field and the reason' {
        $out = script:Get-RunOutput -LogDir $TestDrive
        $out | Should -Match 'FAILED:\s*Type'
        $out | Should -Match 'reserved value'
    }

    It 'ENDS IN A HARD ERROR naming the fields that were not created' {
        # NOT an assertion on $LASTEXITCODE: the mocked gh sets it itself, so that check passed
        # even against the unfixed script - green for a reason that had nothing to do with the
        # behaviour. The terminating error is the real contract, and it is what makes
        # Resolve-Board warn instead of printing "preset applied" over a half-built board.
        { & $script:Script -Number 13 -Owner 'X' -Lang en -Yes *> (Join-Path $TestDrive 'throw.log') } |
            Should -Throw -ExpectedMessage '*NO se crearon*Type*'
    }

    It 'never reads $failedFields before the line that declares it (review of #672)' {
        # The first cut of this fix pasted the end-of-run failure report into the -DryRun branch
        # as well, ABOVE the `$failedFields = @()` that feeds it. Today that is only dead code -
        # $null.Count is not an error without Set-StrictMode - so a behavioural test passes with
        # the defect in place and proves nothing. The defect is STRUCTURAL, so the assertion is
        # too: walk the AST and require every read of the variable to come after its assignment.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                   $script:Script, [ref]$null, [ref]$null)

        $vars = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.VariablePath.UserPath -eq 'failedFields' }, $true)

        $assign = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq 'failedFields' }, $true) |
            Sort-Object { $_.Extent.StartLineNumber } | Select-Object -First 1

        $assign | Should -Not -BeNullOrEmpty -Because 'the accumulator must be declared somewhere'

        $tooEarly = @($vars | Where-Object { $_.Extent.StartLineNumber -lt $assign.Extent.StartLineNumber } |
                              ForEach-Object { "line $($_.Extent.StartLineNumber)" })
        $tooEarly -join ', ' | Should -BeNullOrEmpty
    }

    It '-DryRun still creates nothing' {
        { & $script:Script -Number 13 -Owner 'X' -Lang en -DryRun *> (Join-Path $TestDrive 'dry.log') } |
            Should -Not -Throw
        Should -Invoke gh -ParameterFilter { $args -contains 'field-create' } -Times 0 -Exactly
    }

    It 'still attempts the REMAINING fields instead of aborting on the first refusal' {
        # Honest reporting must not cost coverage: one rejected name must not strand the fields
        # after it. Target is the last field of the English preset.
        script:Get-RunOutput -LogDir $TestDrive | Out-Null
        Should -Invoke gh -ParameterFilter {
            ($args -contains 'field-create') -and ($args -contains 'Target')
        } -Times 1
    }
}
