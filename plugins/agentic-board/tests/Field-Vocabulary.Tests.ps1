#Requires -Modules Pester
<#  Tests for the central FIELD-NAME vocabulary (#671, absorbing #509).

    The English preset shipped a field GitHub refuses to create ('Type' is reserved), and the name
    was spelled by hand in five scripts; a board made with the Spanish preset was invisible to
    Board-Fill and Board-Triage. The fix is one vocabulary (Get-BoardVocabulary.ps1) that every
    script asks. These tests pin the vocabulary itself, the presets that must stay inside it, and how
    Apply-FieldPreset, Board-Changelog, Fleet-Plan and Board-Fill's helpers use it. The end-to-end
    runs of Board-Triage / Board-Fill live in Field-Vocabulary.EndToEnd.Tests.ps1. #>

BeforeAll {
    $script:Scripts = (Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path).Path
    $script:Presets = (Join-Path $PSScriptRoot '..' 'presets' | Resolve-Path).Path
    . (Join-Path $script:Scripts 'Get-BoardVocabulary.ps1')
    $script:Aacute = [string][char]0x00C1
    $script:Ntilde = [string][char]0x00F1
}

Describe 'the field vocabulary' {
    It 'knows every key the suite writes' {
        Get-BoardFieldKeys | Should -Be @('Status', 'Priority', 'Size', 'Type', 'Area', 'Estimate', 'Target')
    }
    It "lists 'Type' BEFORE 'Task Type': an existing board keeps its field, and only a fresh one falls through to the new name" {
        Get-BoardFieldNames 'Type' | Should -Be @('Type', 'Task Type', 'Tipo')
    }
    It 'maps a name of either language back to its key, case-insensitively' {
        Get-BoardFieldKey 'Tipo'      | Should -Be 'Type'
        Get-BoardFieldKey 'task type' | Should -Be 'Type'
        Get-BoardFieldKey "$($script:Aacute)rea" | Should -Be 'Area'
        Get-BoardFieldKey "Tama$($script:Ntilde)o" | Should -Be 'Size'
        Get-BoardFieldKey 'Estimado'  | Should -Be 'Estimate'
        Get-BoardFieldKey 'Sprint'    | Should -BeNullOrEmpty
    }
    It 'returns nothing for a key it has no opinion about' {
        @(Get-BoardFieldNames 'Sprint').Count | Should -Be 0
    }

    Context 'Resolve-BoardFieldName / Find-BoardField (the name THIS board uses)' {
        It "keeps reading 'Type' on a board that has it (existing boards must not change)" {
            Resolve-BoardFieldName 'Type' @('Status', 'Type', 'Area') | Should -Be 'Type'
        }
        It "finds 'Task Type' on a board the English preset created" {
            Resolve-BoardFieldName 'Type' @('Status', 'Task Type') | Should -Be 'Task Type'
        }
        It "finds 'Tipo' on a board the Spanish preset created" {
            Resolve-BoardFieldName 'Type' @('Status', 'Tipo') | Should -Be 'Tipo'
        }
        It "prefers the legacy 'Type' when a board carries two (never flips a working board)" {
            Resolve-BoardFieldName 'Type' @('Task Type', 'Type') | Should -Be 'Type'
        }
        It 'returns $null when the board has none of them' {
            Resolve-BoardFieldName 'Type' @('Status', 'Kind') | Should -BeNullOrEmpty
        }
        It 'a key outside the vocabulary is looked up by its own name' {
            Resolve-BoardFieldName 'Sprint' @('Sprint') | Should -Be 'Sprint'
        }
        It 'Find-BoardField returns the live field object' {
            $fields = @([pscustomobject]@{ name = 'Status'; id = 'F1' }, [pscustomobject]@{ name = 'Task Type'; id = 'F2' })
            (Find-BoardField -Key 'Type' -Fields $fields).id | Should -Be 'F2'
            Find-BoardField -Key 'Area' -Fields $fields | Should -BeNullOrEmpty
        }
    }

    Context 'Get-BoardFieldCoverage (what to WARN about)' {
        It 'reports found and missing keys' {
            $c = Get-BoardFieldCoverage -Keys @('Type', 'Area', 'Estimate') -Fields @([pscustomobject]@{ name = 'Tipo' })
            $c.Found     | Should -Be @('Type')
            $c.Missing   | Should -Be @('Area', 'Estimate')
            $c.NoneFound | Should -BeFalse
        }
        It 'flags NoneFound when the board has none of the fields (the silent-no-op case of #509)' {
            $c = Get-BoardFieldCoverage -Keys @('Type', 'Area') -Fields @([pscustomobject]@{ name = 'Status' }, [pscustomobject]@{ name = 'Kind' })
            $c.NoneFound | Should -BeTrue
            $c.Missing.Count | Should -Be 2
        }
    }

    Context 'Get-ItemFieldValue (reading a gh item-list row)' {
        It "reads 'Task Type' off a row gh keys 'task type' (spaces kept) - the old stripped-key lookup could not" {
            Get-ItemFieldValue ([pscustomobject]@{ 'task type' = 'Bug' }) 'Task Type' | Should -Be 'Bug'
        }
        It "reads an accented field off an accented key, and off a folded one" {
            Get-ItemFieldValue ([pscustomobject]@{ "$($script:Aacute)rea".ToLower() = 'scripts' }) "$($script:Aacute)rea" | Should -Be 'scripts'
            Get-ItemFieldValue ([pscustomobject]@{ area = 'scripts' }) "$($script:Aacute)rea" | Should -Be 'scripts'
        }
        It 'reads a camel-cased key too' {
            Get-ItemFieldValue ([pscustomobject]@{ taskType = 'Bug' }) 'Task Type' | Should -Be 'Bug'
        }
        It 'returns $null when the row has no such field' {
            Get-ItemFieldValue ([pscustomobject]@{ status = 'Backlog' }) 'Type' | Should -BeNullOrEmpty
        }
    }

    Context 'option synonyms (lookup only)' {
        It "finds a Spanish board's option for the canonical name" {
            $opts = @([pscustomobject]@{ id = 'a'; name = 'Bug' }, [pscustomobject]@{ id = 'b'; name = 'Funcionalidad' })
            (Find-FieldOption -Options $opts -Key 'Type' -Value 'Feature').id | Should -Be 'b'
        }
        It 'prefers the exact name when both exist' {
            $opts = @([pscustomobject]@{ id = 'a'; name = 'Feature' }, [pscustomobject]@{ id = 'b'; name = 'Funcionalidad' })
            (Find-FieldOption -Options $opts -Key 'Type' -Value 'Feature').id | Should -Be 'a'
        }
        It 'accepts the Spanish name as input on an English board' {
            $opts = @([pscustomobject]@{ id = 'a'; name = 'Feature' })
            (Find-FieldOption -Options $opts -Key 'Type' -Value 'Funcionalidad').id | Should -Be 'a'
        }
        It 'returns $null for an option that does not exist (never guesses)' {
            Find-FieldOption -Options @([pscustomobject]@{ id = 'a'; name = 'Bug' }) -Key 'Type' -Value 'Spike' | Should -BeNullOrEmpty
        }
        It 'normalises a synonym to its canonical name and leaves unknowns alone' {
            Get-CanonicalSynonym 'Type' 'Tarea' | Should -Be 'Chore'
            Get-CanonicalSynonym 'Type' 'Docs'  | Should -Be 'Docs'
        }
        It 'does NOT feed the rename/merge machinery (Apply-FieldPreset must never rewrite Spanish options into English)' {
            Get-CanonicalOptionName 'Type' 'Funcionalidad' | Should -BeNullOrEmpty
            @(Get-LegacyOptionRenames -Field 'Type' -Options @([pscustomobject]@{ id = '1'; name = 'Funcionalidad' })).Count | Should -Be 0
        }
    }
}

