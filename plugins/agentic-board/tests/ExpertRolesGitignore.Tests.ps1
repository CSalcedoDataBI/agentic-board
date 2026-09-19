#Requires -Modules Pester
<#  Tests for the roles.json .gitignore repair (#470).

    A project that git-ignores `.agentic-board/` can never version roles.json, and the one-line
    "fix" people reach for - `!.agentic-board/roles.json` after `.agentic-board/` - does nothing:
    git cannot re-include a file whose PARENT DIRECTORY is excluded. The working form excludes the
    directory's CONTENTS (`.agentic-board/*`) and then re-includes the file.

    Every assertion here asks GIT (`git add`, `git status`, `git check-ignore`) in a real temporary
    repository - never by grepping .gitignore for the expected text. Nothing is mocked. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_EXPERTROLES_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'ExpertRolesIo.ps1')
    $env:ABIOS_EXPERTROLES_DOTSOURCE = ''

    $script:Dirs = [System.Collections.Generic.List[string]]::new()
    function New-Repo {
        param([string[]]$GitignoreLines, [switch]$Crlf, [switch]$NoRolesFile)
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("gi-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$d/.agentic-board" -Force | Out-Null
        $script:Dirs.Add($d)
        & git -C $d init -q 2>&1 | Out-Null
        if ($GitignoreLines) {
            $eol = if ($Crlf) { "`r`n" } else { "`n" }
            [System.IO.File]::WriteAllText((Join-Path $d '.gitignore'), (($GitignoreLines -join $eol) + $eol), [System.Text.UTF8Encoding]::new($false))
        }
        if (-not $NoRolesFile) { Set-Content -LiteralPath "$d/.agentic-board/roles.json" -Value '{"version":1,"roles":[]}' }
        Set-Content -LiteralPath "$d/.agentic-board/sessions.json" -Value '{}'
        Set-Content -LiteralPath "$d/.agentic-board/expert.json" -Value '{}'
        $d
    }
    # What git itself says. `add --dry-run` exits non-zero for an ignored path.
    function Test-GitAccepts([string]$Repo, [string]$Rel) {
        & git -C $Repo add --dry-run -- $Rel 2>&1 | Out-Null
        $LASTEXITCODE -eq 0
    }
    function Get-Staged([string]$Repo) { @(& git -C $Repo diff --cached --name-only) }
}

