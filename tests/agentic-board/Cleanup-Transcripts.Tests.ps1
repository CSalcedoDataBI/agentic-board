#Requires -Modules Pester
<#  Pester tests for Cleanup-Transcripts.ps1 - `/cleanup transcripts` (#736).

    Old session transcripts (~/.claude/projects/<project>/<sessionId>.jsonl, plus the companion
    <sessionId>/ folder of tool results and subagents) fill the disk. They are compressed into an
    indexed archive and can be restored byte for byte. Two properties matter more than the space:
      * a transcript the app still SHOWS (a session that is not archived there) is never touched -
        compressing it would leave a session in the sidebar that cannot be opened;
      * the original is deleted only after the zip has been read back and matches it (SHA-256).
    The pure rules are asserted over plain objects; the compress/restore round trip runs on real
    files in a throwaway folder. #>

BeforeAll {
    $env:ABIOS_TRANSCRIPTS_DOTSOURCE = '1'
    try { . (Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Cleanup-Transcripts.ps1' | Resolve-Path) }
    finally { $env:ABIOS_TRANSCRIPTS_DOTSOURCE = '' }
    $script:Now = [datetime]::SpecifyKind([datetime]'2026-09-29T12:00:00', 'Utc')
    function script:T {
        param([string]$Id = 'a1', [int]$Days = 60, [long]$Bytes = 1000, [string]$Entrypoint = 'cli')
        [pscustomobject]@{ SessionId = $Id; LastWriteUtc = $script:Now.AddDays(-$Days); Bytes = $Bytes; Entrypoint = $Entrypoint }
    }
    function script:V {
        param($T, [string[]]$Live = @(), [hashtable]$App = @{}, [int]$Older = 30, [bool]$AppKnown = $true)
        Get-TranscriptVerdict -Transcript $T -Now $script:Now -OlderThanDays $Older -LiveIds $Live -AppSessions $App -AppIndexComplete $AppKnown
    }
}

Describe 'Get-TranscriptVerdict - which transcripts may be compressed' {
    It 'archives an old transcript of an archived app session' {
        $v = script:V (script:T -Id 'a1') -App @{ 'a1' = [pscustomobject]@{ IsArchived = $true; Title = 'Old work' } }
        $v.Archive | Should -BeTrue
        $v.Reason | Should -Match 'archived in the app'
    }
    It 'NEVER archives a transcript the app still shows - that session would no longer open' {
        $v = script:V (script:T -Id 'a1') -App @{ 'a1' = [pscustomobject]@{ IsArchived = $false; Title = 'Still listed' } }
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'still (listed|shown) in the app'
    }
    It 'never archives the transcript of a session that is running' {
        (script:V (script:T -Id 'a1') -Live @('a1')).Archive | Should -BeFalse
    }
    It 'keeps anything younger than the threshold' {
        $v = script:V (script:T -Days 10) -Older 30
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'recent'
    }
    It 'archives an old command-line transcript the app never knew about' {
        $v = script:V (script:T -Entrypoint 'cli')
        $v.Archive | Should -BeTrue
        $v.Reason | Should -Match 'not an app session'
    }
    It 'fails closed on an app session it could not map when the app index was only partly readable' {
        $v = script:V (script:T -Entrypoint 'claude-desktop') -AppKnown $false
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'could not'
    }
    It 'archives an unmapped desktop transcript when the app index was read completely - the app has no session for it' {
        (script:V (script:T -Entrypoint 'claude-desktop') -AppKnown $true).Archive | Should -BeTrue
    }
}

Describe 'Get-TranscriptMeta - what the index remembers about a transcript' {
    It 'reads cwd, branch, first/last timestamp and the latest custom title' {
        $lines = @(
            '{"type":"queue-operation","sessionId":"s1","timestamp":"2026-08-01T10:00:00Z"}'
            '{"type":"user","sessionId":"s1","cwd":"D:\\r\\app","gitBranch":"issue-42-fix","entrypoint":"claude-desktop","timestamp":"2026-08-01T10:00:05Z"}'
            'not json at all'
            '{"type":"custom-title","customTitle":"First title","timestamp":"2026-08-01T10:01:00Z"}'
            '{"type":"custom-title","customTitle":"Better title","timestamp":"2026-08-02T09:00:00Z"}'
        )
        $m = Get-TranscriptMeta -Head $lines -Tail $lines
        $m.Cwd | Should -Be 'D:\r\app'
        $m.GitBranch | Should -Be 'issue-42-fix'
        $m.Issue | Should -Be 42
        $m.Title | Should -Be 'Better title'
        $m.Entrypoint | Should -Be 'claude-desktop'
        $m.FirstTs | Should -Be '2026-08-01T10:00:00Z'
        $m.LastTs | Should -Be '2026-08-02T09:00:00Z'
    }
    It 'survives a transcript with no usable line' {
        $m = Get-TranscriptMeta -Head @('garbage') -Tail @()
        $m.Cwd | Should -BeNullOrEmpty
        $m.Issue | Should -Be 0
    }
}

Describe 'Get-ThresholdSavings - how much each age threshold would free' {
    It 'sums only what is eligible besides age, per threshold' {
        $ts = @(
            [pscustomobject]@{ Days = 5;  Bytes = 100; Blocked = $false }
            [pscustomobject]@{ Days = 20; Bytes = 200; Blocked = $false }
            [pscustomobject]@{ Days = 40; Bytes = 400; Blocked = $false }
            [pscustomobject]@{ Days = 90; Bytes = 800; Blocked = $true }
        )
        $s = @(Get-ThresholdSavings -Rows $ts -Days @(7, 30))
        ($s | Where-Object Days -eq 7).Bytes | Should -Be 600
        ($s | Where-Object Days -eq 30).Bytes | Should -Be 400
    }
}

Describe 'Compress-Transcript / Restore-Transcript - a real round trip' {
    BeforeEach {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("abios-tr-" + [guid]::NewGuid().ToString('N'))
        $script:Proj = Join-Path $script:Root 'projects\D--r-app'
        $script:Arch = Join-Path $script:Root 'archive'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Proj 's1\tool-results') | Out-Null
        $script:Jsonl = Join-Path $script:Proj 's1.jsonl'
        # Not ASCII on purpose: the round trip must be byte-identical, not "text-equivalent".
        [IO.File]::WriteAllText($script:Jsonl, ('{"type":"user","cwd":"D:\\r\\app","text":"migración ñ ✓"}' + "`n") * 200, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $script:Proj 's1\tool-results\r.txt'), 'tool output')
        $script:Sha = (Get-FileHash $script:Jsonl -Algorithm SHA256).Hash
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'compresses the transcript and its companion folder, verifies, then removes the originals' {
        $r = Compress-Transcript -JsonlPath $script:Jsonl -ArchiveDir $script:Arch -Meta ([pscustomobject]@{ Title = 't' })
        $r.Ok | Should -BeTrue
        Test-Path $script:Jsonl | Should -BeFalse
        Test-Path (Join-Path $script:Proj 's1') | Should -BeFalse
        Test-Path $r.ZipPath | Should -BeTrue
        $r.Sha256 | Should -Be $script:Sha
        (Get-Item $r.ZipPath).Length | Should -BeLessThan (200 * 60)
    }
    It 'restores it byte for byte, companion folder included' {
        $c = Compress-Transcript -JsonlPath $script:Jsonl -ArchiveDir $script:Arch -Meta ([pscustomobject]@{})
        $r = Restore-Transcript -ZipPath $c.ZipPath -JsonlPath $script:Jsonl -Sha256 $c.Sha256
        $r.Ok | Should -BeTrue
        (Get-FileHash $script:Jsonl -Algorithm SHA256).Hash | Should -Be $script:Sha
        Get-Content (Join-Path $script:Proj 's1\tool-results\r.txt') -Raw | Should -Be 'tool output'
        Test-Path $c.ZipPath | Should -BeFalse
    }
    It 'refuses to overwrite a transcript that came back to life at the original path' {
        $c = Compress-Transcript -JsonlPath $script:Jsonl -ArchiveDir $script:Arch -Meta ([pscustomobject]@{})
        [IO.File]::WriteAllText($script:Jsonl, 'new content')
        $r = Restore-Transcript -ZipPath $c.ZipPath -JsonlPath $script:Jsonl -Sha256 $c.Sha256
        $r.Ok | Should -BeFalse
        Get-Content $script:Jsonl -Raw | Should -Be 'new content'
        Test-Path $c.ZipPath | Should -BeTrue
    }
    It 'keeps the original when the archive cannot be verified' {
        $r = Compress-Transcript -JsonlPath $script:Jsonl -ArchiveDir $script:Arch -Meta ([pscustomobject]@{}) -VerifyHook { param($zip) 'deadbeef' }
        $r.Ok | Should -BeFalse
        Test-Path $script:Jsonl | Should -BeTrue
        Test-Path (Join-Path $script:Proj 's1\tool-results\r.txt') | Should -BeTrue
    }
}
