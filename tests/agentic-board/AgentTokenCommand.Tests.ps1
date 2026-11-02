#Requires -Modules Pester
<#  agentTokenCommand (#808): a brake-armed run can take its agent identity from a local command
    that prints ONE short-lived token (a GitHub App installation token), instead of a PAT that
    expires. Every case uses a fake command in TestDrive that prints a fake token; nothing here
    talks to GitHub, and the developer's own ~/.agentic-board/accounts.json is never read.

    What is pinned:
      * the map: argv list or single string, a leading ~ is home, a malformed value is an error;
      * the command wins over agentTokenVar, and with no command nothing changes;
      * a failed / noisy / empty command is NO token - never a fallback to the owner's;
      * the launch script runs the command, puts its token in GH_TOKEN only, never in the text;
      * the launcher reads the agent identity from the map (no hardcoded variable name);
      * /board setup stores the command and never runs it.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' | Resolve-Path
    $script:SavedFile = $env:ABIOS_ACCOUNTS_FILE
    $env:ABIOS_ACCOUNTS_FILE = Join-Path $TestDrive 'no-accounts.json'
    $env:ABIOS_ADAPTERS_USER_FILE = Join-Path $TestDrive 'no-user-adapters.json'
    $env:ABIOS_ADAPTERS_REPO_FILE = Join-Path $TestDrive 'no-repo-adapters.json'
    . (Join-Path $script:ScriptDir 'Get-AbiosAccounts.ps1')

    $script:FakeToken = 'fake-agent-token-0123456789abcdef'
    # A fake mint: prints the fake token (or what -Out says) and exits with -Code. When -Touch is
    # given it also creates that file, so a test can prove the command did NOT run.
    $script:Mint = Join-Path $TestDrive 'mint.ps1'
    Set-Content -LiteralPath $script:Mint -Encoding UTF8 -Value @'
param([string]$Out = 'fake-agent-token-0123456789abcdef', [int]$Code = 0, [string]$Touch = '')
if ($Touch) { Set-Content -LiteralPath $Touch -Value 'ran' }
[Console]::Error.WriteLine('noise on stderr that must not become the token')
Write-Output $Out
exit $Code
'@
    function script:Write-Map([object]$Shape) {
        $p = Join-Path $TestDrive ("accounts-{0}.json" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $p -Value ($Shape | ConvertTo-Json -Depth 5) -Encoding UTF8
        return $p
    }
}
AfterAll { $env:ABIOS_ACCOUNTS_FILE = $script:SavedFile }

Describe 'agentTokenCommand in the account map (#808)' {
    It 'is empty by default, and agentTokenVar keeps its default' {
        $c = Get-AbiosAccountConfig -Path (Join-Path $TestDrive 'absent.json')
        @($c.agentTokenCommand).Count | Should -Be 0
        $c.agentTokenVar | Should -Be 'GITHUB_TOKEN_AGENT'
    }
    It 'reads an argv list, the bot git identity, and expands a leading ~' {
        $p = script:Write-Map @{ agentTokenCommand = @('pwsh', '-NoProfile', '-File', '~/scripts/mint.ps1')
                                 agentGitName = 'my-app[bot]'; agentGitEmail = '1+my-app[bot]@users.noreply.github.com' }
        $c = Get-AbiosAccountConfig -Path $p
        $c.error | Should -BeNullOrEmpty
        @($c.agentTokenCommand).Count | Should -Be 4
        $c.agentTokenCommand[3] | Should -Not -Match '^~'
        $c.agentTokenCommand[3] | Should -Match 'scripts[\\/]mint\.ps1$'
        $c.agentGitName | Should -Be 'my-app[bot]'
        $c.agentGitEmail | Should -Be '1+my-app[bot]@users.noreply.github.com'
    }
    It 'reads a single string as one executable with no arguments' {
        $c = Get-AbiosAccountConfig -Path (script:Write-Map @{ agentTokenCommand = $script:Mint })
        @($c.agentTokenCommand).Count | Should -Be 1
        $c.agentTokenCommand[0] | Should -Be $script:Mint
    }
    It 'a malformed command is an error, not a silent fallback to the PAT' {
        $c = Get-AbiosAccountConfig -Path (script:Write-Map @{ agentTokenCommand = @('pwsh', 42) })
        $c.error | Should -Match 'agentTokenCommand'
        @($c.agentTokenCommand).Count | Should -Be 0
    }
}

