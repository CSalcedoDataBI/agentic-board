#Requires -Modules Pester
<#  Pester tests for Move-SkillsLayout.ps1.
    Builds a temp git repo with one misplaced skill and one canonical skill, then
    asserts: dry-run changes nothing, -Apply relocates only the misplaced one and
    writes skills-index.json, and a second dry-run is a no-op (idempotent). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Move-SkillsLayout.ps1' | Resolve-Path
    $script:Root   = Join-Path ([System.IO.Path]::GetTempPath()) ("skillmove-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

    function New-Skill {
        param([string]$RelDir, [string]$Name, [string]$Description)
        $dir = Join-Path $script:Root $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @("---","name: $Name","description: $Description","---","","# $Name") -join "`n" |
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8
    }

    New-Skill 'tools/loose-skill' 'loose-skill' 'Does a scattered thing. Use when the user needs the loose thing.'
    New-Skill '.claude/skills/proj-a/keeper'  'keeper' 'Keeps things tidy. Use when the user wants the keeper.'

    Push-Location $script:Root
    git init -q 2>$null | Out-Null
    git -c user.name=t -c user.email=t@t add -A 2>$null | Out-Null
    git -c user.name=t -c user.email=t@t commit -qm init 2>$null | Out-Null
    Pop-Location
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force }
}

Describe 'Move-SkillsLayout' {
    It 'plans exactly one move (the misplaced skill) in dry-run and changes nothing' {
        $r = & $script:Script -Root $script:Root
        $r.moves.Count | Should -Be 1
        $r.moves[0].name | Should -Be 'loose-skill'
        # Original still there, nothing relocated, no index yet.
        Test-Path (Join-Path $script:Root 'tools/loose-skill/SKILL.md') | Should -BeTrue
        Test-Path (Join-Path $script:Root '.claude/skills/tools/loose-skill/SKILL.md') | Should -BeFalse
        Test-Path (Join-Path $script:Root '.claude/skills/skills-index.json') | Should -BeFalse
    }

    It 'leaves the canonical skill out of the plan' {
        $r = & $script:Script -Root $script:Root
        @($r.moves | Where-Object name -eq 'keeper').Count | Should -Be 0
    }

    It 'relocates the misplaced skill and writes the index on -Apply' {
        $r = & $script:Script -Root $script:Root -Apply
        $r.applied | Should -BeTrue
        Test-Path (Join-Path $script:Root '.claude/skills/tools/loose-skill/SKILL.md') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'tools/loose-skill/SKILL.md') | Should -BeFalse
        $idx = Join-Path $script:Root '.claude/skills/skills-index.json'
        Test-Path $idx | Should -BeTrue
        $names = (Get-Content $idx -Raw | ConvertFrom-Json).name
        $names | Should -Contain 'loose-skill'
        $names | Should -Contain 'keeper'
    }

    It 'is idempotent — a second dry-run has nothing to move' {
        $r = & $script:Script -Root $script:Root
        $r.moves.Count | Should -Be 0
    }
}
