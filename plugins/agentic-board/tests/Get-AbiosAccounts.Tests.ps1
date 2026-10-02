#Requires -Modules Pester
<#  The user's account map and the cross-platform token reader (#762, #767).

    Nothing account-specific ships in the plugin: the map is a per-user file, and with no file every
    owner resolves to the ambient token. These tests point ABIOS_ACCOUNTS_FILE at a TestDrive file,
    so the developer's own ~/.agentic-board/accounts.json never leaks into a verdict.  #>

BeforeAll {
    $script:ScriptDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
    $script:SavedFile = $env:ABIOS_ACCOUNTS_FILE
    . (Join-Path $script:ScriptDir 'Get-AbiosAccounts.ps1')
    function script:Write-Map([string]$Json) {
        $p = Join-Path $TestDrive ("accounts-{0}.json" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $p -Value $Json -Encoding UTF8
        return $p
    }
}
AfterAll { $env:ABIOS_ACCOUNTS_FILE = $script:SavedFile }

Describe 'Get-AbiosAccountConfig (#762)' {
    It 'a missing file is an empty map, not an error' {
        $c = Get-AbiosAccountConfig -Path (Join-Path $TestDrive 'nope.json')
        $c.exists | Should -BeFalse
        $c.error | Should -BeNullOrEmpty
        $c.owners.Count | Should -Be 0
        $c.agentTokenVar | Should -Be 'GITHUB_TOKEN_AGENT'
    }
    It 'reads owners, ids, aliases, default owner and agent variable' {
        $p = script:Write-Map '{"defaultOwner":"me","owners":{"me":"TOK_ME","org":"TOK_ORG"},"accountIds":{"42":"TOK_ME"},"aliases":{"w":"org"},"agentTokenVar":"TOK_BOT"}'
        $c = Get-AbiosAccountConfig -Path $p
        $c.defaultOwner | Should -Be 'me'
        $c.owners['org'] | Should -Be 'TOK_ORG'
        $c.accountIds['42'] | Should -Be 'TOK_ME'
        $c.aliases['w'] | Should -Be 'org'
        $c.agentTokenVar | Should -Be 'TOK_BOT'
    }
    It 'drops a value that is not a plain env var name (it would be interpolated into scripts)' {
        $p = script:Write-Map '{"owners":{"me":"TOK; rm -rf /","ok":"GOOD_VAR"},"agentTokenVar":"bad name"}'
        $c = Get-AbiosAccountConfig -Path $p
        $c.owners.ContainsKey('me') | Should -BeFalse
        $c.owners['ok'] | Should -Be 'GOOD_VAR'
        $c.agentTokenVar | Should -Be 'GITHUB_TOKEN_AGENT'
    }
    It 'a broken file reads as empty and says why' {
        $p = script:Write-Map '{ not json'
        $c = Get-AbiosAccountConfig -Path $p
        $c.exists | Should -BeTrue
        $c.error | Should -Match 'could not read'
        $c.owners.Count | Should -Be 0
    }
}

Describe 'Get-AbiosTokenValue (#762)' {
    BeforeEach {
        $script:SavedGh = $env:GH_TOKEN
        $env:ABIOS_T_SET = 'from-var'
        Remove-Item Env:ABIOS_T_UNSET -ErrorAction SilentlyContinue
    }
    AfterEach {
        $env:GH_TOKEN = $script:SavedGh
        Remove-Item Env:ABIOS_T_SET -ErrorAction SilentlyContinue
    }
    It 'reads a named variable from the process environment' {
        Get-AbiosTokenValue -VarName 'ABIOS_T_SET' | Should -Be 'from-var'
    }
    It 'without -AllowAmbient a missing variable stays empty (the agent identity fails closed)' {
        $env:GH_TOKEN = 'ambient'
        Mock Get-AbiosGhAuthToken { 'from-gh' }
        Get-AbiosTokenValue -VarName 'ABIOS_T_UNSET' | Should -BeNullOrEmpty
    }
    It 'with -AllowAmbient it falls back to GH_TOKEN, then to gh auth token' {
        $env:GH_TOKEN = 'ambient'
        Get-AbiosTokenValue -VarName 'ABIOS_T_UNSET' -AllowAmbient | Should -Be 'ambient'
        $env:GH_TOKEN = ''
        Mock Get-AbiosGhAuthToken { 'from-gh' }
        Get-AbiosTokenValue -VarName 'ABIOS_T_UNSET' -AllowAmbient | Should -Be 'from-gh'
    }
}

Describe 'Get-AbiosDefaultOwner (#762)' {
    It 'prefers the configured default and never calls gh for it' {
        Mock Get-Command { throw 'gh must not be consulted' } -ParameterFilter { $Name -eq 'gh' }
        Get-AbiosDefaultOwner -Config ([pscustomobject]@{ defaultOwner = 'me' }) | Should -Be 'me'
    }
}

Describe 'Nothing account-specific ships in the plugin (#762)' {
    It 'no script or skill hard-codes a default owner login' {
        $root = Split-Path -Parent $PSScriptRoot
        $hits = @(Get-ChildItem -Path (Join-Path $root 'scripts') -Filter *.ps1 |
            Select-String -Pattern '\[string\]\$Owner\s*=\s*[''"][A-Za-z0-9]' |
            ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
        $hits | Should -BeNullOrEmpty -Because 'the default owner comes from the account map or the gh login'
    }
}
