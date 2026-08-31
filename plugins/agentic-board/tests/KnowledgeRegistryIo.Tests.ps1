#Requires -Modules Pester
<#  Tests for KnowledgeRegistryIo.ps1 — the JSON-or-YAML knowledge registry (#298).

    KnowledgeRegistryIo.ps1 is pure at load (functions only), so it dot-sources directly. The point of
    these tests: the constrained YAML must ROUND-TRIP the registry losslessly — a repo on an allow-list
    hook (which blocks .json but passes .yaml) has to be able to read back exactly what was written,
    including URLs with ':' and notes with quotes/# that would break a naive line-based YAML. #>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'KnowledgeRegistryIo.ps1')
    $script:Reg = [pscustomobject]@{
        version = 1
        project = 'agentic-bi-ops'
        domains = @('Docs', 'Data', 'Reference')
        references = @(
            [pscustomobject]@{ id='kn_1'; domain='Docs'; type='url'; title='Fabric CI: dev -> prod'; ref='https://learn.microsoft.com/fabric?x=1#refresh'; note='has a colon: and a # hash and "quotes"'; added='2026-07-20' }
            [pscustomobject]@{ id='kn_2'; domain='Data'; type='file'; title='Model'; ref='docs/model.md'; note=''; added='2026-07-20' }
        )
    }
}

Describe 'ConvertTo/From-KnowledgeYaml round-trip' {
    It 'round-trips scalars, domains, and references losslessly' {
        $yaml = ConvertTo-KnowledgeYaml $script:Reg
        $back = ConvertFrom-KnowledgeYaml $yaml
        $back.version | Should -Be 1
        $back.project | Should -Be 'agentic-bi-ops'
        @($back.domains) | Should -Be @('Docs', 'Data', 'Reference')
        @($back.references).Count | Should -Be 2
    }
    It 'preserves a URL with a colon and a fragment (the naive-YAML killer)' {
        $back = ConvertFrom-KnowledgeYaml (ConvertTo-KnowledgeYaml $script:Reg)
        $back.references[0].ref | Should -Be 'https://learn.microsoft.com/fabric?x=1#refresh'
    }
    It 'preserves a note containing a colon, a hash, and quotes' {
        $back = ConvertFrom-KnowledgeYaml (ConvertTo-KnowledgeYaml $script:Reg)
        $back.references[0].note | Should -Be 'has a colon: and a # hash and "quotes"'
    }
    It 'preserves an empty note as empty string' {
        $back = ConvertFrom-KnowledgeYaml (ConvertTo-KnowledgeYaml $script:Reg)
        $back.references[1].note | Should -Be ''
    }
    It 'emits a .yaml body that carries no naked JSON braces (it is real YAML block style)' {
        $yaml = ConvertTo-KnowledgeYaml $script:Reg
        $yaml | Should -Match '(?m)^references:'
        $yaml | Should -Match '(?m)^  - id: "kn_1"'
        ($yaml -split "`n")[0] | Should -Match '^#'   # leading comment line (valid YAML)
    }
    It 'handles an empty registry (no references yet)' {
        $empty = [pscustomobject]@{ version=1; project='x'; domains=@('Docs'); references=@() }
        $back = ConvertFrom-KnowledgeYaml (ConvertTo-KnowledgeYaml $empty)
        @($back.references).Count | Should -Be 0
        @($back.domains) | Should -Be @('Docs')
    }
}

Describe 'Resolve-KnowledgeRegistryPath (autodetect + -Format)' {
    It 'defaults a brand-new registry to .json (no behavior change)' {
        $p = Resolve-KnowledgeRegistryPath -Root $TestDrive
        $p | Should -Match 'registry\.json$'
    }
    It '-Format yaml selects the allow-list-friendly path' {
        (Resolve-KnowledgeRegistryPath -Root $TestDrive -Format yaml) | Should -Match 'registry\.yaml$'
    }
    It 'prefers an EXISTING registry.yaml over a new .json' {
        $dir = Join-Path $TestDrive 'knowledge'; New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'registry.yaml') -Value "version: 1`nproject: `"x`"`ndomains:`nreferences:`n"
        (Resolve-KnowledgeRegistryPath -Root $TestDrive) | Should -Match 'registry\.yaml$'
    }
}

Describe 'Read/Write-KnowledgeRegistry (dispatch by extension)' {
    It 'writes and reads a .yaml registry through the file' {
        $dir = Join-Path $TestDrive 'kw'; New-Item -ItemType Directory -Force $dir | Out-Null
        $path = Join-Path $dir 'registry.yaml'
        Write-KnowledgeRegistry -Registry $script:Reg -Path $path
        (Get-Content -LiteralPath $path -Raw) | Should -Match '(?m)^references:'
        $back = Read-KnowledgeRegistry -Path $path
        $back.references[0].ref | Should -Be 'https://learn.microsoft.com/fabric?x=1#refresh'
    }
    It 'writes and reads a .json registry unchanged (backward compatible)' {
        $dir = Join-Path $TestDrive 'kj'; New-Item -ItemType Directory -Force $dir | Out-Null
        $path = Join-Path $dir 'registry.json'
        Write-KnowledgeRegistry -Registry $script:Reg -Path $path
        (Get-Content -LiteralPath $path -Raw) | Should -Match '"references"'
        (Read-KnowledgeRegistry -Path $path).references[1].id | Should -Be 'kn_2'
    }
}