AfterAll {
    foreach ($d in $script:Dirs) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

Describe 'the trap this repairs, measured (#470)' {
    It 'a directory-level negation leaves roles.json ignored - git refuses to stage it' {
        $r = New-Repo @('.agentic-board/', '!.agentic-board/roles.json')
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeFalse
    }
    It 'excluding the directory CONTENTS plus the negation works - git stages it' {
        $r = New-Repo @('.agentic-board/*', '!.agentic-board/roles.json')
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
    }
}

Describe 'Repair-RolesGitignore makes roles.json genuinely trackable (#470)' {
    It 'fixes <Name>: git stages roles.json and nothing else of the state dir' -ForEach @(
        @{ Name = 'a directory rule';                Lines = @('node_modules/', '.agentic-board/') }
        @{ Name = 'a directory rule without slash';  Lines = @('.agentic-board') }
        @{ Name = 'a rooted directory rule';         Lines = @('/.agentic-board/') }
        @{ Name = 'the dead directory-level negation'; Lines = @('.agentic-board/', '!.agentic-board/roles.json') }
        @{ Name = 'a contents rule with no negation'; Lines = @('.agentic-board/*') }
    ) {
        $r = New-Repo $Lines
        $res = Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json"
        $res.Status | Should -Be 'Repaired'
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
        & git -C $r add -- .agentic-board/roles.json 2>&1 | Out-Null
        Get-Staged $r | Should -Be @('.agentic-board/roles.json')
        # The rest of the state directory must stay local.
        Test-GitAccepts $r '.agentic-board/sessions.json' | Should -BeFalse
        Test-GitAccepts $r '.agentic-board/expert.json'   | Should -BeFalse
    }
    It 'never leaves the directory-level negation in the file it writes' {
        $r = New-Repo @('.agentic-board/', '!.agentic-board/roles.json')
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        $lines = @(Get-Content -LiteralPath "$r/.gitignore")
        $lines | Should -Not -Contain '.agentic-board/'
        $lines | Should -Not -Contain '.agentic-board'
        @($lines | Where-Object { $_ -eq '!.agentic-board/roles.json' }).Count | Should -Be 1
    }
    It 'keeps the unrelated rules of the file' {
        $r = New-Repo @('node_modules/', '*.log', '.agentic-board/', 'dist/')
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        $lines = @(Get-Content -LiteralPath "$r/.gitignore")
        $lines | Should -Contain 'node_modules/'
        $lines | Should -Contain '*.log'
        $lines | Should -Contain 'dist/'
    }
    It 'is idempotent: a second run changes nothing' {
        $r = New-Repo @('.agentic-board/')
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        $before = (Get-FileHash "$r/.gitignore").Hash
        $again = Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json"
        $again.Status | Should -Be 'AlreadyTrackable'
        $again.Changed | Should -BeFalse
        (Get-FileHash "$r/.gitignore").Hash | Should -Be $before
    }
    It 'works before roles.json exists (the persist step runs it after writing, but the rule must hold either way)' {
        $r = New-Repo @('.agentic-board/') -NoRolesFile
        $res = Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json"
        $res.Status | Should -Be 'Repaired'
        Set-Content -LiteralPath "$r/.agentic-board/roles.json" -Value '{}'
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
    }
    It 'preserves CRLF line endings' {
        $r = New-Repo @('node_modules/', '.agentic-board/') -Crlf
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        $raw = [System.IO.File]::ReadAllText("$r/.gitignore")
        $raw | Should -Match "`r`n"
        ($raw -replace "`r`n", '') | Should -Not -Match "`n"
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
    }
    It 'keeps LF line endings LF' {
        $r = New-Repo @('.agentic-board/')
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        [System.IO.File]::ReadAllText("$r/.gitignore") | Should -Not -Match "`r"
    }
}

Describe 'Repair-RolesGitignore leaves things alone when it should (#470)' {
    It 'does nothing for a project that does not ignore the state directory' {
        $r = New-Repo @('node_modules/')
        $before = (Get-FileHash "$r/.gitignore").Hash
        $res = Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json"
        $res.Status | Should -Be 'AlreadyTrackable'
        (Get-FileHash "$r/.gitignore").Hash | Should -Be $before
    }
    It 'does not create a .gitignore for a project without one' {
        $r = New-Repo $null
        Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json" | Out-Null
        Test-Path "$r/.gitignore" | Should -BeFalse
    }
    It 'reports NotARepo outside a git repository and touches nothing' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("gi-norepo-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$d/.agentic-board" -Force | Out-Null
        $script:Dirs.Add($d)
        (Repair-RolesGitignore -RolesPath "$d/.agentic-board/roles.json").Status | Should -Be 'NotARepo'
        Test-Path "$d/.gitignore" | Should -BeFalse
    }
    It 'restores the .gitignore byte for byte when git still refuses (the rule lives elsewhere)' {
        # The ignore comes from .git/info/exclude, which the repair cannot and must not edit.
        $r = New-Repo @('node_modules/')
        Add-Content -LiteralPath "$r/.git/info/exclude" -Value '.agentic-board/'
        $before = [System.IO.File]::ReadAllBytes("$r/.gitignore")
        $res = Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json"
        $res.Status | Should -Be 'CannotRepair'
        $res.Changed | Should -BeFalse
        [System.IO.File]::ReadAllBytes("$r/.gitignore") | Should -Be $before
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeFalse
    }
    It 'reports CannotRepair, without inventing a .gitignore, when the repo has none and something else ignores the file' {
        $r = New-Repo $null
        Add-Content -LiteralPath "$r/.git/info/exclude" -Value '.agentic-board/'
        (Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json").Status | Should -Be 'CannotRepair'
        Test-Path "$r/.gitignore" | Should -BeFalse
    }
}

Describe 'what it says is for a non-programmer (#470)' {
    It 'reports the outcome in plain words: no command to paste, no git syntax, no plugin cache path' {
        $r = New-Repo @('.agentic-board/')
        $msg = (Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json").Message
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Not -Match '(?i)printf|pwsh|powershell|git (add|check|commit)|plugins[/\\]cache|\.ps1'
        $msg | Should -Match 'Nothing for you to run'
    }
    It 'keeps every line short enough not to wrap in a standard terminal' {
        $r = New-Repo @('.agentic-board/')
        $msg = (Repair-RolesGitignore -RolesPath "$r/.agentic-board/roles.json").Message
        foreach ($l in ($msg -split "`n")) { $l.TrimEnd("`r").Length | Should -BeLessOrEqual 95 }
        $r2 = New-Repo @('node_modules/'); Add-Content -LiteralPath "$r2/.git/info/exclude" -Value '.agentic-board/'
        $msg2 = (Repair-RolesGitignore -RolesPath "$r2/.agentic-board/roles.json").Message
        foreach ($l in ($msg2 -split "`n")) { $l.TrimEnd("`r").Length | Should -BeLessOrEqual 95 }
    }
}

Describe 'persisting a role makes the file shareable on its own (#470)' {
    It 'Add-ExpertRole (default path) leaves roles.json trackable in a project that ignores .agentic-board/' {
        $r = New-Repo @('.agentic-board/') -NoRolesFile
        Push-Location $r
        try {
            $out = & { Add-ExpertRole -Role @{ name = 'zoology'; keywords = @('zebra'); skills = @('zoology') } } 6>&1 | Out-String
        } finally { Pop-Location }
        Test-Path "$r/.agentic-board/roles.json" | Should -BeTrue
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
        $out | Should -Match 'Nothing for you to run'
    }
    It 'Add-ExpertRole with an explicit -Path never edits a .gitignore' {
        $r = New-Repo @('.agentic-board/') -NoRolesFile
        $before = (Get-FileHash "$r/.gitignore").Hash
        Add-ExpertRole -Role @{ name = 'x'; keywords = @('a'); skills = @() } -Path "$r/.agentic-board/roles.json" | Out-Null
        (Get-FileHash "$r/.gitignore").Hash | Should -Be $before
    }
}

Describe 'Expert-Config.ps1 and Expert-Roles.ps1 -List (CLI, #470)' {
    BeforeAll {
        function Invoke-Cli {
            param([string]$Repo, [string[]]$PwshArgs)
            $fakeHome = Join-Path ([System.IO.Path]::GetTempPath()) ("gi-home-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
            $script:Dirs.Add($fakeHome)
            $ph = $env:HOME; $pp = $env:USERPROFILE
            $env:HOME = $fakeHome; $env:USERPROFILE = $fakeHome
            Push-Location $Repo
            try { & pwsh -NoProfile -File @PwshArgs 2>&1 | Out-String } finally { Pop-Location; $env:HOME = $ph; $env:USERPROFILE = $pp }
        }
    }
    It 'config repairs an ignored roles.json it finds and says so in plain words' {
        $r = New-Repo @('.agentic-board/')
        $out = Invoke-Cli $r @((Join-Path $script:Scripts 'Expert-Config.ps1'), '-PlanText', 'x', '-PlanGoal', 'g',
                               '-Path', (Join-Path $r 'contract.json'), '-InstalledPlugins', 'none')
        Test-GitAccepts $r '.agentic-board/roles.json' | Should -BeTrue
        $out | Should -Match 'Nothing for you to run'
    }
    It 'config leaves a project whose roles.json is already shareable untouched' {
        $r = New-Repo @('node_modules/')
        $before = (Get-FileHash "$r/.gitignore").Hash
        Invoke-Cli $r @((Join-Path $script:Scripts 'Expert-Config.ps1'), '-PlanText', 'x', '-PlanGoal', 'g',
                        '-Path', (Join-Path $r 'contract.json'), '-InstalledPlugins', 'none') | Out-Null
        (Get-FileHash "$r/.gitignore").Hash | Should -Be $before
    }
    It 'roles -List only WARNS about an ignored roles.json - it is read-only' {
        $r = New-Repo @('.agentic-board/')
        $before = (Get-FileHash "$r/.gitignore").Hash
        $out = Invoke-Cli $r @((Join-Path $script:Scripts 'Expert-Roles.ps1'), '-List')
        $out | Should -Match '(?i)roles\.json.*ignored by git'
        (Get-FileHash "$r/.gitignore").Hash | Should -Be $before
    }
}
