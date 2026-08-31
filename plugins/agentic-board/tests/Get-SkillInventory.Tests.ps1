#Requires -Modules Pester
<#  Pester tests for Get-SkillInventory.ps1.
    Builds a deliberately messy skill layout in a temp fixture (canonical + misplaced
    + near-duplicate + over-cap + first-person) and asserts the inventory contract. #>

BeforeAll {
    $script:Engine = Join-Path $PSScriptRoot '..' 'scripts' 'Get-SkillInventory.ps1' | Resolve-Path
    $script:Root   = Join-Path ([System.IO.Path]::GetTempPath()) ("skillinv-" + [guid]::NewGuid().ToString('N'))

    function New-Skill {
        param([string]$RelDir, [string]$Name, [string]$Description)
        $dir = Join-Path $script:Root $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @("---","name: $Name","description: $Description","---","","# $Name","body") -join "`n" |
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8
    }

    # Canonical, well-partitioned pair with heavy keyword overlap (should flag as near-duplicate).
    New-Skill '.claude/skills/proj-a/report-builder' 'report-builder' `
        'Generate quarterly revenue reports from spreadsheets. Use when building financial revenue dashboards and reports.'
    New-Skill '.claude/skills/proj-b/revenue-reporter' 'revenue-reporter' `
        'Build quarterly revenue dashboards from spreadsheets. Use when generating financial revenue reports and dashboards.'
    # First-person description (should fail thirdPerson lint) and no trigger clause.
    New-Skill '.claude/skills/proj-a/helper-thing' 'helper-thing' 'I can help you with various tasks around here.'
    # Misplaced: a stray SKILL.md outside .claude/skills.
    New-Skill 'random/loose-skill' 'loose-skill' 'Does something useful. Use when the user needs a loose thing.'

    $script:Inv = & $script:Engine -Root $script:Root -Scope project
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force }
}

Describe 'Get-SkillInventory' {
    It 'finds all four project skills' {
        $script:Inv.skills.Count | Should -Be 4
    }
    It 'flags the stray SKILL.md as misplaced and nothing else' {
        @($script:Inv.skills | Where-Object misplaced).name | Should -Be 'loose-skill'
        $script:Inv.summary.misplaced | Should -Be 1
    }
    It 'infers the monorepo project from the canonical path' {
        ($script:Inv.skills | Where-Object name -eq 'report-builder').project | Should -Be 'proj-a'
        ($script:Inv.skills | Where-Object name -eq 'revenue-reporter').project | Should -Be 'proj-b'
    }
    It 'detects the near-duplicate pair via description overlap' {
        $script:Inv.overlaps.Count | Should -BeGreaterThan 0
        $names = @($script:Inv.overlaps[0].a, $script:Inv.overlaps[0].b)
        $names | Should -Contain 'report-builder'
        $names | Should -Contain 'revenue-reporter'
    }
    It 'fails the thirdPerson lint on a first-person description' {
        ($script:Inv.skills | Where-Object name -eq 'helper-thing').lint.thirdPerson | Should -BeFalse
    }
    It 'passes the thirdPerson lint on a proper description' {
        ($script:Inv.skills | Where-Object name -eq 'report-builder').lint.thirdPerson | Should -BeTrue
    }
    It 'flags missing trigger clauses' {
        ($script:Inv.skills | Where-Object name -eq 'helper-thing').lint.hasTriggers | Should -BeFalse
        ($script:Inv.skills | Where-Object name -eq 'loose-skill').lint.hasTriggers | Should -BeTrue
    }
    It 'produces valid JSON with -Json' {
        $json = & $script:Engine -Root $script:Root -Scope project -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
        ($json | ConvertFrom-Json).summary.total | Should -Be 4
    }
}
