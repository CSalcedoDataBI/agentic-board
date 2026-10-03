#Requires -Modules Pester
<#  Pester tests for Invoke-SkillAudit.ps1 and Resolve-SkillOwner.ps1.
    Fixture has one healthy skill and one broken skill (first-person, no triggers,
    no when-not clause) so the classifier's findings can be asserted. #>

BeforeAll {
    $script:Audit    = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-SkillAudit.ps1'   | Resolve-Path
    $script:Resolver = Join-Path $PSScriptRoot '..' 'scripts' 'Resolve-SkillOwner.ps1'  | Resolve-Path
    $script:Root     = Join-Path ([System.IO.Path]::GetTempPath()) ("skillaudit-" + [guid]::NewGuid().ToString('N'))

    function New-Skill {
        param([string]$RelDir, [string]$Name, [string]$Description)
        $dir = Join-Path $script:Root $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @("---","name: $Name","description: $Description","---","","# $Name") -join "`n" |
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8
    }

    New-Skill '.claude/skills/proj-a/healthy' 'healthy' `
        'Formats invoices from raw exports. Use when the user needs invoice formatting. Not for tax filing — see tax-helper.'
    New-Skill '.claude/skills/proj-a/broken' 'broken' 'I can help with stuff.'

    $script:Res = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'CSalcedoDataBI/agentic-board'
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force }
}

Describe 'Invoke-SkillAudit' {
    It 'flags the broken skill with first-person and no-triggers findings' {
        $types = @($script:Res.findings | Where-Object skill -eq 'broken').type
        $types | Should -Contain 'first-person'
        $types | Should -Contain 'no-triggers'
    }
    It 'does not flag description issues on the healthy skill' {
        @($script:Res.findings | Where-Object { $_.skill -eq 'healthy' -and $_.type -in 'first-person','no-triggers','empty-description' }).Count |
            Should -Be 0
    }
    It 'routes project findings to file on the current repo' {
        ($script:Res.findings | Select-Object -First 1).filing | Should -Be 'file'
        ($script:Res.findings | Select-Object -First 1).ownerRepo | Should -Be 'CSalcedoDataBI/agentic-board'
    }
    It 'produces valid JSON' {
        $json = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'x/y' -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Resolve-SkillOwner' {
    It 'files agentic-board plugin skills to the tool board' {
        $o = & $script:Resolver -Scope plugin -Plugin agentic-board
        $o.filing | Should -Be 'file'
        $o.ownerRepo | Should -Be 'CSalcedoDataBI/agentic-board'
    }
    It 'keeps third-party plugin skills local-only' {
        (& $script:Resolver -Scope plugin -Plugin some-other-plugin).filing | Should -Be 'local'
    }
    It 'files project skills to the current repo' {
        (& $script:Resolver -Scope project -CurrentRepo 'me/proj').ownerRepo | Should -Be 'me/proj'
    }
    It 'keeps personal skills local-only' {
        (& $script:Resolver -Scope personal).filing | Should -Be 'local'
    }
}
