#Requires -Modules Pester
<#  The declarative CLI adapter registry (#772).

    Before #772 adding a backend meant editing Get-CliAdapters plus the routing table in
    Fleet-Plan.ps1 and the reviewer list in Get-ReviewerRoster.ps1. The adapter DATA now lives in
    presets/adapters.json, overridable per user (~/.agentic-board/adapters.json) and per project
    (.agentic-board/adapters.json) like roles.json. These tests pin:
      * the shipped registry yields the same adapters as the old literals;
      * the merge rule: per field, later tier wins (preset -> user -> repo), a new name adds;
      * an adapter added by an override JSON entry reaches Get-CliAdapters, Fleet-Plan routing and
        the reviewer roster with no code change;
      * an override cannot inject an unpinned install (#765), an unknown probe code (#770) or a
        launch string that breaks out of the generated script;
      * malformed override files are ignored with a warning; a broken preset throws.
    No CLI runs and nothing touches the network; every override lives in $TestDrive.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Preset    = Join-Path $PSScriptRoot '..' 'presets' 'adapters.json' | Resolve-Path
    # Hermetic: the default tiers point at files that do not exist.
    $env:ABIOS_ADAPTERS_USER_FILE = Join-Path $TestDrive 'no-user-adapters.json'
    $env:ABIOS_ADAPTERS_REPO_FILE = Join-Path $TestDrive 'no-repo-adapters.json'
    $env:ABIOS_FLEETPLAN_DOTSOURCE = '1'
    . (Join-Path $script:ScriptDir 'Fleet-Plan.ps1')
    $env:ABIOS_FLEETPLAN_DOTSOURCE = ''
    . (Join-Path $script:ScriptDir 'Get-ReviewerRoster.ps1')

    $script:N = 0
    # Write an override document to a fresh $TestDrive file; returns its path.
    function script:New-Override {
        param([object[]]$Adapters, [int]$Version = 1, [hashtable]$Extra = @{})
        $script:N++
        $p = Join-Path $TestDrive "override-$($script:N).json"
        $doc = @{ version = $Version; adapters = @($Adapters) } + $Extra
        Set-Content -LiteralPath $p -Value ($doc | ConvertTo-Json -Depth 10) -Encoding utf8
        $p
    }
    function script:New-RawFile([string]$Text) {
        $script:N++
        $p = Join-Path $TestDrive "raw-$($script:N).json"
        Set-Content -LiteralPath $p -Value $Text -Encoding utf8
        $p
    }
    $script:None = Join-Path $TestDrive 'absent.json'
    # A complete, valid new backend as an override would declare it.
    function script:New-AcmeAdapter {
        @{
            name        = 'acme'
            command     = 'acme'
            kind        = 'repl'
            installArgs = @('npm', 'i', '-g', '@acme/cli@2.3.4')
            probeArgs   = @('acme', 'whoami')
            probeRules  = @(
                @{ code = 'AUTH'; pattern = '(?i)please log in'; reason = 'not logged in' }
                @{ include = 'common' }
                @{ code = 'OK'; pattern = '(?im)^signed in as'; reason = 'signed in' }
            )
            bypassArgs  = '--yes-to-all'
            keepEnv     = @('ACME_API_KEY')
            launch      = @{ args = @('run', '--prompt', '{briefingContent}') }
            routing     = @{ docs = 50 }
            reviewer    = $true
        }
    }
}
AfterAll {
    $env:ABIOS_ADAPTERS_USER_FILE = $null
    $env:ABIOS_ADAPTERS_REPO_FILE = $null
}

