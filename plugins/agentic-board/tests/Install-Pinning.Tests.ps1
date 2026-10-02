#Requires -Modules Pester
<#  Pinned runtime installs (#765). The directory security scan flags installs with no version: an
    unpinned `npm i -g`, an `@latest`, a remote script piped into iex, a skill cloned from a moving
    branch tip. These tests keep every install path the tool can run on a fixed version.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    # Hermetic registry (#772): the shipped preset only, never this machine's overrides.
    $env:ABIOS_ADAPTERS_USER_FILE = Join-Path $TestDrive 'no-user-adapters.json'
    $env:ABIOS_ADAPTERS_REPO_FILE = Join-Path $TestDrive 'no-repo-adapters.json'
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Board-Work.ps1')
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
}
AfterAll {
    $env:ABIOS_ADAPTERS_USER_FILE = $null
    $env:ABIOS_ADAPTERS_REPO_FILE = $null
}

Describe 'CLI adapters install a pinned version or nothing' {
    It 'every adapter with an install runs an argv whose package carries an exact version' {
        foreach ($a in (Get-CliAdapters | Where-Object { $_.InstallArgs })) {
            $argv = @($a.InstallArgs)
            $argv[0] | Should -Be 'npm' -Because "$($a.Name) installs through npm"
            $argv[-1] | Should -Match '^@?[\w.-]+(/[\w.-]+)?@\d+\.\d+\.\d+$' -Because "$($a.Name) must pin an exact version"
        }
    }
    It 'an adapter with no pinnable package gives the user a page instead of a command' {
        $agy = Get-CliAdapters | Where-Object Name -eq 'antigravity'
        $agy.InstallArgs | Should -BeNullOrEmpty
        $agy.InstallUrl  | Should -Match '^https://'
    }
    It 'Install-CliOnApproval never installs a CLI that has no pinned argv' {
        Mock Read-Host { 'y' }
        $r = Install-CliOnApproval ([pscustomobject]@{ Name = 'x'; InstallArgs = $null; InstallUrl = 'https://example.invalid' })
        $r | Should -BeFalse
        Should -Invoke Read-Host -Times 0
    }
    It 'Get-CliInstallText shows the pinned command' {
        $codex = Get-CliAdapters | Where-Object Name -eq 'codex'
        Get-CliInstallText $codex | Should -Match '^npm i -g @openai/codex@\d+\.\d+\.\d+$'
    }
}

Describe 'No unpinned install in the shipped scripts' {
    It 'no script runs a string through Invoke-Expression or pipes a download into iex' {
        $hits = Get-ChildItem $script:Scripts -Filter *.ps1 | Select-String -Pattern 'Invoke-Expression|\|\s*iex\b' |
            Where-Object { $_.Line -notmatch '^\s*#' }
        @($hits).Count | Should -Be 0 -Because (($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')
    }
    It 'no script installs @latest' {
        $hits = Get-ChildItem $script:Scripts -Filter *.ps1 | Select-String -Pattern '@latest\b'
        @($hits).Count | Should -Be 0 -Because (($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')
    }
}

Describe 'Skill clones are pinned to a commit' {
    It 'every skill-clone entry in the toolkits carries a full commit SHA as ref' {
        $dir = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' | Resolve-Path
        $clones = foreach ($f in Get-ChildItem $dir -Filter *.json) {
            @(Get-Content $f.FullName -Raw | ConvertFrom-Json) | Where-Object kind -eq 'skill-clone'
        }
        @($clones).Count | Should -BeGreaterThan 0
        foreach ($e in $clones) { [string]$e.ref | Should -Match '^[0-9a-f]{40}$' -Because "$($e.name) must be pinned" }
    }
    It 'Install-SkillFromRepo refuses a ref that is not a full SHA, before touching the network' {
        $dest = Join-Path $TestDrive 'skills'
        { & (Join-Path $script:Scripts 'Install-SkillFromRepo.ps1') -Repo 'o/r' -Path 'p' -Name 'n' -Dest $dest -Ref 'main' } |
            Should -Throw '*40-character*'
    }
    It 'the catalog hands the pinned ref to the installer' {
        $body = Get-Content (Join-Path $script:Scripts 'Install-ToolFromCatalog.ps1') -Raw
        $body | Should -Match '\$iargs\.Ref\s*=\s*\$t\.ref'
        (Get-Content (Join-Path $script:Scripts 'Get-ToolsCatalog.ps1') -Raw) | Should -Match 'ref=\$e\.ref'
    }
}
