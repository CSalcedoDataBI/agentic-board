#Requires -Modules Pester
<#  Tests for the two Board-Triage fixes of this file's PR:

      #511  the suite-wide -ProjectNum must bind (Apply-FieldPreset got the alias in #297; this one
            was missed);
      #605  triage of N issues must read the board ONCE, not once per issue - the per-issue full
            read is what made a 45-issue sweep exhaust the 5,000-point GraphQL quota twice.

    The end-to-end tests run the REAL script in a child `pwsh -File` (so the launcher's argument
    delivery is what is exercised) with a fake `gh.cmd` first on PATH: the real Invoke-Gh, the real
    Get-BoardItems and the real Set-ItemField all run, only the binary at the end is ours. The fake
    LOGS every call, so "how many times was the board read" is a count of `project item-list` lines,
    not an inference. A .cmd is Windows-only (CI runs Pester on windows-latest). #>

BeforeAll {
    $script:Script = (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Triage.ps1' | Resolve-Path).Path
    $env:ABIOS_TRIAGE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_TRIAGE_DOTSOURCE = ''

    $script:FakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('faketriage' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:FakeDir -Force | Out-Null
    $script:Log = Join-Path $script:FakeDir 'calls.log'

    # A fake gh.cmd: it LOGS every call, then answers the four board calls Board-Triage makes from
    # canned JSON files. Plain batch, not a pwsh per call: that made this file take minutes.
    @'
@echo off
echo %* >>"%FAKE_GH_LOG%"
if "%1 %2"=="project field-list" (type "%~dp0fields.json" & exit /b 0)
if "%1 %2"=="project view" (type "%~dp0view.json" & exit /b 0)
if "%1 %2"=="project item-list" (type "%~dp0items.json" & exit /b 0)
if "%1 %2"=="project item-edit" goto edit
echo fake gh: unexpected call: %* 1>&2
exit /b 1
:edit
if defined FAKE_GH_EDIT_FAIL goto editfail
exit /b 0
:editfail
echo HTTP 401 Bad credentials 1>&2
exit /b 1
'@ | Set-Content (Join-Path $script:FakeDir 'gh.cmd') -Encoding ASCII
    $opt = { param($id, $name) "{`"id`":`"$id`",`"name`":`"$name`"}" }
    $ss  = { param($id, $name, $opts) "{`"id`":`"$id`",`"name`":`"$name`",`"type`":`"ProjectV2SingleSelectField`",`"options`":[$($opts -join ',')]}" }
    '{"fields":[' + ((
        (& $ss 'F_type' 'Type' @((& $opt 'O_bug' 'Bug'), (& $opt 'O_feat' 'Feature'))),
        (& $ss 'F_area' 'Area' @((& $opt 'O_scripts' 'scripts'))),
        '{"id":"F_est","name":"Estimate","type":"ProjectV2Field","dataType":"NUMBER"}',
        (& $ss 'F_prio' 'Priority' @((& $opt 'O_p1' 'P1'), (& $opt 'O_p2' 'P2')))
    ) -join ',') + ']}' | Set-Content (Join-Path $script:FakeDir 'fields.json') -Encoding ASCII
    '{"id":"PVT_1"}' | Set-Content (Join-Path $script:FakeDir 'view.json') -Encoding ASCII
    $it = { param($n, $t) "{`"id`":`"I$n`",`"status`":`"Backlog`",`"content`":{`"number`":$n,`"title`":`"$t`",`"repository`":`"o/r`"}}" }
    '{"items":[' + ((& $it 1 'one'), (& $it 2 'two'), (& $it 3 'three') -join ',') + ']}' |
        Set-Content (Join-Path $script:FakeDir 'items.json') -Encoding ASCII

    # Run the real script through `pwsh -File`, with the fake gh first on PATH. Returns the output
    # text, the exit code and the log lines (one per gh call).
    function Invoke-TriageWithFakeGh {
        param([string[]]$ScriptArgs, [hashtable]$ExtraEnv = @{})
        Remove-Item -LiteralPath $script:Log -Force -ErrorAction SilentlyContinue
        $saved = @{ PATH = $env:PATH; GH_TOKEN = $env:GH_TOKEN; FAKE_GH_LOG = $env:FAKE_GH_LOG }
        try {
            $env:PATH        = "$($script:FakeDir);$($env:PATH)"
            $env:GH_TOKEN    = 'not-a-real-token'
            $env:FAKE_GH_LOG = $script:Log
            foreach ($k in $ExtraEnv.Keys) { Set-Item -Path "Env:$k" -Value $ExtraEnv[$k] }
            $out  = (& pwsh -NoProfile -File $script:Script @ScriptArgs 2>&1 | Out-String)
            $code = $LASTEXITCODE
        } finally {
            $env:PATH = $saved.PATH; $env:GH_TOKEN = $saved.GH_TOKEN; $env:FAKE_GH_LOG = $saved.FAKE_GH_LOG
            foreach ($k in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
        }
        $calls = if (Test-Path -LiteralPath $script:Log) { @(Get-Content -LiteralPath $script:Log) } else { @() }
        [pscustomobject]@{ Out = $out; Code = $code; Calls = $calls
                           Reads  = @($calls | Where-Object { $_ -like 'project item-list*' }).Count
                           Writes = @($calls | Where-Object { $_ -like 'project item-edit*' }).Count }
    }
}

AfterAll { Remove-Item $script:FakeDir -Recurse -Force -ErrorAction SilentlyContinue }

$script:notWindows = -not $IsWindows

Describe '#511 - -ProjectNum binds on Board-Triage' {
    It 'declares ProjectNum as an alias of -Number' {
        (Get-Command $script:Script).Parameters['Number'].Aliases | Should -Contain 'ProjectNum'
    }
    It 'runs end to end with -ProjectNum (the suite-wide name), reading the board it names' -Skip:$script:notWindows {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-ProjectNum', '7', '-Owner', 'o', '-Issue', '2', '-Type', 'Bug')
        $r.Out  | Should -Not -Match 'parameter cannot be found'
        $r.Code | Should -Be 0
        ($r.Calls | Where-Object { $_ -like 'project view*' }) | Should -Match ' 7 '
        $r.Writes | Should -Be 1
    }
    It 'still runs with the original -Number' -Skip:$script:notWindows {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '7', '-Owner', 'o', '-Issue', '2', '-Type', 'Bug')
        $r.Code   | Should -Be 0
        $r.Writes | Should -Be 1
    }
}

Describe 'ConvertTo-TriageRefList (#605)' {
    It 'splits the single "1,2,3" string a `pwsh -File` call delivers' {
        ConvertTo-TriageRefList @('1,2,3') | Should -Be @('1', '2', '3')
    }
    It 'keeps an already-split array and qualified refs intact' {
        ConvertTo-TriageRefList @('1', 'o/r#2') | Should -Be @('1', 'o/r#2')
    }
    It 'ignores empty pieces and stray whitespace' {
        ConvertTo-TriageRefList @(' 4 , ,5 ') | Should -Be @('4', '5')
    }
    It 'returns nothing for nothing' {
        @(ConvertTo-TriageRefList @()).Count | Should -Be 0
    }
}

Describe 'Get-TriageEntries (#605)' {
    It 'is empty (-Pending mode) when no target is given' {
        @(Get-TriageEntries).Count | Should -Be 0
    }
    It 'gives every -Issues target the command-line defaults' {
        $e = @(Get-TriageEntries -Issues @('1,2') -Defaults @{ Type = 'Bug'; Area = 'scripts'; Repo = 'o/r' })
        $e.Count | Should -Be 2
        $e[1].Issue | Should -Be '2'
        $e[1].Type  | Should -Be 'Bug'
        $e[1].Repo  | Should -Be 'o/r'
    }
    It 'unions -Issue and -Issues' {
        @(Get-TriageEntries -Issue '9' -Issues @('1', '2')).Count | Should -Be 3
    }
    Context 'a -BatchFile' {
        BeforeEach { $script:bf = Join-Path ([System.IO.Path]::GetTempPath()) ("batch$([guid]::NewGuid().ToString('N').Substring(0,8)).json") }
        AfterEach  { Remove-Item -LiteralPath $script:bf -Force -ErrorAction SilentlyContinue }

        It 'reads per-issue values, and a key on the entry beats the command-line default' {
            '[{"issue":1,"type":"Feature","estimate":3},{"issue":"o/r#2","priority":"P1","rationale":"why"}]' | Set-Content $script:bf -Encoding UTF8
            $e = @(Get-TriageEntries -BatchFile $script:bf -Defaults @{ Type = 'Bug'; Area = 'scripts' })
            $e.Count       | Should -Be 2
            $e[0].Type     | Should -Be 'Feature'
            $e[0].Estimate | Should -Be '3'
            $e[0].Area     | Should -Be 'scripts'
            $e[1].Issue    | Should -Be 'o/r#2'
            $e[1].Type     | Should -Be 'Bug'
            $e[1].Priority | Should -Be 'P1'
        }
        It 'accepts a single object as a one-entry batch' {
            '{"issue":5,"type":"Bug"}' | Set-Content $script:bf -Encoding UTF8
            @(Get-TriageEntries -BatchFile $script:bf).Count | Should -Be 1
        }
        It 'refuses a file that does not exist' {
            { Get-TriageEntries -BatchFile (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-batch.json') } | Should -Throw '*no existe*'
        }
        It 'refuses invalid JSON rather than dropping the batch silently' {
            'not json' | Set-Content $script:bf -Encoding UTF8
            { Get-TriageEntries -BatchFile $script:bf } | Should -Throw '*JSON*'
        }
        It 'refuses an entry with no "issue" key' {
            '[{"type":"Bug"}]' | Set-Content $script:bf -Encoding UTF8
            { Get-TriageEntries -BatchFile $script:bf } | Should -Throw "*falta la clave 'issue'*"
        }
    }
}

Describe 'Test-TriageEntry (#605)' {
    BeforeAll {
        function New-Entry { param($Issue = '1', $Repo = '', $Estimate = '', $Priority = '', $Rationale = '')
            [pscustomobject]@{ Issue = $Issue; Repo = $Repo; Type = ''; Area = ''; Estimate = $Estimate; Priority = $Priority; Rationale = $Rationale } }
    }
    It 'accepts a plain entry' { Test-TriageEntry (New-Entry) | Should -BeNullOrEmpty }
    It 'refuses a non-numeric Estimate, naming the issue' { Test-TriageEntry (New-Entry -Issue '7' -Estimate 'big') | Should -Match '^7: .*numerico' }
    It 'refuses a Priority outside P0-P3' { Test-TriageEntry (New-Entry -Priority 'P9' -Rationale 'x') | Should -Match 'P0, P1, P2 o P3' }
    It 'refuses a Priority with no rationale (#306 applies per entry)' { Test-TriageEntry (New-Entry -Priority 'P1') | Should -Match 'razonamiento' }
    It 'refuses a repo qualifier that is not owner/name (review of #686)' {
        Test-TriageEntry (New-Entry -Issue '42' -Repo 'not-a-repo') | Should -Match "repo debe ser owner/name.*not-a-repo"
        Test-TriageEntry (New-Entry -Issue '42' -Repo 'a/b/c')      | Should -Match 'owner/name'
        Test-TriageEntry (New-Entry -Issue '42' -Repo 'owner/repo') | Should -BeNullOrEmpty
    }
    It 'refuses a malformed ref' { Test-TriageEntry (New-Entry -Issue 'nonsense') | Should -Match 'not a valid issue reference' }
}

Describe '#605 - a batch reads the board ONCE (end to end, counted)' -Skip:$script:notWindows {
    It 'reads the board once for three issues and writes each of them' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '1,2,3', '-Type', 'Bug', '-Area', 'scripts')
        $r.Code   | Should -Be 0
        $r.Reads  | Should -Be 1
        $r.Writes | Should -Be 6          # Type + Area on each of 3 issues
        $r.Out    | Should -Match '3 de 3 issue'
    }
    It 'reads the board once for a -BatchFile with per-issue values' {
        $bf = Join-Path $script:FakeDir 'batch.json'
        '[{"issue":1,"type":"Bug"},{"issue":2,"type":"Feature","estimate":5},{"issue":3,"area":"scripts"}]' | Set-Content $bf -Encoding UTF8
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-BatchFile', $bf)
        $r.Code   | Should -Be 0
        $r.Reads  | Should -Be 1
        $r.Writes | Should -Be 4          # 1 + 2 + 1
    }
    It 'a single -Issue still reads the board once' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issue', '2', '-Type', 'Bug')
        $r.Reads | Should -Be 1
    }
    It 'refuses the WHOLE batch before any gh call when one entry is invalid' {
        $bf = Join-Path $script:FakeDir 'bad.json'
        '[{"issue":1,"type":"Bug"},{"issue":2,"estimate":"huge"}]' | Set-Content $bf -Encoding UTF8
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-BatchFile', $bf)
        $r.Code  | Should -Be 1
        $r.Out   | Should -Match 'no escribi nada'
        $r.Calls.Count | Should -Be 0      # not even the read: nothing was half-done
    }
    It 'reports an unresolvable issue at the end and still triages the rest' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '1,99,3', '-Type', 'Bug')
        $r.Code   | Should -Be 1
        $r.Reads  | Should -Be 1
        $r.Writes | Should -Be 2          # 1 and 3 written; 99 skipped, not fatal
        $r.Out    | Should -Match 'Pendientes para reintentar'
        $r.Out    | Should -Match '#99'
    }
    It 'proposes Priority for a batch without writing it unless -ConfirmPriority' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '1,2', '-Priority', 'P1', '-Rationale', 'blocks')
        $r.Writes | Should -Be 0
        $r.Out    | Should -Match '\(no escrita\)'
        $r2 = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '1,2', '-Priority', 'P1', '-Rationale', 'blocks', '-ConfirmPriority')
        $r2.Writes | Should -Be 2
    }
}

Describe 'review of #686 - batch edge cases' -Skip:$script:notWindows {
    It 'validates every entry BEFORE the first gh call of any kind, board resolution from origin included' {
        $bf = Join-Path $script:FakeDir 'bad2.json'
        '[{"issue":1,"type":"Bug"},{"issue":2,"estimate":"huge"}]' | Set-Content $bf -Encoding UTF8
        # No -Number: the board would be resolved from origin (gh api graphql) if validation ran later.
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Owner', 'o', '-BatchFile', $bf)
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'no escribi nada'
        $r.Calls.Count | Should -Be 0
    }
    It 'a row with a malformed "repo" is refused before any gh call (review of #686)' {
        $bf = Join-Path $script:FakeDir 'badrepo.json'
        '[{"issue":1,"type":"Bug"},{"issue":42,"repo":"not-a-repo","type":"Bug"}]' | Set-Content $bf -Encoding UTF8
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-BatchFile', $bf)
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'repo debe ser owner/name'
        $r.Calls.Count | Should -Be 0
    }
    It 'a ONE-row -BatchFile is still a batch: an unresolvable target is listed for retry, not thrown' {
        $bf = Join-Path $script:FakeDir 'one.json'
        '[{"issue":99,"type":"Bug"}]' | Set-Content $bf -Encoding UTF8
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-BatchFile', $bf)
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'Pendientes para reintentar'
        $r.Out  | Should -Match '#99'
    }
    It 'a ONE-item -Issues is still a batch' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '99', '-Type', 'Bug')
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'Pendientes para reintentar'
    }
    It 'a single -Issue that cannot be resolved still throws exactly as before (no retry list)' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issue', '99', '-Type', 'Bug')
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'ERROR: El issue #99 no esta en el board'
        $r.Out  | Should -Not -Match 'Pendientes para reintentar'
    }
    It 'a failed WRITE stops the batch (no more writes are issued) and lists everything not yet done' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '1,2,3', '-Type', 'Bug') -ExtraEnv @{ FAKE_GH_EDIT_FAIL = '1' }
        $r.Code   | Should -Be 1
        $r.Writes | Should -Be 1          # the first write failed; issues 2 and 3 were never attempted
        $r.Out    | Should -Match 'detengo el lote'
        $r.Out    | Should -Match 'Pendientes para reintentar'
        @($r.Out -split "`n" | Where-Object { $_ -match 'no procesado' }).Count | Should -Be 2
    }
    It 'an unresolvable target does NOT stop the batch (only a failed write does)' {
        $r = Invoke-TriageWithFakeGh -ScriptArgs @('-Number', '13', '-Owner', 'o', '-Issues', '99,2,3', '-Type', 'Bug')
        $r.Writes | Should -Be 2
        $r.Out    | Should -Not -Match 'detengo el lote'
    }
}