Describe 'The shipped registry yields the same adapters as before #772' {
    BeforeAll { $script:A = @(Get-CliAdapters -UserPath $script:None -RepoPath $script:None) }
    It 'loads the five adapters, in order, all from the preset' {
        $script:A.Name | Should -Be @('claude', 'antigravity', 'jules', 'codex', 'copilot')
        @($script:A | Where-Object Source -ne 'preset').Count | Should -Be 0
    }
    It 'keeps claude the one default, with no probe to run and its launch in code' {
        @($script:A | Where-Object IsDefault).Name | Should -Be @('claude')
        ($script:A | Where-Object Name -eq 'claude').ProbeArgs | Should -BeNullOrEmpty
        $s = & ($script:A | Where-Object Name -eq 'claude').BuildLaunch @{ BriefingFile = 'C:\b.txt'; AuthVar = 'ANTHROPIC_API_KEY'; AllowBypass = $true }
        $s | Should -Match 'claude -p \(Get-Content -Raw -LiteralPath ''C:\\b\.txt''\) --permission-mode bypassPermissions --no-session-persistence --verbose$'
    }
    It 'keeps the same commands, kinds, pinned installs and install page' {
        $by = @{}; foreach ($a in $script:A) { $by[$a.Name] = $a }
        $by.antigravity.Command | Should -Be 'agy'
        $by.jules.Kind          | Should -Be 'async'
        @($by.jules.InstallArgs)   | Should -Be @('npm', 'i', '-g', '@google/jules@0.1.42')
        @($by.codex.InstallArgs)   | Should -Be @('npm', 'i', '-g', '@openai/codex@0.160.0')
        @($by.copilot.InstallArgs) | Should -Be @('npm', 'i', '-g', '@github/copilot@1.0.91')
        $by.antigravity.InstallArgs | Should -BeNullOrEmpty
        $by.antigravity.InstallUrl  | Should -Be 'https://antigravity.google/docs/cli/install'
        $by.claude.InstallArgs      | Should -BeNullOrEmpty
    }
    It 'keeps each adapter''s probe argv, bypass, keep-env list and RequiresBypass' {
        $by = @{}; foreach ($a in $script:A) { $by[$a.Name] = $a }
        @($by.antigravity.ProbeArgs) | Should -Be @('agy', '-p', 'reply OK')
        @($by.jules.ProbeArgs)       | Should -Be @('jules', 'remote', 'list', '--session')
        @($by.codex.ProbeArgs)       | Should -Be @('codex', 'login', 'status')
        @($by.copilot.ProbeArgs)     | Should -Be @('copilot', '-p', 'reply OK')
        $by.codex.BypassArgs   | Should -Be '--dangerously-bypass-approvals-and-sandbox'
        @($by.codex.KeepEnv)   | Should -Be @('OPENAI_API_KEY')
        @($by.copilot.KeepEnv) | Should -Be @('COPILOT_GITHUB_TOKEN')
        @($script:A | Where-Object RequiresBypass).Name | Should -Be @('antigravity')
    }
    It 'expands the shared rules in each adapter''s own order (same rule sequence as the old literals)' {
        $seq = @{}; foreach ($a in $script:A) { $seq[$a.Name] = ($a.ProbeRules.Code) -join ',' }
        $common = 'CONTEXT_WINDOW,QUOTA,RATE_LIMIT,AUTH'
        $seq.claude      | Should -Be "QUOTA,RATE_LIMIT,AUTH,CONTEXT_WINDOW,$common,OK"
        $seq.antigravity | Should -Be "AUTH,ERROR,$common,OK"
        $seq.jules       | Should -Be "AUTH,OK,$common"
        $seq.codex       | Should -Be "AUTH,$common,OK"
        $seq.copilot     | Should -Be "QUOTA,AUTH,$common,OK"
    }
    It 'renders the template launches exactly as the old scriptblocks did' {
        $ctx = @{ BriefingFile = "C:\Users\O'Brien\b.txt"; AllowBypass = $true }
        $by = @{}; foreach ($a in $script:A) { $by[$a.Name] = & $a.BuildLaunch $ctx }
        $by.antigravity | Should -BeExactly "agy -p 'Read the file C:\Users\O''Brien\b.txt and follow its instructions to the letter.' --dangerously-skip-permissions"
        $by.jules       | Should -BeExactly "jules new (Get-Content -Raw -LiteralPath 'C:\Users\O''Brien\b.txt')"
        $by.codex       | Should -BeExactly "`$null | codex exec (Get-Content -Raw -LiteralPath 'C:\Users\O''Brien\b.txt') --dangerously-bypass-approvals-and-sandbox"
        $by.copilot     | Should -BeExactly "copilot -p (Get-Content -Raw -LiteralPath 'C:\Users\O''Brien\b.txt') --allow-all"
    }
    It 'derives the shipped routing and reviewer flags' {
        Get-CliRoutePreference -Route 'docs'     -Adapters $script:A | Should -Be @('antigravity', 'copilot', 'claude')
        Get-CliRoutePreference -Route 'chore'    -Adapters $script:A | Should -Be @('copilot', 'antigravity', 'claude')
        Get-CliRoutePreference -Route 'refactor' -Adapters $script:A | Should -Be @('codex', 'claude')
        Get-CliRoutePreference -Route 'heavy'    -Adapters $script:A | Should -Be @('claude')
        @($script:A | Where-Object Reviewer).Name | Should -Be @('antigravity', 'codex')
    }
}

