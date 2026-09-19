#Requires -Modules Pester
<#  End-to-end proof for the field vocabulary (#671, absorbing #509): the REAL Board-Triage.ps1 and
    Board-Fill.ps1 run under `pwsh -File` against boards whose type field is called 'Type', 'Task
    Type' or 'Tipo', and against a board with none of the expected fields.

    The seam is a fake `gh.ps1` first on PATH (a script, so it runs in-process and keeps the
    multi-line graphql arguments intact - a .cmd cannot). The real Invoke-Gh, Get-BoardItems and
    Set-ItemField / gap detector all run; only the answers are canned. The fake LOGS every call, so
    "which field id did the write go to" is read from the `item-edit` line, not inferred. #>

BeforeAll {
    $script:Triage = (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Triage.ps1' | Resolve-Path).Path
    $script:Fill   = (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Fill.ps1'   | Resolve-Path).Path
    $script:Ntilde = [string][char]0x00F1
    $script:Aacute = [string][char]0x00C1

    $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('fakevocab' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    $script:Log = Join-Path $script:Dir 'calls.log'

    @'
$flat = (($args | ForEach-Object { "$_" }) -join ' ') -replace '\s+', ' '
Add-Content -LiteralPath $env:FAKE_LOG -Value $flat
function Emit($f) { Get-Content -LiteralPath (Join-Path $env:FAKE_DIR $f) -Raw -Encoding UTF8 }
if ($args[0] -eq 'project') {
    switch ($args[1]) {
        'field-list' { Emit 'fields.json'; exit 0 }
        'view'       { Emit 'view.json';   exit 0 }
        'item-list'  { Emit 'items.json';  exit 0 }
        'item-edit'  { exit 0 }
    }
}
if ($args[0] -eq 'api' -and $args[1] -eq 'graphql') {
    if     ($flat -match 'repositoryOwner')          { Emit 'owner.json';       exit 0 }
    elseif ($flat -match 'fields\(first:30\)')       { Emit 'fillproject.json'; exit 0 }
    elseif ($flat -match 'items\(first:100')         { Emit 'fillitems.json';   exit 0 }
    elseif ($flat -match 'repository\(owner')        { '{"data":{"repository":{"id":"R1"}}}'; exit 0 }
    elseif ($flat -match 'updateProjectV2ItemFieldValue') { '{"data":{}}'; exit 0 }
}
[Console]::Error.WriteLine("fake gh: unexpected call: $flat")
exit 1
'@ | Set-Content (Join-Path $script:Dir 'gh.ps1') -Encoding UTF8

    function ConvertTo-J($o) { $o | ConvertTo-Json -Depth 12 -Compress }
    function Set-Json($name, $obj) { [IO.File]::WriteAllText((Join-Path $script:Dir $name), (ConvertTo-J $obj), (New-Object Text.UTF8Encoding $false)) }

    # A single-select / number / text field as `gh project field-list` reports it.
    function New-SS($id, $name, [string[]]$opts) {
        @{ id = $id; name = $name; type = 'ProjectV2SingleSelectField'
           options = @($opts | ForEach-Object { @{ id = "O_$_"; name = $_ } }) }
    }
    function New-Plain($id, $name) { @{ id = $id; name = $name; type = 'ProjectV2Field' } }

    # Canned board for Board-Triage: fields + three Backlog items; $Rows carries per-item extra keys.
    function Set-TriageBoard {
        param([object[]]$Fields, [hashtable[]]$Rows = @(@{}, @{}, @{}))
        Set-Json 'fields.json' @{ fields = $Fields }
        Set-Json 'view.json' @{ id = 'PVT_1' }
        $items = @(); $n = 0
        foreach ($r in $Rows) {
            $n++
            $row = @{ id = "I$n"; status = 'Backlog'; content = @{ number = $n; title = "issue $n"; repository = 'o/r' } }
            foreach ($k in $r.Keys) { $row[$k] = $r[$k] }
            $items += $row
        }
        Set-Json 'items.json' @{ items = $items }
    }

    function Invoke-WithFakeGh {
        param([string]$Script, [string[]]$ScriptArgs)
        Remove-Item -LiteralPath $script:Log -Force -ErrorAction SilentlyContinue
        $saved = @{ PATH = $env:PATH; GH_TOKEN = $env:GH_TOKEN; FAKE_LOG = $env:FAKE_LOG; FAKE_DIR = $env:FAKE_DIR }
        try {
            $env:PATH = "$($script:Dir);$($env:PATH)"; $env:GH_TOKEN = 'not-a-real-token'
            $env:FAKE_LOG = $script:Log; $env:FAKE_DIR = $script:Dir
            $out  = (& pwsh -NoProfile -File $Script @ScriptArgs 2>&1 | Out-String)
            $code = $LASTEXITCODE
        } finally {
            $env:PATH = $saved.PATH; $env:GH_TOKEN = $saved.GH_TOKEN; $env:FAKE_LOG = $saved.FAKE_LOG; $env:FAKE_DIR = $saved.FAKE_DIR
        }
        $calls = if (Test-Path -LiteralPath $script:Log) { @(Get-Content -LiteralPath $script:Log) } else { @() }
        [pscustomobject]@{ Out = $out; Code = $code; Calls = $calls
                           Edits = @($calls | Where-Object { $_ -like 'project item-edit*' }) }
    }
}

AfterAll { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

$script:notWindows = -not $IsWindows

Describe 'Board-Triage writes the type/area/estimate/priority of ANY board vocabulary (#671, #509)' {

    It "a board with the legacy 'Type' field: writes go to it, and existing values read back" -Skip:$script:notWindows {
        Set-TriageBoard -Fields @((New-SS 'F_type' 'Type' @('Bug', 'Feature')), (New-Plain 'F_area' 'Area'), (New-Plain 'F_est' 'Estimate'), (New-SS 'F_prio' 'Priority' @('P1', 'P2'))) `
                        -Rows @(@{ type = 'Bug' }, @{})
        $r = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Issue', '2', '-Type', 'Bug', '-Area', 'scripts', '-Estimate', '3')
        $r.Code | Should -Be 0
        ($r.Edits -join "`n") | Should -Match '--field-id F_type --single-select-option-id O_Bug'
        ($r.Edits -join "`n") | Should -Match '--field-id F_area --text scripts'
        ($r.Edits -join "`n") | Should -Match '--field-id F_est --number 3'
        $r.Out | Should -Not -Match 'ATENCION|WARN'
        $p = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Pending')
        $p.Out | Should -Match 'Type=Bug'
    }

    It "a board the English preset made ('Task Type'): writes go to it, and the row key 'task type' is read" -Skip:$script:notWindows {
        Set-TriageBoard -Fields @((New-SS 'F_tt' 'Task Type' @('Bug', 'Feature')), (New-Plain 'F_area' 'Area'), (New-Plain 'F_est' 'Estimate'), (New-SS 'F_prio' 'Priority' @('P1', 'P2'))) `
                        -Rows @(@{ 'task type' = 'Feature' }, @{})
        $r = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Issue', '2', '-Type', 'Bug')
        $r.Code | Should -Be 0
        ($r.Edits -join "`n") | Should -Match '--field-id F_tt --single-select-option-id O_Bug'
        $r.Out | Should -Match 'OK\s+Task Type -> Bug'
        $p = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Pending')
        $p.Out | Should -Match 'Type=Feature'      # issue 1 - read from the 'task type' row key
        $p.Out | Should -Match '\[Type\]'          # issue 2 - blank
    }

    It "a board the SPANISH preset made: Tipo/Area/Estimado/Prioridad are written, and 'Feature' finds 'Funcionalidad' (#509)" -Skip:$script:notWindows {
        Set-TriageBoard -Fields @((New-SS 'F_tipo' 'Tipo' @('Bug', 'Funcionalidad', 'Mejora')), (New-Plain 'F_area' "$($script:Aacute)rea"), (New-Plain 'F_est' 'Estimado'), (New-SS 'F_prio' 'Prioridad' @('P1', 'P2'))) `
                        -Rows @(@{ 'tipo' = 'Bug' }, @{})
        $r = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Issue', '2', '-Type', 'Feature', '-Area', 'scripts', '-Estimate', '3', '-Priority', 'P1', '-Rationale', 'blocks', '-ConfirmPriority')
        $r.Code | Should -Be 0
        $e = $r.Edits -join "`n"
        $e | Should -Match '--field-id F_tipo --single-select-option-id O_Funcionalidad'
        $e | Should -Match '--field-id F_area --text scripts'
        $e | Should -Match '--field-id F_est --number 3'
        $e | Should -Match '--field-id F_prio --single-select-option-id O_P1'
        $r.Out | Should -Not -Match 'ATENCION|WARN'
        $p = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Pending')
        $p.Out | Should -Match 'Type=Bug'          # the Spanish row key 'tipo' is read too
    }

    It 'a board with NONE of the fields is called out loudly and nothing is written (never a silent no-op)' -Skip:$script:notWindows {
        Set-TriageBoard -Fields @((New-SS 'F_status' 'Status' @('Backlog', 'Done')), (New-SS 'F_kind' 'Kind' @('a', 'b')))
        $r = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Issue', '1', '-Type', 'Bug', '-Area', 'x')
        $r.Out | Should -Match 'ATENCION.*NINGUNO'
        $r.Out | Should -Match 'busque: Type, Task Type, Tipo'
        $r.Edits.Count | Should -Be 0
    }

    It 'a board missing only SOME of them names the missing ones' -Skip:$script:notWindows {
        Set-TriageBoard -Fields @((New-SS 'F_tt' 'Task Type' @('Bug')), (New-Plain 'F_est' 'Estimate'))
        $r = Invoke-WithFakeGh $script:Triage @('-Number', '5', '-Owner', 'o', '-Issue', '1', '-Type', 'Bug')
        $r.Out | Should -Match 'WARN el board no tiene: Area, Priority'
        $r.Edits.Count | Should -Be 1
    }
}

Describe 'Board-Fill fills and VERIFIES any board vocabulary, and says so when it cannot (#671, #509)' {
    BeforeAll {
        # One OPEN issue with an assignee, no PR, and no field values: every empty field is a gap.
        function Set-FillBoard {
            param([object[]]$Fields)
            Set-Json 'owner.json' @{ data = @{ repositoryOwner = @{ __typename = 'User' } } }
            Set-Json 'fillproject.json' @{ data = @{ user = @{ projectV2 = @{ id = 'PVT_1'; fields = @{ nodes = @($Fields) } } } } }
            Set-Json 'fillitems.json' @{ data = @{ node = @{ items = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }
                nodes = @(@{ id = 'I1'; fieldValues = @{ nodes = @() }
                             content = @{ __typename = 'Issue'; number = 1; title = 't'; state = 'OPEN'
                                          repository = @{ nameWithOwner = 'o/r' }; labels = @{ nodes = @() }
                                          assignees = @{ nodes = @(@{ login = 'o' }) }; timelineItems = @{ nodes = @() } } }) } } } }
        }
        function New-FillSS($id, $name, [string[]]$opts) { @{ id = $id; name = $name; options = @($opts | ForEach-Object { @{ id = "O_$_"; name = $_ } }) } }
    }

    It "an English board with 'Task Type': the empty type is planned as Feature" -Skip:$script:notWindows {
        Set-FillBoard @((New-FillSS 'F_s' 'Status' @('Backlog', 'Done')), (New-FillSS 'F_p' 'Priority' @('P2')), (New-FillSS 'F_z' 'Size' @('M')), (New-FillSS 'F_t' 'Task Type' @('Bug', 'Feature')))
        $r = Invoke-WithFakeGh $script:Fill @('-Owner', 'o', '-Repo', 'o/r', '-ProjectNum', '5', '-DryRun')
        $r.Out | Should -Match 'Task Type vacio -> Feature'
        $r.Out | Should -Not -Match 'ATENCION'
    }

    It "a SPANISH board (default Status + Prioridad/Tamano/Tipo): every empty field is detected, 'Feature' becomes 'Funcionalidad' (#509)" -Skip:$script:notWindows {
        Set-FillBoard @((New-FillSS 'F_s' 'Status' @('Todo', 'In Progress', 'Done')), (New-FillSS 'F_p' 'Prioridad' @('P0', 'P1', 'P2', 'P3')),
                        (New-FillSS 'F_z' "Tama$($script:Ntilde)o" @('XS', 'S', 'M', 'L', 'XL')), (New-FillSS 'F_t' 'Tipo' @('Bug', 'Funcionalidad', 'Mejora', 'Tarea')))
        $r = Invoke-WithFakeGh $script:Fill @('-Owner', 'o', '-Repo', 'o/r', '-ProjectNum', '5', '-DryRun')
        $r.Out | Should -Match 'Prioridad vacio -> P2'
        $r.Out | Should -Match 'vacio -> M'
        $r.Out | Should -Match 'Tipo vacio -> Funcionalidad'
        $r.Out | Should -Match 'Status \[\] -> Todo'
        $r.Out | Should -Not -Match 'ATENCION'
    }

    It "a legacy 'Type' board still fills (existing boards keep working)" -Skip:$script:notWindows {
        Set-FillBoard @((New-FillSS 'F_s' 'Status' @('Backlog')), (New-FillSS 'F_t' 'Type' @('Bug', 'Feature')))
        $r = Invoke-WithFakeGh $script:Fill @('-Owner', 'o', '-Repo', 'o/r', '-ProjectNum', '5', '-DryRun')
        $r.Out | Should -Match 'Type vacio -> Feature'
    }

    It 'a board with NONE of the fields says ATENCION and does NOT claim "Board completo" (the false all-clear of #509)' -Skip:$script:notWindows {
        Set-FillBoard @((New-FillSS 'F_k' 'Kind' @('a', 'b')))
        $r = Invoke-WithFakeGh $script:Fill @('-Owner', 'o', '-Repo', 'o/r', '-ProjectNum', '5', '-DryRun')
        $r.Out | Should -Match 'ATENCION.*NINGUNO'
        $r.Out | Should -Match 'NO verifique'
        $r.Out | Should -Not -Match 'Board completo'
    }

    It 'a board missing only some fields warns and does not call itself complete' -Skip:$script:notWindows {
        Set-FillBoard @((New-FillSS 'F_s' 'Status' @('Backlog')), (New-FillSS 'F_p' 'Priority' @('P2')), (New-FillSS 'F_z' 'Size' @('M')))
        $r = Invoke-WithFakeGh $script:Fill @('-Owner', 'o', '-Repo', 'o/r', '-ProjectNum', '5', '-DryRun')
        $r.Out | Should -Match 'WARN el board no tiene: Type'
    }
}
