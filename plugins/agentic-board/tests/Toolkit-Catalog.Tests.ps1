#Requires -Modules Pester
<#  Pester tests for the toolkit catalogs (presets/toolkits/*.json) — schema + content. #>

BeforeAll {
    $script:ToolkitsDir = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' | Resolve-Path
    $script:QualityPath = Join-Path $script:ToolkitsDir 'quality.json'
    $script:BiPath      = Join-Path $script:ToolkitsDir 'bi.json'
    $script:McpPath     = Join-Path $script:ToolkitsDir 'mcp.json'

    $script:RequiredKeys = @('name','owner','repo','kind','path','license','homepage','profiles','install','purpose')

    function Get-Catalog([string]$Path) {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
}

Describe 'Toolkit catalogs' {
    It 'all catalog files exist (quality, bi, mcp)' {
        Test-Path $script:QualityPath | Should -BeTrue
        Test-Path $script:BiPath      | Should -BeTrue
        Test-Path $script:McpPath     | Should -BeTrue
    }

    It 'all parse as valid JSON arrays' {
        { Get-Catalog $script:QualityPath } | Should -Not -Throw
        { Get-Catalog $script:BiPath }      | Should -Not -Throw
        { Get-Catalog $script:McpPath }     | Should -Not -Throw
        @(Get-Catalog $script:QualityPath).Count | Should -BeGreaterThan 0
        @(Get-Catalog $script:BiPath).Count      | Should -BeGreaterThan 0
        @(Get-Catalog $script:McpPath).Count     | Should -BeGreaterThan 0
    }
}

Describe 'Entry schema' -ForEach @(
    @{ File = 'quality.json' }
    @{ File = 'bi.json' }
    @{ File = 'mcp.json' }
) {
    BeforeEach {
        $path = Join-Path $script:ToolkitsDir $File
        $script:entries = @(Get-Catalog $path)
    }

    It "<File>: every entry carries all required keys" {
        foreach ($e in $script:entries) {
            $names = $e.PSObject.Properties.Name
            foreach ($k in $script:RequiredKeys) {
                $names | Should -Contain $k -Because "entry '$($e.name)' in $File must define '$k'"
            }
        }
    }

    It "<File>: name/owner/repo/license/homepage/purpose are non-empty strings" {
        foreach ($e in $script:entries) {
            foreach ($k in 'name','owner','repo','license','homepage','purpose') {
                [string]::IsNullOrWhiteSpace([string]$e.$k) | Should -BeFalse -Because "$File/$($e.name).$k"
            }
        }
    }

    It "<File>: repo is 'owner/name'" {
        foreach ($e in $script:entries) { $e.repo | Should -Match '^[^/]+/[^/]+$' }
    }

    It "<File>: profiles is a non-empty array" {
        foreach ($e in $script:entries) { @($e.profiles).Count | Should -BeGreaterThan 0 }
    }

    It "<File>: kind is skill-clone, plugin, or mcp, with matching path/install" {
        foreach ($e in $script:entries) {
            $e.kind | Should -BeIn @('skill-clone','plugin','mcp')
            if ($e.kind -in 'plugin','mcp') {
                [string]::IsNullOrWhiteSpace([string]$e.install) | Should -BeFalse -Because "$($e.name) is $($e.kind) — needs an install command"
                $e.path | Should -BeNullOrEmpty -Because "$($e.name) is $($e.kind) — path must be null"
                [string]::IsNullOrWhiteSpace([string]$e.detect) | Should -BeFalse -Because "$($e.name) is $($e.kind) — needs a detect id for gap detection"
            } else {
                [string]::IsNullOrWhiteSpace([string]$e.path) | Should -BeFalse -Because "$($e.name) is skill-clone — needs a path"
            }
        }
    }
}

Describe 'bi.json content' {
    BeforeEach { $script:bi = @(Get-Catalog $script:BiPath) }

    It 'includes microsoft/skills-for-fabric as an MIT plugin' {
        $ms = $script:bi | Where-Object { $_.repo -eq 'microsoft/skills-for-fabric' }
        $ms | Should -Not -BeNullOrEmpty
        $ms.kind    | Should -Be 'plugin'
        $ms.license | Should -Be 'MIT'
        $ms.owner   | Should -Be 'Microsoft'
    }

    It 'the Fabric entry covers the three BI profiles' {
        $ms = $script:bi | Where-Object { $_.repo -eq 'microsoft/skills-for-fabric' }
        foreach ($p in 'semantic-model-review','fabric-app','data-agent') {
            $ms.profiles | Should -Contain $p
        }
    }
}

Describe 'quality.json content' {
    It 'carries the four best-practice skills' {
        $names = @(Get-Catalog $script:QualityPath).name | Sort-Object
        $names | Should -Be (@('second-opinion','skill-creator','skill-improver','writing-skills'))
    }

    It 'every quality entry is skill-clone tagged with the quality profile' {
        foreach ($e in @(Get-Catalog $script:QualityPath)) {
            $e.kind     | Should -Be 'skill-clone'
            $e.profiles | Should -Contain 'quality'
        }
    }
}

Describe 'mcp.json content (#416)' {
    BeforeEach { $script:mcp = @(Get-Catalog $script:McpPath) }

    It 'includes deepwiki-mcp entry from Cognition' {
        $dw = $script:mcp | Where-Object { $_.name -eq 'deepwiki-mcp' }
        $dw              | Should -Not -BeNullOrEmpty
        $dw.kind         | Should -Be 'mcp'
        $dw.owner        | Should -Be 'Cognition'
        $dw.detect       | Should -Be 'deepwiki'
        $dw.install      | Should -Match 'claude mcp add'
        $dw.install      | Should -Match 'deepwiki'
    }

    It 'every mcp entry carries documentation profile' {
        foreach ($e in $script:mcp) {
            @($e.profiles) | Should -Contain 'documentation'
        }
    }

    It 'deepwiki-mcp install command references the SSE endpoint' {
        $dw = $script:mcp | Where-Object { $_.name -eq 'deepwiki-mcp' }
        $dw.install | Should -Match 'sse'
        $dw.install | Should -Match 'deepwiki\.com'
    }
}

Describe 'legacy catalog removed' {
    It 'presets/recommended-skills.json no longer exists (migrated to toolkits/)' {
        $legacy = Join-Path $PSScriptRoot '..' 'presets' 'recommended-skills.json'
        Test-Path $legacy | Should -BeFalse
    }
}
