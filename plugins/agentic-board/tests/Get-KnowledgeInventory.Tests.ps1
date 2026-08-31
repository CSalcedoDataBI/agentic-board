#Requires -Modules Pester
<#  Pester tests for Get-KnowledgeInventory.ps1. Builds a temp registry with a broken
    local path, a duplicate ref, an orphan domain and a missing note, then asserts the
    health contract. Also asserts the empty-registry seed path. #>
BeforeAll {
    $script:Engine = Join-Path $PSScriptRoot '..' 'scripts' 'Get-KnowledgeInventory.ps1' | Resolve-Path
    $script:Root   = Join-Path ([IO.Path]::GetTempPath()) ("kninv-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'knowledge') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $script:Root 'real.md') -Force | Out-Null
    $reg = [pscustomobject]@{
        version=1; project='fix'; domains=@('Fabric','DAX','Unused')
        references=@(
            [pscustomobject]@{ id='kn_001'; domain='Fabric'; type='md';  title='A'; ref='real.md';    note='ok';  added='2026-07-07' }
            [pscustomobject]@{ id='kn_002'; domain='Fabric'; type='md';  title='B'; ref='gone.md';    note='';    added='2026-07-07' }
            [pscustomobject]@{ id='kn_003'; domain='DAX';    type='url'; title='C'; ref='http://x/y'; note='ok';  added='2026-07-07' }
            [pscustomobject]@{ id='kn_004'; domain='DAX';    type='url'; title='D'; ref='http://x/y'; note='ok';  added='2026-07-07' }
        )
    }
    $reg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Root 'knowledge' 'registry.json') -Encoding utf8
    $script:Inv = & $script:Engine -Root $script:Root
}
AfterAll { if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force } }

Describe 'Get-KnowledgeInventory' {
    It 'reads all references' { $script:Inv.summary.total | Should -Be 4 }
    It 'flags the broken local path' { $script:Inv.health.brokenPaths | Should -Be 'kn_002' }
    It 'flags the duplicate ref' { $script:Inv.health.duplicates | Should -Be 'http://x/y' }
    It 'flags the orphan domain' { $script:Inv.health.orphanDomains | Should -Be 'Unused' }
    It 'flags the missing note' { $script:Inv.health.missingNotes | Should -Be 'kn_002' }
    It 'counts by domain' { $script:Inv.summary.byDomain.Fabric | Should -Be 2 }
    It 'seeds domains when the registry is absent' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("kninv-e-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        (& $script:Engine -Root $empty).domains | Should -Contain 'PowerBI'
        Remove-Item $empty -Recurse -Force
    }
}
