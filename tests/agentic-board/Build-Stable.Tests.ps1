#Requires -Modules Pester
<#  scripts/Build-Stable.ps1 (#768): the stable commit holds only plugins/agentic-board/, is a
    fast-forward of the previous stable, and is never built when the folder carries something the
    plugin directory refuses. Runs against throw-away git repos; no network. #>

BeforeAll {
    $script:Builder = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Build-Stable.ps1' | Resolve-Path

    function script:New-Repo([string]$Name) {
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $root 'plugins/agentic-board/.claude-plugin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'plugins/agentic-board/skills/s') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'plugins/agentic-board-tools/scripts') -Force | Out-Null
        Set-Content (Join-Path $root 'plugins/agentic-board/.claude-plugin/plugin.json') '{ "name": "agentic-board", "version": "9.9.9" }'
        Set-Content (Join-Path $root 'plugins/agentic-board/skills/s/SKILL.md') '# s'
        Set-Content (Join-Path $root 'plugins/agentic-board-tools/scripts/X.ps1') 'Write-Host x'
        Set-Content (Join-Path $root 'README.md') '# repo'
        Push-Location $root
        try {
            git init --quiet -b main 2>$null
            git config user.email 't@example.invalid'; git config user.name 't'
            git add -A; git commit --quiet -m init
        } finally { Pop-Location }
        $root
    }

    function script:Invoke-Builder([string]$Root, [string[]]$Extra = @()) {
        Push-Location $Root
        try {
            $out = & pwsh -NoProfile -File $script:Builder -NoFetch @Extra 2>&1 | Out-String
            $code = $LASTEXITCODE
            $m = [regex]::Matches($out, '(?m)^[0-9a-f]{40}\s*$') | Select-Object -Last 1
            [pscustomobject]@{ Code = $code; Out = $out; Sha = $(if ($m) { $m.Value.Trim() } else { '' }) }
        } finally { Pop-Location }
    }
}

Describe 'Build-Stable.ps1' {
    It 'builds a commit whose tree is plugins/agentic-board only, and writes no branch' {
        $root = New-Repo 'clean'
        $r = Invoke-Builder $root
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Sha | Should -Match '^[0-9a-f]{40}$'
        Push-Location $root
        try {
            $files = @(git ls-tree -r --name-only $r.Sha)
            $files | Should -Contain 'plugins/agentic-board/skills/s/SKILL.md'
            $files | Should -Contain 'plugins/agentic-board/.claude-plugin/plugin.json'
            $files | Where-Object { $_ -notlike 'plugins/agentic-board/*' } | Should -BeNullOrEmpty
            (git rev-parse "$($r.Sha)^{tree}") | Should -Not -Be (git rev-parse 'HEAD^{tree}')
            @(git branch --list stable) | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }

    It 'parents the new commit on the remote stable, so the push is a fast-forward' {
        $root = New-Repo 'ff'
        Push-Location $root
        try {
            $old = (git rev-parse HEAD).Trim()
            git update-ref refs/remotes/origin/stable $old
            Set-Content (Join-Path $root 'plugins/agentic-board/skills/s/SKILL.md') '# s v2'
            git add -A; git commit --quiet -m v2
        } finally { Pop-Location }
        $r = Invoke-Builder $root
        $r.Code | Should -Be 0 -Because $r.Out
        Push-Location $root
        try { (git rev-parse "$($r.Sha)^1").Trim() | Should -Be $old } finally { Pop-Location }
    }

    It 'says unchanged and builds nothing when stable already holds that tree' {
        $root = New-Repo 'same'
        $first = Invoke-Builder $root
        Push-Location $root
        try { git update-ref refs/remotes/origin/stable $first.Sha } finally { Pop-Location }
        $again = Invoke-Builder $root
        $again.Code | Should -Be 0
        $again.Out | Should -Match 'Unchanged'
    }

    It 'refuses a script, a #! file, a hooks folder or a hooks key, and builds nothing' -ForEach @(
        @{ Case = 'script'; Path = 'plugins/agentic-board/scripts/X.ps1'; Body = 'Write-Host x'; Expect = 'type the directory refuses' }
        @{ Case = 'shebang'; Path = 'plugins/agentic-board/notes.txt'; Body = '#!/bin/sh'; Expect = 'starts with #!' }
        @{ Case = 'hooks'; Path = 'plugins/agentic-board/hooks/hooks.json'; Body = '{}'; Expect = 'hooks/ folder' }
        @{ Case = 'hookkey'; Path = 'plugins/agentic-board/.claude-plugin/plugin.json'; Body = '{ "name": "agentic-board", "version": "1.0.0", "hooks": "./h.json" }'; Expect = 'plugin.json declares hooks' }
    ) {
        $root = New-Repo "bad-$Case"
        $full = Join-Path $root $Path
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
        Set-Content $full $Body
        Push-Location $root
        try { git add -A; git commit --quiet -m bad } finally { Pop-Location }
        $r = Invoke-Builder $root
        $r.Code | Should -Be 1
        $r.Out | Should -Match ([regex]::Escape($Expect))
        $r.Sha | Should -BeNullOrEmpty
    }

    It 'accepts the real plugin folder as it is in this checkout' {
        $env:ABIOS_BUILDSTABLE_DOTSOURCE = '1'
        try { . $script:Builder } finally { $env:ABIOS_BUILDSTABLE_DOTSOURCE = '' }
        $repo = (Join-Path $PSScriptRoot '..' '..' | Resolve-Path).Path
        Push-Location $repo
        try {
            $tree = (git write-tree 2>$null)
            if (-not $tree) { Set-ItResult -Skipped -Because 'the index cannot be written here'; return }
            $sub = (git rev-parse "${tree}:plugins/agentic-board").Trim()
            @(Get-StableFindings -TreeSha $sub) | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }
}
