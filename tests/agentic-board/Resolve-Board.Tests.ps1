#Requires -Modules Pester
<#  Tests for Resolve-Board.ps1 - the read must FAIL CLOSED (#313, part of #303).

    Resolve-Board's whole job is "find-or-reuse, create only if none exists". The find is a
    `gh project list` read, and a gh failure that read as an empty list would send the script
    straight to `gh project create` - manufacturing a duplicate of the board it just could not
    read. That is the #86 bug in one script. After #313 the read goes through Invoke-Gh, so a
    gh failure THROWS before the create.

    The seam here is the `gh` executable itself: mocking it (exit 1, empty stdout) reproduces
    the real 401 with no token and no network. A regression to bare `gh ... | ConvertFrom-Json`
    would NOT throw under this mock - it would proceed to create - so `Should -Throw` plus a
    `create -Times 0 -Exactly` is what pins the fix. (`-Times 0` alone is a vacuous pass; the
    `-Exactly` is the assertion.) #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Resolve-Board.ps1' | Resolve-Path
    # Resolve-Board picks its identity through the account map (#793). These tests must never read
    # the developer's own map or token: no map file means "ambient token", and the ambient token is
    # a dummy - gh is mocked, nothing leaves the process.
    $script:SavedAccountsFile = $env:ABIOS_ACCOUNTS_FILE
    $script:SavedToken        = $env:GH_TOKEN
    $env:ABIOS_ACCOUNTS_FILE  = Join-Path $TestDrive 'no-accounts.json'
    $env:GH_TOKEN             = 'dummy'
    # ...nor the brake state of wherever Pester was started: the resolver looks for a brake marker
    # from the current directory upwards, and a suite run inside an armed worktree would otherwise
    # turn every "outside a braked run" test into an armed one. A clean TestDrive folder has none.
    $script:CleanCwd = Join-Path $TestDrive 'clean-cwd'
    New-Item -ItemType Directory -Force $script:CleanCwd | Out-Null
    Push-Location $script:CleanCwd
}
AfterAll {
    Pop-Location
    $env:ABIOS_ACCOUNTS_FILE = $script:SavedAccountsFile
    $env:GH_TOKEN            = $script:SavedToken
}

Describe 'Resolve-Board fails closed when the board-list read fails (#313)' {

    It 'THROWS instead of CREATING a duplicate board when gh exits non-zero' {
        Mock gh { $global:LASTEXITCODE = 1 }
        { & $script:Script -Owner 'X' -Repo 'X/y' } | Should -Throw
        # The whole point: the create must never run off a failed read.
        Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
    }

    It 'reuses an existing board without creating when the read succeeds' {
        Mock gh { $global:LASTEXITCODE = 0; '{"projects":[{"number":7,"title":"Widget Board"}]}' }
        (& $script:Script -Owner 'X' -Repo 'X/widget' -Title 'Widget Board') | Should -Be 7
        Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
    }
}