Describe 'Override tiers: preset -> user -> repo, per field (#772)' {
    It 'a user override replaces only the fields it states' {
        $u = New-Override @(@{ name = 'codex'; keepEnv = @('OPENAI_API_KEY', 'CODEX_HOME') })
        $codex = Get-CliAdapters -UserPath $u -RepoPath $script:None | Where-Object Name -eq 'codex'
        @($codex.KeepEnv) | Should -Be @('OPENAI_API_KEY', 'CODEX_HOME')
        $codex.BypassArgs | Should -Be '--dangerously-bypass-approvals-and-sandbox'   # inherited
        @($codex.ProbeArgs) | Should -Be @('codex', 'login', 'status')                # inherited
        $codex.Source | Should -Be 'user'
    }
    It 'the repo tier wins over the user tier on the same field; other user fields survive' {
        $u = New-Override @(@{ name = 'codex'; keepEnv = @('USER_VAR'); routing = @{ refactor = 100; docs = 10 } })
        $r = New-Override @(@{ name = 'codex'; keepEnv = @('REPO_VAR') })
        $codex = Get-CliAdapters -UserPath $u -RepoPath $r | Where-Object Name -eq 'codex'
        @($codex.KeepEnv) | Should -Be @('REPO_VAR')
        $codex.Routing['docs'] | Should -Be 10
        $codex.Source | Should -Be 'repo'
    }
    It 'with no override files the result is the preset alone' {
        (Get-CliAdapters -UserPath $script:None -RepoPath $script:None).Count | Should -Be 5
    }
    It 'reads the default tiers from ABIOS_ADAPTERS_USER_FILE / ABIOS_ADAPTERS_REPO_FILE' {
        $old = $env:ABIOS_ADAPTERS_USER_FILE
        try {
            $env:ABIOS_ADAPTERS_USER_FILE = New-Override @(@{ name = 'copilot'; keepEnv = @('FROM_ENV') })
            @((Get-CliAdapters | Where-Object Name -eq 'copilot').KeepEnv) | Should -Be @('FROM_ENV')
        } finally { $env:ABIOS_ADAPTERS_USER_FILE = $old }
    }
}

Describe 'A backend added by an override JSON entry, with no code change (#772)' {
    BeforeAll {
        $script:OldUser = $env:ABIOS_ADAPTERS_USER_FILE
        $env:ABIOS_ADAPTERS_USER_FILE = New-Override @(New-AcmeAdapter)
    }
    AfterAll { $env:ABIOS_ADAPTERS_USER_FILE = $script:OldUser }

    It 'shows up in Get-CliAdapters, after the shipped ones, with its own probe and rules' {
        $all = @(Get-CliAdapters)
        $all.Name | Should -Be @('claude', 'antigravity', 'jules', 'codex', 'copilot', 'acme')
        $acme = $all | Where-Object Name -eq 'acme'
        $acme.Source | Should -Be 'user'
        $acme.IsDefault | Should -BeFalse
        $acme.Probe.ToString() | Should -Match "Invoke-CliProbe @\('acme', 'whoami'\) -Cli 'acme'"
        ConvertTo-CliProbeCode -Cli 'acme' -ExitCode 0 -Output 'Signed in as someone' | Should -Be 'OK'
        ConvertTo-CliProbeCode -Cli 'acme' -ExitCode 0 -Output 'please log in' | Should -Be 'AUTH'
        ConvertTo-CliProbeCode -Cli 'acme' -ExitCode 1 -Output 'quota exceeded' | Should -Be 'QUOTA'
        Get-CliInstallText $acme | Should -Be 'npm i -g @acme/cli@2.3.4'
    }
    It 'launches from its template, the bypass only on opt-in' {
        $acme = Get-CliAdapters | Where-Object Name -eq 'acme'
        & $acme.BuildLaunch @{ BriefingFile = 'C:\b\brief.txt' } |
            Should -BeExactly "acme run --prompt (Get-Content -Raw -LiteralPath 'C:\b\brief.txt')"
        & $acme.BuildLaunch @{ BriefingFile = 'C:\b\brief.txt'; AllowBypass = $true } | Should -Match ' --yes-to-all$'
    }
    It 'is routed by Fleet-Plan for the route it ranks' {
        $docs = [pscustomobject]@{ number = 1; labels = @(); size = 'M'; type = 'Docs' }
        Select-CliForIssue $docs @('claude', 'antigravity', 'acme') | Should -Be 'acme'
        # ... and only when it is available.
        Select-CliForIssue $docs @('claude', 'antigravity') | Should -Be 'antigravity'
        # A route it does not rank is untouched.
        $feat = [pscustomobject]@{ number = 2; labels = @(); size = 'M'; type = 'Feature' }
        Select-CliForIssue $feat @('claude', 'acme') | Should -Be 'claude'
    }
    It 'joins the reviewer roster with its probe argv' {
        $r = @(Get-ReviewerRoster) | Where-Object Name -eq 'acme'
        $r.Command | Should -Be 'acme'
        @($r.ProbeArgs) | Should -Be @('whoami')
    }
}