Describe 'Get-AbiosCommandToken / Get-AbiosAgentToken (#808)' {
    It 'returns the one token the command prints, without its stderr' {
        Get-AbiosCommandToken -Command @($script:Mint) | Should -BeExactly $script:FakeToken
    }
    It 'works through a child pwsh, the way a real map calls it' {
        Get-AbiosCommandToken -Command @('pwsh', '-NoProfile', '-File', $script:Mint) | Should -BeExactly $script:FakeToken
    }
    It 'a non-zero exit, a missing executable or an output that is not one token is no token' {
        Get-AbiosCommandToken -Command @($script:Mint, '-Code', '3') | Should -BeExactly ''
        Get-AbiosCommandToken -Command @((Join-Path $TestDrive 'missing.exe')) | Should -BeExactly ''
        Get-AbiosCommandToken -Command @($script:Mint, '-Out', 'Error: could not mint a token') | Should -BeExactly ''
        Get-AbiosCommandToken -Command @($script:Mint, '-Out', '') | Should -BeExactly ''
    }
    It 'the command wins over agentTokenVar; without one, the variable is read as before' {
        $env:ABIOS_T_AGENT_TOKEN = 'expired-pat-value-0123456789'
        try {
            $withCmd = [pscustomobject]@{ agentTokenVar = 'ABIOS_T_AGENT_TOKEN'; agentTokenCommand = @($script:Mint) }
            Get-AbiosAgentToken -Config $withCmd | Should -BeExactly $script:FakeToken
            Get-AbiosAgentIdentityLabel -Config $withCmd | Should -Be 'agentTokenCommand'
            $noCmd = [pscustomobject]@{ agentTokenVar = 'ABIOS_T_AGENT_TOKEN'; agentTokenCommand = @() }
            Get-AbiosAgentToken -Config $noCmd | Should -BeExactly 'expired-pat-value-0123456789'
            Get-AbiosAgentIdentityLabel -Config $noCmd | Should -Be 'ABIOS_T_AGENT_TOKEN'
        } finally { Remove-Item Env:ABIOS_T_AGENT_TOKEN -ErrorAction SilentlyContinue }
    }
}