Describe 'Resolve-Board applies the canonical preset to a NEWLY created board (#299)' {
    # A board created here is born with GitHub's template Status (`Todo`). Applying the preset at
    # birth renames `Todo`->`Backlog` while the board is empty, so it never carries the legacy option
    # that a later plain apply could duplicate into the Todo+Backlog dead-end #299 describes. The
    # `field-list` read is Apply-FieldPreset's fingerprint: only the preset apply issues it, so its
    # presence/absence is what proves the preset ran (or was skipped). gh is mocked at the seam so no
    # token/network is touched; the real presets/fields.en.json is loaded from disk.
    BeforeEach {
        Mock gh {
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if     ($joined -match 'project\s+create') { '{"number":42}' }
            elseif ($joined -match 'project\s+list')   { '{"projects":[]}' }   # none -> create path
            elseif ($joined -match 'field-list')       { '{"fields":[]}' }     # empty board -> no renames
            elseif ($joined -match 'graphql')          { '{"data":{}}' }
            else                                       { '' }                  # link / edit / field-create
        }
    }

    It 'creates the board AND applies the preset (field-list is the fingerprint)' {
        (& $script:Script -Owner 'X' -Repo 'X/new' -Title 'Nope') | Should -Be 42
        Should -Invoke gh -ParameterFilter { $args -contains 'create' }     -Times 1 -Exactly
        # Two reads: the preset's own, then Resolve-Board reading Status back before it claims the
        # board was born canonical (#794).
        Should -Invoke gh -ParameterFilter { $args -contains 'field-list' } -Times 2 -Exactly
    }

    It '-SkipPreset creates the board but does NOT apply the preset' {
        (& $script:Script -Owner 'X' -Repo 'X/new' -Title 'Nope' -SkipPreset) | Should -Be 42
        Should -Invoke gh -ParameterFilter { $args -contains 'create' }     -Times 1 -Exactly
        Should -Invoke gh -ParameterFilter { $args -contains 'field-list' } -Times 0 -Exactly
    }
}