Describe 'the shipped presets stay inside the vocabulary' {
    BeforeAll {
        $script:En = Get-Content (Join-Path $script:Presets 'fields.en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Es = Get-Content (Join-Path $script:Presets 'fields.es.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    It "the English preset does not ship 'Type' - GitHub refuses to create it (#671)" {
        @($script:En.fields | ForEach-Object { $_.name }) | Should -Not -Contain 'Type'
        @($script:En.fields | ForEach-Object { $_.name }) | Should -Contain 'Task Type'
    }
    It 'every preset field name belongs to a key of the vocabulary' {
        foreach ($f in @($script:En.fields) + @($script:Es.fields)) {
            Get-BoardFieldKey $f.name | Should -Not -BeNullOrEmpty -Because "'$($f.name)' must be resolvable by every script"
        }
    }
    It 'both languages cover the same keys, so a board is writable whichever preset made it' {
        $enKeys = @($script:En.fields | ForEach-Object { Get-BoardFieldKey $_.name } | Sort-Object)
        $esKeys = @($script:Es.fields | ForEach-Object { Get-BoardFieldKey $_.name } | Sort-Object)
        $esKeys | Should -Be $enKeys
    }
}

Describe 'Apply-FieldPreset creates only what the board lacks, by KEY (#671)' {
    BeforeAll {
        $script:Apply = Join-Path $script:Scripts 'Apply-FieldPreset.ps1'
        function script:Get-RunLog {
            param([string]$Lang)
            $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
            try { & $script:Apply -Number 13 -Owner 'X' -Lang $Lang -Yes *> $log } catch { }
            if (Test-Path $log) { Get-Content $log -Raw } else { '' }
        }
        function script:New-FieldListJson([string[]]$Names) {
            '{"fields":[' + ((@($Names) | ForEach-Object { "{`"id`":`"F_$($_ -replace '\W','')`",`"name`":`"$_`",`"type`":`"ProjectV2Field`"}" }) -join ',') + ']}'
        }
    }

    It "a FRESH English board gets 'Task Type' created - and never 'Type'" {
        $global:FieldListJson = script:New-FieldListJson @('Title', 'Status')
        Mock gh {
            $global:LASTEXITCODE = 0
            if     ($args -contains 'field-list') { $global:FieldListJson }
            elseif ($args -contains 'graphql')    { '{"data":{"user":{"projectV2":{"field":null}}}}' }
            else                                   { '' }
        }
        $out = script:Get-RunLog 'en'
        $out | Should -Match 'created: Task Type'
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Task Type') } -Times 1 -Exactly
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Type') } -Times 0 -Exactly
    }

    It "a board that already has a legacy 'Type' is NOT given a second type field" {
        $global:FieldListJson = script:New-FieldListJson @('Title', 'Status', 'Type')
        Mock gh {
            $global:LASTEXITCODE = 0
            if     ($args -contains 'field-list') { $global:FieldListJson }
            elseif ($args -contains 'graphql')    { '{"data":{"user":{"projectV2":{"field":null}}}}' }
            else                                   { '' }
        }
        $out = script:Get-RunLog 'en'
        $out | Should -Match "skip \(exists as 'Type'\): Task Type"
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Task Type') } -Times 0 -Exactly
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Type') } -Times 0 -Exactly
    }

    It "the Spanish preset does NOT create 'Estado' beside the default 'Status' (#509 second defect)" {
        $global:FieldListJson = script:New-FieldListJson @('Title', 'Status')
        Mock gh {
            $global:LASTEXITCODE = 0
            if     ($args -contains 'field-list') { $global:FieldListJson }
            elseif ($args -contains 'graphql')    { '{"data":{"user":{"projectV2":{"field":null}}}}' }
            else                                   { '' }
        }
        $out = script:Get-RunLog 'es'
        $out | Should -Match "skip \(exists as 'Status'\): Estado"
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Estado') } -Times 0 -Exactly
        # ...and still builds the rest of the Spanish board.
        Should -Invoke gh -ParameterFilter { ($args -contains 'field-create') -and ($args -contains 'Tipo') } -Times 1 -Exactly
    }

    It 'the English preset run on a Spanish-born board does not pile English fields on top of it' {
        $global:FieldListJson = script:New-FieldListJson @('Title', 'Status', 'Prioridad', "Tama$($script:Ntilde)o", 'Tipo', "$($script:Aacute)rea", 'Estimado', 'Objetivo')
        Mock gh {
            $global:LASTEXITCODE = 0
            if     ($args -contains 'field-list') { $global:FieldListJson }
            elseif ($args -contains 'graphql')    { '{"data":{"user":{"projectV2":{"field":null}}}}' }
            else                                   { '' }
        }
        $null = script:Get-RunLog 'en'
        Should -Invoke gh -ParameterFilter { $args -contains 'field-create' } -Times 0 -Exactly
    }

    It '-DryRun lists the fields it WOULD create with the alias-aware check' {
        $global:FieldListJson = script:New-FieldListJson @('Title', 'Status', 'Type')
        Mock gh {
            $global:LASTEXITCODE = 0
            if     ($args -contains 'field-list') { $global:FieldListJson }
            elseif ($args -contains 'graphql')    { '{"data":{"user":{"projectV2":{"field":null}}}}' }
            else                                   { '' }
        }
        $log = Join-Path $TestDrive 'dry.log'
        & $script:Apply -Number 13 -Owner 'X' -Lang en -DryRun *> $log
        $text = Get-Content $log -Raw
        $text | Should -Not -Match 'Task Type'
        Should -Invoke gh -ParameterFilter { $args -contains 'field-create' } -Times 0 -Exactly
    }
}

Describe 'Board-Changelog reads the type through the vocabulary (#671)' {
    BeforeAll {
        $env:ABIOS_CHANGELOG_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Board-Changelog.ps1')
        $env:ABIOS_CHANGELOG_DOTSOURCE = ''
        function script:Node($field, $value) { [pscustomobject]@{ field = [pscustomobject]@{ name = $field }; name = $value } }
    }
    It "reads a legacy 'Type' field" {
        Get-ItemTypeName @((script:Node 'Status' 'Done'), (script:Node 'Type' 'Bug')) | Should -Be 'Bug'
    }
    It "reads 'Task Type' (the English preset's field)" {
        Get-ItemTypeName @((script:Node 'Task Type' 'Feature')) | Should -Be 'Feature'
    }
    It "reads a Spanish board's 'Tipo' and normalises the option ('Funcionalidad' -> 'Feature')" {
        Get-ItemTypeName @((script:Node 'Tipo' 'Funcionalidad')) | Should -Be 'Feature'
        Get-ItemTypeName @((script:Node 'Tipo' 'Tarea')) | Should -Be 'Chore'
    }
    It 'returns $null for an item with no type field at all (labels then decide)' {
        Get-ItemTypeName @((script:Node 'Status' 'Done')) | Should -BeNullOrEmpty
    }
}

Describe 'Fleet-Plan reads the item fields through the vocabulary (#671)' {
    BeforeAll {
        $env:ABIOS_FLEETPLAN_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Fleet-Plan.ps1')
        $env:ABIOS_FLEETPLAN_DOTSOURCE = ''
        function script:Node($field, $value) { [pscustomobject]@{ field = [pscustomobject]@{ name = $field }; name = $value } }
    }
    It "reads legacy 'Type', Size, Priority and Status" {
        $r = Read-ItemFields @((script:Node 'Status' 'Backlog'), (script:Node 'Size' 'L'), (script:Node 'Type' 'Docs'), (script:Node 'Priority' 'P1'))
        $r.Type | Should -Be 'Docs'; $r.Size | Should -Be 'L'; $r.Priority | Should -Be 'P1'; $r.Status | Should -Be 'Backlog'
    }
    It "reads 'Task Type'" {
        (Read-ItemFields @((script:Node 'Task Type' 'Bug'))).Type | Should -Be 'Bug'
    }
    It "reads a Spanish board and hands the routing rules the canonical names" {
        $r = Read-ItemFields @((script:Node 'Prioridad' 'P0'), (script:Node "Tama$($script:Ntilde)o" 'XL'), (script:Node 'Tipo' 'Tarea'))
        $r.Type | Should -Be 'Chore'; $r.Size | Should -Be 'XL'; $r.Priority | Should -Be 'P0'
    }
    It 'leaves missing fields $null' {
        (Read-ItemFields @()).Type | Should -BeNullOrEmpty
    }
}

Describe 'Board-Fill resolves and reads its fields through the vocabulary (#671)' {
    BeforeAll {
        $env:ABIOS_BOARDFILL_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Board-Fill.ps1')
        $env:ABIOS_BOARDFILL_DOTSOURCE = ''
    }
    It 'resolves the four fields of an English board with a Task Type' {
        $f = @([pscustomobject]@{ name = 'Status' }, [pscustomobject]@{ name = 'Priority' }, [pscustomobject]@{ name = 'Size' }, [pscustomobject]@{ name = 'Task Type' })
        $m = Get-FillFields $f
        $m.Type.name | Should -Be 'Task Type'
        $m.Status.name | Should -Be 'Status'
    }
    It 'resolves a Spanish board (default Status kept, the rest Spanish)' {
        $f = @([pscustomobject]@{ name = 'Status' }, [pscustomobject]@{ name = 'Prioridad' }, [pscustomobject]@{ name = "Tama$($script:Ntilde)o" }, [pscustomobject]@{ name = 'Tipo' })
        $m = Get-FillFields $f
        $m.Priority.name | Should -Be 'Prioridad'; $m.Size.name | Should -Be "Tama$($script:Ntilde)o"; $m.Type.name | Should -Be 'Tipo'
    }
    It 'gives $null for a field the board lacks' {
        (Get-FillFields @([pscustomobject]@{ name = 'Status' })).Type | Should -BeNullOrEmpty
    }
    It "reads an item's value by the LIVE field name" {
        $fv = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Task Type' }; optionId = 'o1'; name = 'Bug' })
        (Get-FillFieldValue $fv ([pscustomobject]@{ name = 'Task Type' })).optionId | Should -Be 'o1'
        Get-FillFieldValue $fv ([pscustomobject]@{ name = 'Type' }) | Should -BeNullOrEmpty
        Get-FillFieldValue $fv $null | Should -BeNullOrEmpty
    }
}
