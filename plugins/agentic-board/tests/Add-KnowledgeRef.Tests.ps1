#Requires -Modules Pester
<#  Pester tests for Add-KnowledgeRef.ps1: inits a seeded registry, appends a record,
    regenerates the table, enforces the domain guard and the local-path-exists guard,
    infers type, and increments ids. #>
BeforeAll {
    $script:Engine = Join-Path $PSScriptRoot '..' 'scripts' 'Add-KnowledgeRef.ps1' | Resolve-Path
    function New-Root { Join-Path ([IO.Path]::GetTempPath()) ("knadd-" + [guid]::NewGuid().ToString('N')) }
}

Describe 'Add-KnowledgeRef' {
    It 'inits a seeded registry and appends the first record' {
        $root = New-Root; New-Item -ItemType Directory -Path $root -Force | Out-Null
        $rec = & $script:Engine -Root $root -Ref 'https://learn.microsoft.com/x' -Domain 'Fabric' -Title 'Cap' -Note 'n' -Date '2026-07-07'
        $rec.id | Should -Be 'kn_001'
        $rec.type | Should -Be 'url'
        (Test-Path (Join-Path $root 'knowledge' 'KNOWLEDGE.md')) | Should -BeTrue
        Remove-Item $root -Recurse -Force
    }
    It 'rejects an unknown domain without -NewDomain' {
        $root = New-Root; New-Item -ItemType Directory -Path $root -Force | Out-Null
        { & $script:Engine -Root $root -Ref 'https://x/y' -Domain 'Nope' } | Should -Throw
        Remove-Item $root -Recurse -Force
    }
    It 'accepts an unknown domain with -NewDomain' {
        $root = New-Root; New-Item -ItemType Directory -Path $root -Force | Out-Null
        $rec = & $script:Engine -Root $root -Ref 'https://x/y' -Domain 'Ontology' -NewDomain
        $rec.domain | Should -Be 'Ontology'
        Remove-Item $root -Recurse -Force
    }
    It 'rejects a non-existent local ref' {
        $root = New-Root; New-Item -ItemType Directory -Path $root -Force | Out-Null
        { & $script:Engine -Root $root -Ref 'docs/gone.md' -Domain 'DAX' } | Should -Throw
        Remove-Item $root -Recurse -Force
    }
    It 'increments ids and infers md for a local file' {
        $root = New-Root; New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'a.md') -Force | Out-Null
        & $script:Engine -Root $root -Ref 'https://x/1' -Domain 'DAX' | Out-Null
        $rec = & $script:Engine -Root $root -Ref 'a.md' -Domain 'DAX'
        $rec.id | Should -Be 'kn_002'
        $rec.type | Should -Be 'md'
        Remove-Item $root -Recurse -Force
    }
    It 'normalizes a Windows-separator local ref to repo-relative forward slashes' {
        $root = New-Root; New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root 'docs' 'cap.md') -Force | Out-Null
        $rec = & $script:Engine -Root $root -Ref 'docs\cap.md' -Domain 'DAX'
        $rec.ref | Should -Be 'docs/cap.md'
        Remove-Item $root -Recurse -Force
    }
}
