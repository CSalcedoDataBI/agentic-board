#Requires -Modules Pester
<#  Pester tests for Invoke-KnowledgeHarvest.ps1: finds docs md files + http links,
    dedups against the existing registry, and never writes. #>
BeforeAll {
    $script:Engine = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-KnowledgeHarvest.ps1' | Resolve-Path
    $script:Root   = Join-Path ([IO.Path]::GetTempPath()) ("knhrv-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs') -Force | Out-Null
    "# Fabric Capacity`nbody" | Set-Content -LiteralPath (Join-Path $script:Root 'docs' 'cap.md') -Encoding utf8
    "See [Docs](https://learn.microsoft.com/z) and [Dup](https://dup/1)." | Set-Content -LiteralPath (Join-Path $script:Root 'README.md') -Encoding utf8
    # existing registry already contains the dup url -> must be deduped out
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'knowledge') -Force | Out-Null
    ([pscustomobject]@{ version=1; project='fix'; domains=@('Fabric'); references=@(
        [pscustomobject]@{ id='kn_001'; domain='Fabric'; type='url'; title='Dup'; ref='https://dup/1'; note='x'; added='2026-07-07' }
    )}) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Root 'knowledge' 'registry.json') -Encoding utf8
    $script:Res = & $script:Engine -Root $script:Root
}
AfterAll { if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force } }

Describe 'Invoke-KnowledgeHarvest' {
    It 'finds the docs md file with its heading title' {
        ($script:Res.candidates | Where-Object ref -eq 'docs/cap.md').title | Should -Be 'Fabric Capacity'
    }
    It 'finds the http link in README' {
        ($script:Res.candidates | Where-Object ref -eq 'https://learn.microsoft.com/z').type | Should -Be 'url'
    }
    It 'dedups refs already in the registry' {
        ($script:Res.candidates | Where-Object ref -eq 'https://dup/1') | Should -BeNullOrEmpty
    }
    It 'does not write anything' {
        (Get-Content -LiteralPath (Join-Path $script:Root 'knowledge' 'registry.json') -Raw) | Should -Match 'kn_001'
        (Get-ChildItem -LiteralPath (Join-Path $script:Root 'knowledge')).Name | Should -Not -Contain 'KNOWLEDGE.md'
    }
    It 'relativizes docs refs correctly when called with a relative -Root (the documented "-Root ." usage)' {
        Push-Location $script:Root
        try { $res = & $script:Engine -Root '.' }
        finally { Pop-Location }
        ($res.candidates | Where-Object ref -eq 'docs/cap.md').title | Should -Be 'Fabric Capacity'
    }
}
