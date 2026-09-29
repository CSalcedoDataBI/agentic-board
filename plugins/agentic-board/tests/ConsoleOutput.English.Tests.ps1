#Requires -Modules Pester
<#  Console output is English - a ratchet over the Spanish that is still there (#cleanup, epic #732).

    The product owner, reading the tool: "it has things in Spanish ... it looks really odd". Names
    were fixed first (CommandSurface: no Spanish verb, menu entry or parameter). This covers what the
    scripts PRINT. The agent relays every result in the user's own language, so the tool itself
    speaks one language: English. Hundreds of messages predate that rule, so this is a ratchet, like
    the raw-gh lint: every file's count of Spanish messages is frozen, a file not listed must have
    none, and a file whose count drops must lower its entry so the gain is locked in.

    What counts: the text of every Write-Host argument, extracted from the AST by
    Get-WriteHostArgumentText (Find-InternalVocabularyLeak.ps1), matched against accented letters
    and common Spanish words. A heuristic - good enough to stop NEW Spanish from landing. #>

BeforeAll {
    $env:ABIOS_VOCABLEAK_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Find-InternalVocabularyLeak.ps1' | Resolve-Path)
    $env:ABIOS_VOCABLEAK_DOTSOURCE = ''
    $script:Spanish = '(?i)[áéíóúñ¿¡]|\b(que|para|los|las|una|unos|sin|con|esta|pude|puedo|hay|rama|ramas|sesion|sesiones|borrar|limpiar|todavia|tambien|aqui|ningun|ninguna|nada|corre|revisa|listo|lista|quedo|sigue|siguen|mas|dias|hecho|cambio|cambios|abiertos|pendientes|borrador|omitido|conservo|conserva)\b'
    # Frozen 2026-09-29. Lower an entry when a file gets translated; never raise one.
    $script:Baseline = @{
        'Apply-FieldPreset.ps1' = 19
        'Assert-BoardComplete.ps1' = 3
        'Backup-Board.ps1' = 1
        'Board-Breakdown.ps1' = 1
        'Board-Changelog.ps1' = 3
        'Board-Depend.ps1' = 1
        'Board-Doctor.ps1' = 33
        'Board-Fill.ps1' = 6
        'Board-Merge.ps1' = 16
        'Board-Plan.ps1' = 3
        'Board-ReviewGate.ps1' = 47
        'Board-Triage.ps1' = 12
        'Board-Work.ps1' = 142
        'BoardWork.Capacity.ps1' = 1
        'Bpa-GateReview.ps1' = 2
        'Clear-AbiosState.ps1' = 5
        'Expert-Auto.ps1' = 5
        'Expert-WorkClass.ps1' = 6
        'Find-DuplicateIssue.ps1' = 4
        'Fleet-Findings.ps1' = 1
        'Fleet-Handoff.ps1' = 3
        'Fleet-Ownership.ps1' = 4
        'Fleet-Plan.ps1' = 3
        'Fleet-Supervisor.ps1' = 6
        'Get-ActionsCostAudit.ps1' = 11
        'Install-RepoTemplates.ps1' = 4
        'Invoke-FieldScan.ps1' = 10
        'New-BoardPR.ps1' = 6
        'Publish-DocsWiki.ps1' = 5
        'Resolve-Board.ps1' = 2
        'Set-BoardField.ps1' = 1
        'Tmdl-DiffReview.ps1' = 5
    }
    function script:Get-SpanishCount([string]$Path) {
        @(Get-WriteHostArgumentText -Path $Path | Where-Object { $_.Text -match $script:Spanish }).Count
    }
}

Describe 'Console output is English (ratchet over the Spanish still printed)' {
    It 'the detector is not vacuous - it sees Spanish and passes English' {
        'No pude listar los PRs' | Should -Match $script:Spanish
        'Could not list the PRs' | Should -Not -Match $script:Spanish
    }
    It 'every script matches its frozen count of Spanish messages EXACTLY' {
        $violations = foreach ($f in Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'scripts') -Filter '*.ps1') {
            $count = script:Get-SpanishCount $f.FullName
            $allowed = if ($script:Baseline.ContainsKey($f.Name)) { $script:Baseline[$f.Name] } else { 0 }
            if ($count -gt $allowed) { "{0}: {1} Spanish message(s), baseline {2} - write new console output in English (the agent translates for the user)" -f $f.Name, $count, $allowed }
            elseif ($count -lt $allowed) { "{0}: {1} Spanish message(s), baseline {2} - lower this file's baseline entry to {1} so the translation is locked in" -f $f.Name, $count, $allowed }
        }
        $violations | Should -BeNullOrEmpty -Because ($violations -join '; ')
    }
    It 'the cleanup scripts, written under this rule, print no Spanish at all' {
        foreach ($n in 'Cleanup-Sessions.ps1', 'Cleanup-Transcripts.ps1', 'Cleanup-Disk.ps1') {
            script:Get-SpanishCount (Join-Path $PSScriptRoot '..' 'scripts' $n) | Should -Be 0 -Because "$n was written after the English-output rule"
            $script:Baseline.ContainsKey($n) | Should -BeFalse
        }
    }
}