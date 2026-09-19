#Requires -Modules Pester
<#  Tests for the plugin-script paths in the session briefing of Board-Work.ps1 (#480).

    Get-SessionBriefing named its scripts `plugins/agentic-board/scripts/<name>`, a path relative to
    the session's working directory that exists in exactly one repository: this one. In every
    consumer project the commands pointed at nothing, the session improvised a bare `gh pr create`
    and the review gate never ran. These render the REAL briefing and check the paths against the
    disk, for a repo that is not this one, for this one, and for a script that is genuinely absent. #>

# Evaluated at DISCOVERY time (a -Skip condition is read before any BeforeAll runs): is this a
# checkout of the repo itself? Absent when the tests run from an installed plugin cache, where
# the layout is flatter.
$discoveryRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..') -ErrorAction SilentlyContinue).Path
$discoveryInThisRepo = [bool]($discoveryRepoRoot -and (Test-Path (Join-Path $discoveryRepoRoot 'plugins/agentic-board/scripts/New-BoardPR.ps1')))

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    $script:ScriptsDir = Split-Path -Parent $script:Script
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..') -ErrorAction SilentlyContinue).Path

    # Every `pwsh <script>.ps1` the briefing tells the session to run, as the token it would type.
    function Get-BriefingScriptTokens([string]$Briefing) {
        @([regex]::Matches($Briefing, 'pwsh ("[^"]+\.ps1"|\S+\.ps1)') | ForEach-Object { $_.Groups[1].Value.Trim('"') })
    }
}

Describe 'a briefing composed for a repo that is NOT this one (#480)' {
    BeforeAll {
        # A consumer project: a work folder with no plugins/ directory in it.
        $script:Consumer = Join-Path $TestDrive 'consumer-repo--worktrees\issue-9'
        New-Item -ItemType Directory -Path $script:Consumer -Force | Out-Null
        $script:Brief = Get-SessionBriefing 9 'someone/consumer' 'issue-9-x' $script:Consumer
        $script:Tokens = Get-BriefingScriptTokens $script:Brief
    }

    It 'names all six plugin scripts' {
        $names = $script:Tokens | ForEach-Object { Split-Path -Leaf $_ }
        foreach ($n in 'Fleet-Findings.ps1', 'Fleet-Handoff.ps1', 'Fleet-Ownership.ps1', 'New-BoardPR.ps1', 'Board-ReviewGate.ps1', 'Board-Merge.ps1') {
            $names | Should -Contain $n
        }
    }
    It 'names paths that EXIST on disk - the bug was commands that pointed at nothing' {
        # Resolve them the way the session will: from ITS working directory. From the runner's own cwd
        # (usually this repo's root) the old repo-relative form would resolve too and hide the bug.
        Push-Location $script:Consumer
        try {
            foreach ($t in $script:Tokens) { (Test-Path -LiteralPath $t) | Should -BeTrue -Because "'$t' must resolve from the session's working directory" }
        } finally { Pop-Location }
    }
    It 'no longer emits the repo-relative form that only resolves in this repo' {
        $script:Brief | Should -Not -Match 'pwsh plugins/agentic-board/scripts/'
    }
    It 'points at the folder of the script that composed it (the same install, so it exists by construction)' {
        $np = $script:Tokens | Where-Object { $_ -like '*New-BoardPR.ps1' } | Select-Object -First 1
        ($np -replace '\\', '/') | Should -Be ((Join-Path $script:ScriptsDir 'New-BoardPR.ps1') -replace '\\', '/')
    }
    It 'stays a single line and keeps the numbered steps' {
        $script:Brief | Should -Not -Match "`n"
        foreach ($n in 1..6) { ([regex]::Matches($script:Brief, "\($n\)")).Count | Should -Be 1 }
    }
    It 'always tells the session not to substitute a missing script with a bare gh pr create' {
        $script:Brief | Should -Match "do NOT replace New-BoardPR\.ps1 with a bare 'gh pr create'"
        $script:Brief | Should -Match 'STOP and report'
        $script:Brief | Should -Not -Match 'WARNING - these plugin scripts were NOT found'
    }
}

