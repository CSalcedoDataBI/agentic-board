#Requires -Modules Pester
<#  Integration tests for `Board-Work.ps1 -PreferGroupedPRs` (#662).

    Pure tests could not have caught what these do. The bug they exist for was not in any
    function: the preference block SAT BELOW the GitHub token guard, so recording a purely
    local decision threw `TokenVar not set` on a machine with no PAT configured. Only running
    the script end to end, with no token reachable, shows it.

    Each test runs in its own throwaway git repo under TestDrive, so the real repo's
    .agentic-board/config.json is never touched. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path

    function New-ThrowawayRepo {
        param([string]$Name)
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Push-Location $path
        git init -q 2>&1 | Out-Null
        Pop-Location
        $path
    }

    # Runs the script inside $Repo with NO token reachable: GH_TOKEN cleared, and -TokenVar
    # pointed at a registry variable that does not exist.
    function Invoke-PreferenceWithoutToken {
        param([string]$Repo, [string]$Value)
        $saved = $env:GH_TOKEN
        $env:GH_TOKEN = ''
        try {
            Push-Location $Repo
            # 6>&1 as well as 2>&1: the script reports through Write-Host, which in PowerShell 7
            # writes to the INFORMATION stream. Redirecting only errors captures an empty string
            # while the text scrolls past on the console - which is what these tests first did.
            $out = & $script:Script -PreferGroupedPRs $Value -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 6>&1 2>&1 | Out-String
            $code = $LASTEXITCODE
            Pop-Location
            [pscustomobject]@{ output = $out; exitCode = $code }
        } finally { $env:GH_TOKEN = $saved }
    }
}

Describe 'Board-Work.ps1 -PreferGroupedPRs outside a git repo' {
    It 'says where it would have saved the preference instead of throwing' {
        $plain = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $saved = $env:GH_TOKEN
        $env:GH_TOKEN = ''
        try {
            Push-Location $plain
            $out = & $script:Script -PreferGroupedPRs on -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 6>&1 2>&1 | Out-String
            Pop-Location
        } finally { $env:GH_TOKEN = $saved }
        $out | Should -Match 'no hay donde guardar la preferencia'
    }
}

Describe 'Board-Work.ps1 -PreferGroupedPRs' {
    It 'records the preference with no GitHub token available at all' {
        $repo = New-ThrowawayRepo 'pref-no-token'
        $r = Invoke-PreferenceWithoutToken -Repo $repo -Value 'on'
        $r.output | Should -Not -Match 'not set in Windows USER environment'
        $r.output | Should -Match 'Preferencia del repo guardada'

        $cfg = Join-Path $repo '.agentic-board' 'config.json'
        Test-Path $cfg | Should -BeTrue
        (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).preferGroupedPRs | Should -BeTrue
    }

    It 'records off as a real decision, not as an absence' {
        $repo = New-ThrowawayRepo 'pref-off'
        Invoke-PreferenceWithoutToken -Repo $repo -Value 'off' | Out-Null
        $cfg = Join-Path $repo '.agentic-board' 'config.json'
        (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).preferGroupedPRs | Should -BeFalse
    }

    It 'clears the decision back to auto' {
        $repo = New-ThrowawayRepo 'pref-auto'
        Invoke-PreferenceWithoutToken -Repo $repo -Value 'on'   | Out-Null
        Invoke-PreferenceWithoutToken -Repo $repo -Value 'auto' | Out-Null
        $cfg = Join-Path $repo '.agentic-board' 'config.json'
        (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).preferGroupedPRs | Should -BeNullOrEmpty
    }

    It 'says what it recorded in the words of the decision, not in tool jargon' {
        $repo = New-ThrowawayRepo 'pref-words'
        $r = Invoke-PreferenceWithoutToken -Repo $repo -Value 'on'
        $r.output | Should -Match 'De ahora en adelante'
        # #494: no internal script names in user-facing output.
        $r.output | Should -Not -Match '\.ps1'
    }
}