Describe 'Resolve-Board picks its identity through the account map (#793)' {
    # Before #793 this script used whatever $env:GH_TOKEN held, so an account the map knew could
    # still not be reached through /board init. It now asks the one resolver. The mocked gh records
    # $env:GH_TOKEN at the moment it is called: that IS the identity the script worked with. After
    # the call the caller's own value must be back (review: no identity leaks into the session).

    BeforeAll {
        $script:MapFile = Join-Path $TestDrive 'accounts.third.json'
        @{ defaultOwner = 'Me'; owners = @{ Me = 'ABIOS_T793_ME'; ThirdOrg = 'ABIOS_T793_THIRD' }
           agentTokenVar = 'ABIOS_T793_AGENT' } | ConvertTo-Json | Set-Content $script:MapFile
    }
    BeforeEach {
        $env:ABIOS_ACCOUNTS_FILE = $script:MapFile
        $env:ABIOS_T793_ME       = 'tok-me'
        $env:ABIOS_T793_THIRD    = 'tok-third'
        $env:ABIOS_T793_OTHER    = 'tok-other'
        $env:GH_TOKEN            = 'dummy'
        $global:AbiosSeenTokens = @()
        Mock gh {
            $global:LASTEXITCODE = 0
            $global:AbiosSeenTokens += "$env:GH_TOKEN"
            '{"data":{"repository":{"projectsV2":{"pageInfo":{"hasNextPage":false},"nodes":[{"number":3,"title":"app - Roadmap","closed":false,"owner":{"login":"ThirdOrg"}}]}}}}'
        }
    }
    AfterEach {
        $env:ABIOS_ACCOUNTS_FILE = Join-Path $TestDrive 'no-accounts.json'
        $env:GH_TOKEN            = 'dummy'
        foreach ($n in 'ABIOS_T793_ME', 'ABIOS_T793_THIRD', 'ABIOS_T793_OTHER', 'ABIOS_T793_AGENT') {
            [Environment]::SetEnvironmentVariable($n, $null)
        }
        $global:AbiosSeenTokens = $null
    }

    It 'uses the token of a THIRD account the map names - no plugin edit, no hand-set GH_TOKEN' {
        (& $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -CreateIfMissing $false 6>$null) | Should -Be 3
        $global:AbiosSeenTokens | Should -Not -BeNullOrEmpty
        $global:AbiosSeenTokens | Should -Be @('tok-third')
    }

    It "gives the caller's own GH_TOKEN back afterwards - the chosen identity does not leak into the session" {
        & $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -CreateIfMissing $false 6>$null | Out-Null
        $env:GH_TOKEN | Should -Be 'dummy'
    }

    It 'gives it back on a THROW too' {
        Mock gh { $global:LASTEXITCODE = 1 }
        { & $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' 6>$null } | Should -Throw
        $env:GH_TOKEN | Should -Be 'dummy'
    }

    It 'CREATES, links and applies the preset all under the chosen identity (no call slips to another)' {
        # The nested Apply-FieldPreset gets no -TokenVar: it must run on the token lent through
        # GH_TOKEN, not re-resolve the owner from the map (which here would say THIRD, not OTHER).
        Mock gh {
            $global:LASTEXITCODE = 0
            $global:AbiosSeenTokens += "$env:GH_TOKEN"
            $j = $args -join ' '
            if     ($j -match 'project\s+create') { '{"number":42}' }
            elseif ($j -match 'project\s+list')   { '{"projects":[]}' }
            elseif ($j -match 'field-list')       { '{"fields":[]}' }
            elseif ($j -match 'graphql')          { '{"data":{}}' }
            else                                  { '' }
        }
        (& $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/new' -Title 'Nope' -TokenVar 'ABIOS_T793_OTHER' 6>$null) | Should -Be 42
        Should -Invoke gh -ParameterFilter { $args -contains 'field-create' } -Times 1   # the preset did run
        @($global:AbiosSeenTokens | Select-Object -Unique) | Should -Be @('tok-other')
        $env:GH_TOKEN | Should -Be 'dummy'
    }

    It 'honours an explicit -TokenVar outside a braked run' {
        (& $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -TokenVar 'ABIOS_T793_OTHER' -CreateIfMissing $false 6>$null) | Should -Be 3
        $global:AbiosSeenTokens | Should -Be @('tok-other')
    }

    It 'fails BEFORE any gh call when an explicit -TokenVar is unset (never a silent fallback)' {
        { & $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -TokenVar 'ABIOS_T793_MISSING' 6>$null } |
            Should -Throw -ExpectedMessage '*ABIOS_T793_MISSING is not set*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'inside a brake-armed run refuses any -TokenVar but the agent identity' {
        $armed = Join-Path $TestDrive 'armed'
        New-Item -ItemType Directory -Force (Join-Path $armed '.agentic-board') | Out-Null
        '{}' | Set-Content (Join-Path (Join-Path $armed '.agentic-board') 'brake-armed.json')
        Push-Location $armed
        try {
            { & $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -TokenVar 'ABIOS_T793_THIRD' 6>$null } |
                Should -Throw -ExpectedMessage '*BRAKED run*'
        } finally { Pop-Location }
        Should -Invoke gh -Times 0 -Exactly
    }

    Context 'a brake-armed run with no -TokenVar' {
        BeforeEach {
            $script:Armed = Join-Path $TestDrive 'armed2'
            New-Item -ItemType Directory -Force (Join-Path $script:Armed '.agentic-board') | Out-Null
            '{}' | Set-Content (Join-Path (Join-Path $script:Armed '.agentic-board') 'brake-armed.json')
        }

        It 'works as the AGENT identity, not the mapped owner nor the ambient token' {
            $env:ABIOS_T793_AGENT = 'tok-agent'
            Push-Location $script:Armed
            try { (& $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -CreateIfMissing $false 6>$null) | Should -Be 3 }
            finally { Pop-Location }
            $global:AbiosSeenTokens | Should -Be @('tok-agent')
        }

        It 'accepts the agent variable named explicitly' {
            $env:ABIOS_T793_AGENT = 'tok-agent'
            Push-Location $script:Armed
            try { (& $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' -TokenVar 'ABIOS_T793_AGENT' -CreateIfMissing $false 6>$null) | Should -Be 3 }
            finally { Pop-Location }
            $global:AbiosSeenTokens | Should -Be @('tok-agent')
        }

        It 'STOPS before any gh call when the agent token is missing (never falls back to the owner)' {
            Push-Location $script:Armed
            try {
                { & $script:Script -Owner 'ThirdOrg' -Repo 'ThirdOrg/app' 6>$null } |
                    Should -Throw -ExpectedMessage '*BRAKED run*ABIOS_T793_AGENT*'
            } finally { Pop-Location }
            Should -Invoke gh -Times 0 -Exactly
        }
    }
}

Describe 'Resolve-Board only claims "born canonical" after reading Status back (#794)' {
    # The lie: "board born on the canonical vocabulary (no legacy 'Todo')" printed after ANY preset
    # apply, including the -Lang es one that left Status on Todo / In Progress / Done. The claim is
    # now decided by the live options. Apply-FieldPreset is replaced by a stub in a copy of the
    # scripts folder, so the read-back is the only thing under test.

    BeforeAll {
        $script:Work = Join-Path $TestDrive 'rb794'
        New-Item -ItemType Directory -Force $script:Work | Out-Null
        $src = Split-Path $script:Script -Parent
        Get-ChildItem $src -Filter '*.ps1' | Where-Object { $_.Name -ne 'Apply-FieldPreset.ps1' } |
            Copy-Item -Destination $script:Work
        'param([int]$Number, [string]$Owner, [string]$Lang, [switch]$Yes)' |
            Set-Content (Join-Path $script:Work 'Apply-FieldPreset.ps1')
        $script:Copy = Join-Path $script:Work 'Resolve-Board.ps1'

        function script:Invoke-Create([string]$StatusJson, [string]$Lang = 'en') {
            $global:AbiosStatusJson = $StatusJson
            Mock gh {
                $global:LASTEXITCODE = 0
                $j = $args -join ' '
                if     ($j -match 'project\s+create') { '{"number":42}' }
                elseif ($j -match 'project\s+list')   { '{"projects":[]}' }
                elseif ($j -match 'field-list')       { $global:AbiosStatusJson }
                elseif ($j -match 'graphql')          { '{"data":{}}' }
                else                                  { '' }
            }
            $all = & $script:Copy -Owner 'X' -Repo 'X/new' -Title 'Nope' -Lang $Lang 6>&1
            (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) |
                ForEach-Object { "$($_.MessageData)" }) -join "`n"
        }
    }
    AfterAll { $global:AbiosStatusJson = $null }

    It 'WARNS, naming the legacy option, when Status still carries Todo' {
        $out = script:Invoke-Create '{"fields":[{"name":"Status","options":[{"name":"Todo"},{"name":"In Progress"},{"name":"Done"}]}]}' 'es'
        $out | Should -Not -Match 'born on the canonical vocabulary'
        $out | Should -Match 'NOT canonical'
        $out | Should -Match 'legacy: Todo'
        $out | Should -Match 'missing: Backlog, In Review, Blocked'
    }

    It 'claims "born canonical" only when the live Status is exactly the canonical set' {
        $out = script:Invoke-Create '{"fields":[{"name":"Status","options":[{"name":"Backlog"},{"name":"In Progress"},{"name":"In Review"},{"name":"Blocked"},{"name":"Done"}]}]}'
        $out | Should -Match "born on the canonical vocabulary \(no legacy 'Todo'\)"
        $out | Should -Not -Match 'NOT canonical'
    }

    It 'does not claim it either when Status carries an option the vocabulary does not know' {
        $out = script:Invoke-Create '{"fields":[{"name":"Status","options":[{"name":"Backlog"},{"name":"In Progress"},{"name":"In Review"},{"name":"Blocked"},{"name":"Done"},{"name":"Triage"}]}]}'
        $out | Should -Not -Match 'born on the canonical vocabulary'
        $out | Should -Match 'unknown: Triage'
    }

    It '-Lang es says the other fields are named in Spanish' {
        $out = script:Invoke-Create '{"fields":[{"name":"Status","options":[{"name":"Backlog"},{"name":"In Progress"},{"name":"In Review"},{"name":"Blocked"},{"name":"Done"}]}]}' 'es'
        $out | Should -Match '-Lang es names Priority/Size'
    }
}
