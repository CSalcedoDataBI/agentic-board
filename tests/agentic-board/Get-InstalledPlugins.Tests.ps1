#Requires -Modules Pester
<#  Pester tests for Get-InstalledPlugins.ps1 — parsing `claude plugin list` output into
    match keys (plugin + marketplace), best-effort. #>

BeforeAll {
    $script:Plugins = Join-Path $PSScriptRoot '..' 'scripts' 'Get-InstalledPlugins.ps1' | Resolve-Path
    $script:Sample = @'
Installed plugins:

  > agentic-board@agentic-board
    Version: 0.20.0
    Scope: user
    Status: enabled

  > fabric-skills@fabric-collection
    Version: 0.3.3
    Scope: user
    Status: enabled
'@
}

Describe 'Get-InstalledPlugins' {
    It 'emits both the plugin name and its marketplace, lowercased' {
        $ids = & $script:Plugins -Raw $script:Sample
        $ids | Should -Contain 'fabric-skills'
        $ids | Should -Contain 'fabric-collection'
        $ids | Should -Contain 'agentic-board'
    }
    It 'returns an empty array on empty/missing output (never throws)' {
        { & $script:Plugins -Raw '' } | Should -Not -Throw
        @(& $script:Plugins -Raw '').Count | Should -Be 0
    }
    It 'de-duplicates repeated identifiers' {
        $ids = & $script:Plugins -Raw "a@shared`nb@shared"
        @($ids | Where-Object { $_ -eq 'shared' }).Count | Should -Be 1
    }
}
