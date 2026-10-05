#Requires -Modules Pester
<#  /board setup - Set-AbiosAccounts.ps1 (#762). It stores env var NAMES only, merges into the
    existing map, and never writes outside the file it was pointed at.  #>

BeforeAll {
    $script:Script = Join-Path (Join-Path ((Resolve-Path (Join-Path $PSScriptRoot '../../plugins/agentic-board')).Path) 'scripts') 'Set-AbiosAccounts.ps1'
    $script:SavedFile = $env:ABIOS_ACCOUNTS_FILE
    function script:Run-Setup([string[]]$ArgList) {
        & pwsh -NoProfile -File $script:Script @ArgList 2>&1 | Out-String
    }
}
AfterAll { $env:ABIOS_ACCOUNTS_FILE = $script:SavedFile }

Describe 'Set-AbiosAccounts (#762)' {
    BeforeEach {
        $env:ABIOS_ACCOUNTS_FILE = Join-Path $TestDrive ("acc-{0}.json" -f [guid]::NewGuid().ToString('N'))
    }
    It 'writes the default owner, a map entry and an alias' {
        $null = script:Run-Setup @('-DefaultOwner', 'me', '-Map', 'me=TOK_ME', '-Alias', 'm=me')
        $j = Get-Content -LiteralPath $env:ABIOS_ACCOUNTS_FILE -Raw | ConvertFrom-Json
        $j.defaultOwner | Should -Be 'me'
        $j.owners.me | Should -Be 'TOK_ME'
        $j.aliases.m | Should -Be 'me'
        $j.agentTokenVar | Should -Be 'GITHUB_TOKEN_AGENT'
    }
    It 'merges: a second call keeps what the first wrote' {
        $null = script:Run-Setup @('-Map', 'me=TOK_ME')
        $null = script:Run-Setup @('-Map', 'org=TOK_ORG')
        $j = Get-Content -LiteralPath $env:ABIOS_ACCOUNTS_FILE -Raw | ConvertFrom-Json
        $j.owners.me | Should -Be 'TOK_ME'
        $j.owners.org | Should -Be 'TOK_ORG'
    }
    It '-Remove drops the owner, its aliases and the default that pointed at it' {
        $null = script:Run-Setup @('-DefaultOwner', 'org', '-Map', 'org=TOK_ORG', '-Alias', 'w=org')
        $null = script:Run-Setup @('-Remove', 'org')
        $j = Get-Content -LiteralPath $env:ABIOS_ACCOUNTS_FILE -Raw | ConvertFrom-Json
        $j.owners.PSObject.Properties.Name | Should -Not -Contain 'org'
        $j.aliases.PSObject.Properties.Name | Should -Not -Contain 'w'
        $j.PSObject.Properties.Name | Should -Not -Contain 'defaultOwner'
    }
    It 'refuses a value that looks like a token instead of a variable name' {
        $out = script:Run-Setup @('-Map', 'me=ghp_abc123-not-a-name!')
        $out | Should -Match 'Invalid map entry'
        Test-Path -LiteralPath $env:ABIOS_ACCOUNTS_FILE | Should -BeFalse
    }
    It '-DryRun writes nothing' {
        $out = script:Run-Setup @('-Map', 'me=TOK_ME', '-DryRun')
        $out | Should -Match 'DryRun'
        Test-Path -LiteralPath $env:ABIOS_ACCOUNTS_FILE | Should -BeFalse
    }
    It '-Show reports whether a variable is set, never its value' {
        $null = script:Run-Setup @('-Map', 'me=ABIOS_T_SHOWN')
        $env:ABIOS_T_SHOWN = 'secret-value-123'
        try { $out = script:Run-Setup @('-Show') } finally { Remove-Item Env:ABIOS_T_SHOWN -ErrorAction SilentlyContinue }
        $out | Should -Match 'ABIOS_T_SHOWN \[set\]'
        $out | Should -Not -Match 'secret-value-123'
    }
}
