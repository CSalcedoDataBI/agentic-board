#Requires -Modules Pester
<#  Pester tests for SkillAudit-StopHook.ps1 — passive, suggest-only, never throws. #>

BeforeAll {
    $script:Hook = Join-Path $PSScriptRoot '..' 'scripts' 'SkillAudit-StopHook.ps1' | Resolve-Path
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("skillhook-" + [guid]::NewGuid().ToString('N'))

    function New-Skill {
        param([string]$RelDir, [string]$Name, [string]$Description)
        $dir = Join-Path $script:Root $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @("---","name: $Name","description: $Description","---","","# $Name") -join "`n" |
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8
    }
    # A broken skill guarantees findings.
    New-Skill '.claude/skills/proj-a/broken' 'broken' 'I can help.'
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force }
}

Describe 'SkillAudit-StopHook' {
    It 'appends a suggestion line when there are findings' {
        & $script:Hook -Root $script:Root -Quiet
        $file = Join-Path $script:Root '.agentic-board/skill-suggestions.jsonl'
        Test-Path $file | Should -BeTrue
        $last = (Get-Content $file | Select-Object -Last 1) | ConvertFrom-Json
        $last.findings | Should -BeGreaterThan 0
        $last.hint | Should -Match 'skills audit'
    }

    It 'never throws even when the root has no skills at all' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("skillhook-empty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        { & $script:Hook -Root $empty -Quiet } | Should -Not -Throw
        # No findings → no suggestions file written.
        Test-Path (Join-Path $empty '.agentic-board/skill-suggestions.jsonl') | Should -BeFalse
        Remove-Item $empty -Recurse -Force
    }
}