Describe 'Brake-armed token resolution with agentTokenCommand (#808)' {
    BeforeAll {
        $env:ABIOS_TOKENVAR_DOTSOURCE = '1'
        . (Join-Path $script:ScriptDir 'Resolve-GhTokenVar.ps1')
        $env:ABIOS_TOKENVAR_DOTSOURCE = ''
        $script:Armed = Join-Path $TestDrive 'armed-wt'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Armed '.agentic-board') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Armed '.agentic-board' 'brake-armed.json') -Value '{}'
    }
    AfterAll { Import-AbiosAccountMaps -Config (Get-AbiosAccountConfig -Path (Join-Path $TestDrive 'absent.json')) }
    It 'an armed run gets the minted token, not the variable' {
        $env:ABIOS_T_AGENT_TOKEN = 'expired-pat-value-0123456789'
        try {
            Import-AbiosAccountMaps -Config (Get-AbiosAccountConfig -Path (script:Write-Map @{
                owners = @{ me = 'ABIOS_T_OWNER' }; agentTokenVar = 'ABIOS_T_AGENT_TOKEN'; agentTokenCommand = @($script:Mint) }))
            $r = Get-GhTokenForContext -StartDir $script:Armed -Owner 'me' -IdLookup { '' }
            $r.armed | Should -BeTrue
            $r.token | Should -BeExactly $script:FakeToken
        } finally { Remove-Item Env:ABIOS_T_AGENT_TOKEN -ErrorAction SilentlyContinue }
    }
    It 'a failing command stops the armed run instead of falling back to the owner' {
        $env:ABIOS_T_OWNER = 'owner-admin-token-0123456789'
        $env:GH_TOKEN_SAVED = $env:GH_TOKEN; $env:GH_TOKEN = 'ambient-owner-token-0123456789'
        try {
            Import-AbiosAccountMaps -Config (Get-AbiosAccountConfig -Path (script:Write-Map @{
                owners = @{ me = 'ABIOS_T_OWNER' }; agentTokenCommand = @($script:Mint, '-Code', '1') }))
            { Get-GhTokenForContext -StartDir $script:Armed -Owner 'me' -IdLookup { '' } } |
                Should -Throw -ExpectedMessage '*agentTokenCommand*'
        } finally {
            Remove-Item Env:ABIOS_T_OWNER -ErrorAction SilentlyContinue
            $env:GH_TOKEN = $env:GH_TOKEN_SAVED; Remove-Item Env:GH_TOKEN_SAVED -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Launch script with agentTokenCommand (#808)' {
    BeforeAll {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:ScriptDir 'Board-Work.ps1')
        $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    }
    It 'carries the command as literals and never a token value' {
        $s = Get-SecretScrubScript -Keep @('ANTHROPIC_API_KEY') -GhTokenVar 'GITHUB_TOKEN_AGENT' -GhTokenCommand @('pwsh', '-File', "C:\O'Brien\mint.ps1")
        $s | Should -Match "'pwsh' '-File' 'C:\\O''Brien\\mint\.ps1'"
        $s | Should -Not -Match 'GITHUB_TOKEN_AGENT'     # the command wins: the expired PAT never travels
        $s | Should -Not -Match ([regex]::Escape($script:FakeToken))
    }
    It 'with no command the scrub is unchanged' {
        (Get-SecretScrubScript -Keep @('K') -GhTokenVar 'GITHUB_TOKEN_AGENT') |
            Should -BeExactly (Get-SecretScrubScript -Keep @('K') -GhTokenVar 'GITHUB_TOKEN_AGENT' -GhTokenCommand @())
        (Get-SecretScrubScript -Keep @('K') -GhTokenVar 'GITHUB_TOKEN_AGENT') | Should -Not -Match 'abiosAgentTok|GIT_CONFIG|GIT_AUTHOR'
    }
    It 'really mints into GH_TOKEN only, sets the bot author and the gh credential helper (child pwsh)' {
        $script = (Get-SecretScrubScript -Keep @('ABIOS_T_MODEL_KEY') -GhTokenVar 'ABIOS_T_AGENT_TOKEN' -GhTokenCommand @('pwsh', '-NoProfile', '-File', $script:Mint) `
                     -GitName 'my-app[bot]' -GitEmail '1+my-app[bot]@users.noreply.github.com') + "`r`n" +
                  '[pscustomobject]@{ gh = $env:GH_TOKEN; pat = $env:ABIOS_T_AGENT_TOKEN; model = $env:ABIOS_T_MODEL_KEY; an = $env:GIT_AUTHOR_NAME; ce = $env:GIT_COMMITTER_EMAIL; helper = $env:GIT_CONFIG_VALUE_1; leftover = [bool](Get-Variable abiosAgentTok -ErrorAction SilentlyContinue) } | ConvertTo-Json -Compress'
        $f = Join-Path $TestDrive 'mint-launch.ps1'
        Set-Content -LiteralPath $f -Value $script -Encoding UTF8
        $saved = @{}
        $vars = @{ ABIOS_T_MODEL_KEY = 'model'; ABIOS_T_AGENT_TOKEN = 'expired-pat-value-0123456789'; GH_TOKEN = 'owner' }
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try { $r = (& pwsh -NoProfile -File $f) | ConvertFrom-Json }
        finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $r.gh       | Should -BeExactly $script:FakeToken   # the minted token, not the owner's GH_TOKEN
        $r.pat      | Should -BeNullOrEmpty                 # the PAT variable is scrubbed, not kept
        $r.model    | Should -Be 'model'
        $r.an       | Should -Be 'my-app[bot]'
        $r.ce       | Should -Be '1+my-app[bot]@users.noreply.github.com'
        $r.helper   | Should -Be '!gh auth git-credential'
        $r.leftover | Should -BeFalse
    }
    It 'no token stops the script before the CLI line, and the owner token is gone' {
        $script = (Get-SecretScrubScript -Keep @() -GhTokenCommand @('pwsh', '-NoProfile', '-File', $script:Mint, '-Code', '2')) + "`r`n" +
                  'Write-Output "CLI-STARTED gh=$env:GH_TOKEN"'
        $f = Join-Path $TestDrive 'mint-fail.ps1'
        Set-Content -LiteralPath $f -Value $script -Encoding UTF8
        $saved = $env:GH_TOKEN; $env:GH_TOKEN = 'owner'
        try { $out = (& pwsh -NoProfile -File $f *>&1 | Out-String) } finally { $env:GH_TOKEN = $saved }
        $out | Should -Match 'STOP: agentTokenCommand gave no token'
        $out | Should -Not -Match 'CLI-STARTED'
    }
    It 'rejects a multi-line git identity' {
        { Get-SecretScrubScript -GhTokenCommand @('x') -GitName "a`nb" } | Should -Throw
    }
    It 'a brake-armed preview takes the agent identity from the map, command first' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $work = Join-Path $TestDrive 'wt-808'; New-Item -ItemType Directory -Force -Path $work | Out-Null
        $saved = $env:ABIOS_ACCOUNTS_FILE
        try {
            $env:ABIOS_ACCOUNTS_FILE = script:Write-Map @{ agentTokenVar = 'MY_AGENT_PAT' }
            $p = Start-WorktreeSession -IssueNum 808 -Repo 'o/r' -Branch 'issue-808-x' -WorkPath $work -StopAtPR -Preview 6>$null
            $p.launchScript | Should -Match "'MY_AGENT_PAT'"           # the map's variable, not a hardcoded name
            $p.launchScript | Should -Not -Match 'GITHUB_TOKEN_AGENT'

            $env:ABIOS_ACCOUNTS_FILE = script:Write-Map @{ agentTokenVar = 'MY_AGENT_PAT'; agentTokenCommand = @($script:Mint); agentGitName = 'my-app[bot]' }
            $p = Start-WorktreeSession -IssueNum 808 -Repo 'o/r' -Branch 'issue-808-x' -WorkPath $work -StopAtPR -Preview 6>$null
            $p.launchScript | Should -Match 'abiosAgentTok'
            $p.launchScript | Should -Not -Match 'MY_AGENT_PAT'
            $p.launchScript | Should -Match "GIT_AUTHOR_NAME = 'my-app\[bot\]'"

            $p = Start-WorktreeSession -IssueNum 808 -Repo 'o/r' -Branch 'issue-808-x' -WorkPath $work -Preview 6>$null
            $p.launchScript | Should -Not -Match 'abiosAgentTok'        # an unarmed run is untouched
        } finally { $env:ABIOS_ACCOUNTS_FILE = $saved }
    }
}

Describe '/board setup with agentTokenCommand (#808)' {
    BeforeAll {
        $script:Setup = Join-Path $script:ScriptDir 'Set-AbiosAccounts.ps1'
        function script:Run-Setup([string[]]$ArgList) { & pwsh -NoProfile -File $script:Setup @ArgList 2>&1 | Out-String }
    }
    BeforeEach { $env:ABIOS_ACCOUNTS_FILE = Join-Path $TestDrive ("acc-{0}.json" -f [guid]::NewGuid().ToString('N')) }
    It 'stores the command and the bot identity, and -Show never runs the command' {
        $touch = Join-Path $TestDrive ("ran-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $null = script:Run-Setup @('-AgentTokenCommand', "$($script:Mint),-Touch,$touch", '-AgentGitName', 'my-app[bot]')
        $j = Get-Content -LiteralPath $env:ABIOS_ACCOUNTS_FILE -Raw | ConvertFrom-Json
        @($j.agentTokenCommand) | Should -Be @($script:Mint, '-Touch', $touch)
        $j.agentGitName | Should -Be 'my-app[bot]'
        $out = script:Run-Setup @('-Show')
        $out | Should -Match 'agentTokenCommand'
        Test-Path -LiteralPath $touch | Should -BeFalse
    }
    It '-ClearAgentTokenCommand goes back to agentTokenVar' {
        $null = script:Run-Setup @('-AgentTokenCommand', $script:Mint, '-AgentGitName', 'my-app[bot]')
        $null = script:Run-Setup @('-ClearAgentTokenCommand')
        $j = Get-Content -LiteralPath $env:ABIOS_ACCOUNTS_FILE -Raw | ConvertFrom-Json
        $j.PSObject.Properties.Name | Should -Not -Contain 'agentTokenCommand'
        $j.PSObject.Properties.Name | Should -Not -Contain 'agentGitName'
        $j.agentTokenVar | Should -Be 'GITHUB_TOKEN_AGENT'
    }
}