Describe 'a briefing composed for THIS repo is unchanged (#480, the other direction)' {
    It 'keeps the repo-relative form, which resolves from the worktree''s own copy' -Skip:(-not $discoveryInThisRepo) {
        $b = Get-SessionBriefing 42 'CSalcedoDataBI/agentic-board' 'issue-42-x' $script:RepoRoot
        $b | Should -Match 'pwsh plugins/agentic-board/scripts/New-BoardPR\.ps1 -Issue 42 '
        $b | Should -Match 'pwsh plugins/agentic-board/scripts/Board-ReviewGate\.ps1 -PR <pr>'
        $b | Should -Match 'pwsh plugins/agentic-board/scripts/Board-Merge\.ps1 -PR <pr>'
        $b | Should -Match 'pwsh plugins/agentic-board/scripts/Fleet-Findings\.ps1 -List'
        # ...and those relative paths really resolve from that folder
        foreach ($t in (Get-BriefingScriptTokens $b)) { (Test-Path -LiteralPath (Join-Path $script:RepoRoot $t)) | Should -BeTrue }
    }
}

Describe 'a script that cannot be found is reported, not silently replaced (#480)' {
    BeforeAll {
        $script:Empty = Join-Path $TestDrive 'no-scripts-here'
        New-Item -ItemType Directory -Path $script:Empty -Force | Out-Null
        $script:WorkDir = Join-Path $TestDrive 'wd'
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    It 'lists exactly the missing scripts in a WARNING and forbids the gh substitute' {
        $b = Get-SessionBriefing 9 'o/r' 'issue-9-x' $script:WorkDir -ScriptsDir $script:Empty
        $b | Should -Match 'WARNING - these plugin scripts were NOT found on this machine: '
        foreach ($n in 'New-BoardPR.ps1', 'Board-ReviewGate.ps1', 'Board-Merge.ps1', 'Fleet-Findings.ps1') { $b | Should -Match ([regex]::Escape($n)) }
        $b | Should -Match "do NOT replace New-BoardPR\.ps1 with a bare 'gh pr create'"
    }
    It 'names only the scripts that are really missing' {
        $partial = Join-Path $TestDrive 'partial'
        New-Item -ItemType Directory -Path $partial -Force | Out-Null
        foreach ($n in 'Fleet-Findings.ps1', 'Fleet-Handoff.ps1', 'Fleet-Ownership.ps1', 'Board-ReviewGate.ps1', 'Board-Merge.ps1') { Set-Content (Join-Path $partial $n) '# stub' }
        $b = Get-SessionBriefing 9 'o/r' 'issue-9-x' $script:WorkDir -ScriptsDir $partial
        $b | Should -Match 'NOT found on this machine: New-BoardPR\.ps1\.'
    }
    It 'under the merge brake, a missing Board-Merge is not mentioned (the brake never orders it)' {
        $b = Get-SessionBriefing 9 'o/r' 'issue-9-x' $script:WorkDir -StopAtPR -ScriptsDir $script:Empty
        $b | Should -Not -Match 'Board-Merge'
        $b | Should -Match 'NOT found'
    }
}

Describe 'Resolve-BriefingScriptRef' {
    It 'quotes an absolute path that contains whitespace, with forward slashes' {
        $dir = Join-Path $TestDrive 'a folder with spaces'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'New-BoardPR.ps1') '# stub'
        $r = Resolve-BriefingScriptRef -Name 'New-BoardPR.ps1' -WorkPath (Join-Path $TestDrive 'elsewhere') -ScriptsDir $dir
        $r.found | Should -BeTrue
        $r.ref   | Should -Match '^".* folder with spaces/New-BoardPR\.ps1"$'
        $r.ref   | Should -Not -Match '\\'
    }
    It 'prefers the working copy''s own relative path when it carries the plugin' {
        $wc = Join-Path $TestDrive 'vendored'
        New-Item -ItemType Directory -Path (Join-Path $wc 'plugins/agentic-board/scripts') -Force | Out-Null
        Set-Content (Join-Path $wc 'plugins/agentic-board/scripts/New-BoardPR.ps1') '# stub'
        $r = Resolve-BriefingScriptRef -Name 'New-BoardPR.ps1' -WorkPath $wc -ScriptsDir $script:ScriptsDir
        $r.ref   | Should -Be 'plugins/agentic-board/scripts/New-BoardPR.ps1'
        $r.found | Should -BeTrue
    }
    It 'reports found = $false when neither place has it' {
        $r = Resolve-BriefingScriptRef -Name 'Nope.ps1' -WorkPath $TestDrive -ScriptsDir $TestDrive
        $r.found | Should -BeFalse
    }
}