Describe 'An override cannot weaken the rules on load (#765, #770, #772)' {
    BeforeAll {
        function script:Load([object[]]$Adapters) {
            $p = New-Override $Adapters
            $w = $null
            $all = @(Get-CliAdapters -UserPath $p -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue)
            [pscustomobject]@{ All = $all; Warnings = @($w | ForEach-Object { "$_" }) }
        }
    }
    It 'rejects an unpinned install and keeps the pinned one: <label>' -TestCases @(
        @{ label = 'no version';      argv = @('npm', 'i', '-g', '@openai/codex') }
        @{ label = '@latest';         argv = @('npm', 'i', '-g', '@openai/codex@latest') }
        @{ label = 'a range';         argv = @('npm', 'i', '-g', '@openai/codex@^0.160.0') }
        @{ label = 'another program'; argv = @('curl', '-o', 'x', 'evil@1.0.0') }
        @{ label = 'extra flags';     argv = @('npm', 'i', '-g', '--registry', 'https://evil.example', '@openai/codex@0.160.0') }
    ) {
        param($label, $argv)
        $r = Load @(@{ name = 'codex'; installArgs = $argv })
        @(($r.All | Where-Object Name -eq 'codex').InstallArgs) | Should -Be @('npm', 'i', '-g', '@openai/codex@0.160.0')
        ($r.Warnings -join "`n") | Should -Match "adapter 'codex' rejected .*installArgs.*#765"
        ($r.Warnings -join "`n") | Should -Match 'keeping the preset definition'
    }
    It 'rejects an install page that is not https' {
        $r = Load @(@{ name = 'antigravity'; installUrl = 'http://example.invalid/install' })
        ($r.All | Where-Object Name -eq 'antigravity').InstallUrl | Should -Be 'https://antigravity.google/docs/cli/install'
        ($r.Warnings -join "`n") | Should -Match 'installUrl must be an https'
    }
    It 'rejects a probe rule whose code is outside the closed set: <code>' -TestCases @(
        @{ code = 'FAIL' }, @{ code = 'ok' }, @{ code = 'NOT_INSTALLED' }
    ) {
        param($code)
        $rules = @(@{ code = $code; pattern = 'x'; reason = 'r' }, @{ code = 'OK'; pattern = 'OK'; reason = 'r' })
        $r = Load @(@{ name = 'copilot'; probeRules = $rules })
        (($r.All | Where-Object Name -eq 'copilot').ProbeRules.Code) -join ',' | Should -Be 'QUOTA,AUTH,CONTEXT_WINDOW,QUOTA,RATE_LIMIT,AUTH,OK'
        ($r.Warnings -join "`n") | Should -Match "unknown probe code '$code'"
    }
    It 'does not ADD a new adapter that fails validation' {
        $bad = New-AcmeAdapter; $bad.probeRules = @(@{ code = 'MAYBE'; pattern = 'x'; reason = 'r' })
        $r = Load @($bad)
        $r.All.Name | Should -Not -Contain 'acme'
        ($r.Warnings -join "`n") | Should -Match "adapter 'acme' rejected .*it is not added"
    }
    It 'rejects <label>' -TestCases @(
        @{ label = 'a command with a metacharacter'; patch = @{ command = 'codex;rm' };                 msg = 'bare executable name' }
        @{ label = 'a bypass flag with a metacharacter'; patch = @{ bypassArgs = '--yolo; Remove-Item x' }; msg = 'bypassArgs' }
        @{ label = 'a probe that carries the bypass'; patch = @{ probeArgs = @('codex', '--dangerously-bypass-approvals-and-sandbox') }; msg = '#761' }
        @{ label = 'a probe for another executable'; patch = @{ probeArgs = @('pwsh', '-c', 'x') };    msg = 'must start with the command' }
        @{ label = 'a second default'; patch = @{ isDefault = $true };                                  msg = 'isDefault' }
        @{ label = 'an unknown route'; patch = @{ routing = @{ nowhere = 1 } };                         msg = 'unknown route' }
        @{ label = 'an invalid regex'; patch = @{ probeRules = @(@{ code = 'OK'; pattern = '(unclosed'; reason = 'r' }) }; msg = 'not a valid regex' }
        @{ label = 'no OK rule'; patch = @{ probeRules = @(@{ code = 'AUTH'; pattern = 'x'; reason = 'r' }) }; msg = 'exactly one OK rule' }
        @{ label = 'a bad keepEnv name'; patch = @{ keepEnv = @('A B') };                               msg = 'keepEnv' }
        @{ label = 'an unknown launch key'; patch = @{ launch = @{ args = @('x'); shell = 'cmd' } };    msg = "unknown key 'shell'" }
    ) {
        param($label, $patch, $msg)
        $r = Load @(@{ name = 'codex' } + $patch)
        $codex = $r.All | Where-Object Name -eq 'codex'
        $codex.Source | Should -Be 'preset' -Because $label
        ($r.Warnings -join "`n") | Should -Match ([regex]::Escape($msg))
    }
    It 'a template argument is quoted, never spliced in as code' {
        $evil = New-AcmeAdapter; $evil.launch = @{ args = @("x'; Remove-Item C:\ -Recurse; '", '$(whoami)', '{briefingFile}') }
        $r = Load @($evil)
        $line = & ($r.All | Where-Object Name -eq 'acme').BuildLaunch @{ BriefingFile = "C:\O'Brien`u{2019}s\b.txt" }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $ast.EndBlock.Statements.Count | Should -Be 1
        $cmd = $ast.EndBlock.Statements[0].PipelineElements[0]
        $cmd.GetCommandName() | Should -Be 'acme'
        # Every argument is a plain string constant - no subexpression, no second command.
        @($cmd.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] }).Count | Should -Be 0
        $cmd.CommandElements[1].Value | Should -Be "x'; Remove-Item C:\ -Recurse; '"
        $cmd.CommandElements[2].Value | Should -Be '$(whoami)'
        $cmd.CommandElements[3].Value | Should -Be "C:\O'Brien`u{2019}s\b.txt"
    }
}

