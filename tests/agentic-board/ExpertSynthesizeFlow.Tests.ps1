#Requires -Modules Pester
<#  End-to-end test of the synthesize-and-persist flow for a plan that matches NO role (#466).

    The flow (commands/expert.md, skill board-expert): `config` reports NO ROLE MATCHED -> the
    agent proposes a role and, once the user confirms, persists it with Add-ExpertRole -> the NEXT
    plan of that kind classifies to the new role, the contract carries it, and `roles` lists it.

    Every step runs the real scripts in child processes against a hermetic project and home, so it
    exercises the same argument handling, state-dir resolution and file round-trip a user gets.
    Nothing is mocked. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Dirs = [System.Collections.Generic.List[string]]::new()
    function New-Tracked([string]$Tag) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("$Tag-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $script:Dirs.Add($d); $d
    }

    $script:FakeHome = New-Tracked 'flow-home'
    $script:Repo     = New-Tracked 'flow-repo'
    $script:Contract = Join-Path $script:Repo 'contract.json'
    $script:Plan     = 'Survey the zebra herd migration corridors'

    # An installed skill the new role can hook (a project skill of the hermetic repo).
    $skillDir = Join-Path $script:Repo '.claude/skills/wildlife/zoology-helper'
    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Encoding utf8 `
        -Value "---`nname: zoology-helper`ndescription: Helps with zoology field surveys. Use when planning wildlife work.`n---`nBody"

    # Persist step, as the skill instructs: Add-ExpertRole, called from the project directory.
    $script:PersistScript = Join-Path $script:Repo 'persist.ps1'
    Set-Content -LiteralPath $script:PersistScript -Encoding utf8 -Value @"
`$env:ABIOS_EXPERTROLES_DOTSOURCE = '1'
. '$($script:Scripts)/ExpertRolesIo.ps1'
`$path = Add-ExpertRole -Role @{ name = 'zoology'; keywords = @('zebra', 'herd'); skills = @('zoology') }
Write-Output "PERSISTED:`$path"
"@

    function Invoke-InRepo {
        # Run a script in a child pwsh with cwd = the hermetic repo and HOME = the hermetic home.
        param([string[]]$PwshArgs)
        $prevHome = $env:HOME; $prevProf = $env:USERPROFILE
        $env:HOME = $script:FakeHome; $env:USERPROFILE = $script:FakeHome
        Push-Location $script:Repo
        try { & pwsh -NoProfile -File @PwshArgs 2>&1 | Out-String }
        finally { Pop-Location; $env:HOME = $prevHome; $env:USERPROFILE = $prevProf }
    }

    Push-Location $script:Repo
    try { & git init -q . 2>&1 | Out-Null } finally { Pop-Location }

    # Step 1: config on a plan no role matches.
    $script:Out1 = Invoke-InRepo @((Join-Path $script:Scripts 'Expert-Config.ps1'),
        '-PlanText', $script:Plan, '-PlanGoal', 'Map the corridors', '-Path', $script:Contract, '-InstalledPlugins', 'none')
    $script:C1 = if (Test-Path $script:Contract) { Get-Content -Raw $script:Contract | ConvertFrom-Json } else { $null }
    Remove-Item -LiteralPath $script:Contract -Force -ErrorAction SilentlyContinue

    # Step 2: persist the synthesized role (after the user's confirmation, in the real flow).
    $script:Out2 = Invoke-InRepo @($script:PersistScript)
    $script:LocalRoles = Join-Path $script:Repo '.agentic-board/roles.json'

    # Step 3: config again on the same kind of plan.
    $script:Out3 = Invoke-InRepo @((Join-Path $script:Scripts 'Expert-Config.ps1'),
        '-PlanText', 'Plan the next zebra count', '-PlanGoal', 'Count zebras', '-Path', $script:Contract, '-InstalledPlugins', 'none')
    $script:C3 = if (Test-Path $script:Contract) { Get-Content -Raw $script:Contract | ConvertFrom-Json } else { $null }

    # Step 4: the catalog explains itself.
    $script:OutWhy  = Invoke-InRepo @((Join-Path $script:Scripts 'Expert-Roles.ps1'), '-Why', 'Plan the next zebra count')
    $script:OutList = Invoke-InRepo @((Join-Path $script:Scripts 'Expert-Roles.ps1'), '-List')
}

AfterAll {
    foreach ($d in $script:Dirs) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

Describe 'a plan that matches no role (#466)' {
    It 'is reported as NO ROLE MATCHED so the flow can offer to synthesize one' {
        $script:Out1 | Should -Match 'NO ROLE MATCHED'
        $script:C1.roleMatched | Should -BeFalse
    }
    It 'says it is scanning before it prints the role preview (never a silent wait, #609)' {
        $iScan = $script:Out1.IndexOf('Scanning installed skills')
        $iRole = $script:Out1.IndexOf('Synthesized role')
        $iScan | Should -BeGreaterOrEqual 0
        $iRole | Should -BeGreaterThan $iScan
    }
    It 'runs as the generic role until one is persisted' {
        $script:C1.role | Should -Match 'expert in generic'
    }
}

Describe 'persisting the synthesized role (#466)' {
    It 'writes the role to the project-local catalog' {
        $script:Out2 | Should -Match 'PERSISTED:'
        Test-Path -LiteralPath $script:LocalRoles | Should -BeTrue
    }
    It 'writes a catalog the loader accepts: valid JSON, current schema version, the role intact' {
        $doc = Get-Content -Raw -LiteralPath $script:LocalRoles | ConvertFrom-Json
        $doc.version | Should -Be 1
        @($doc.roles).Count | Should -Be 1
        $doc.roles[0].name | Should -Be 'zoology'
        @($doc.roles[0].keywords) | Should -Be @('zebra', 'herd')
        @($doc.roles[0].skills)   | Should -Be @('zoology')
    }
    It 'emits no warning that the loader rejected or ignored the file' {
        $script:Out3 | Should -Not -Match '(?i)ignoring'
        $script:Out3 | Should -Not -Match '(?i)skipped'
    }
}

Describe 'the next plan of that kind after persisting (#466)' {
    It 'no longer reports NO ROLE MATCHED' {
        $script:Out3 | Should -Not -Match 'NO ROLE MATCHED'
        $script:C3.roleMatched | Should -BeTrue
    }
    It 'classifies to the persisted role and carries it into the contract' {
        $script:C3.role | Should -Match 'expert in zoology'
    }
    It 'hooks the installed skill the role points at' {
        $script:C3.role | Should -Match '(?m)^- zoology-helper$'
    }
    It '`roles why` names the persisted role and the keyword that decided it' {
        $script:OutWhy | Should -Match "MATCH\s+'zoology'"
        $script:OutWhy | Should -Match "keyword 'zebra'"
    }
    It '`roles` lists it as a local role with its keywords and one hooked skill' {
        $script:OutList | Should -Match '(?m)^\s+zoology\s+local\s+2\s+1\b'
    }
}