Describe 'Malformed files (#772)' {
    It 'ignores an override that is not valid JSON, with a warning, and keeps the preset' {
        $p = New-RawFile '{ "version": 1, "adapters": [ { "name": "codex", '
        $w = $null
        $all = @(Get-CliAdapters -UserPath $p -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue)
        $all.Count | Should -Be 5
        (@($w) -join "`n") | Should -Match 'could not parse'
    }
    It 'ignores an override whose top level is not an object' {
        $p = New-RawFile '[ { "name": "codex" } ]'
        $w = $null
        @(Get-CliAdapters -UserPath $script:None -RepoPath $p -WarningVariable w -WarningAction SilentlyContinue).Count | Should -Be 5
        (@($w) -join "`n") | Should -Match 'could not parse'
    }
    It 'ignores an override written for another schema version' {
        $p = New-Override @(@{ name = 'codex'; keepEnv = @('X') }) -Version 2
        $w = $null
        $codex = Get-CliAdapters -UserPath $p -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue | Where-Object Name -eq 'codex'
        @($codex.KeepEnv) | Should -Be @('OPENAI_API_KEY')
        (@($w) -join "`n") | Should -Match "declares version '2'"
    }
    It 'skips an entry with no name and warns about unknown fields and preset-only keys' {
        $p = New-Override @(@{ command = 'x' }, @{ name = 'codex'; colour = 'blue' }) -Extra @{ routes = @() }
        $w = $null
        $null = Get-CliAdapters -UserPath $p -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue
        $text = @($w) -join "`n"
        $text | Should -Match "without a 'name'"
        $text | Should -Match "unknown field 'colour'"
        $text | Should -Match "'routes', which only presets/adapters.json may define"
    }
    It 'THROWS on a broken shipped preset - that is a broken install, not a preference' {
        $p = New-RawFile '{ "version": 1, "adapters": ['
        { Get-CliAdapters -PresetPath $p -UserPath $script:None -RepoPath $script:None } | Should -Throw '*broken install*'
        { Get-CliAdapters -PresetPath (Join-Path $TestDrive 'missing-preset.json') -UserPath $script:None -RepoPath $script:None } | Should -Throw '*broken install*'
    }
}
