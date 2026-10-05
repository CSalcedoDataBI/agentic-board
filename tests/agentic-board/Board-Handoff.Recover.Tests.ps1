#Requires -Modules Pester
<#  Pester tests for Board-Handoff.ps1 -Recover (#730): rebuilding a session that ended without
    -Save from its local Claude Code transcript.

    The pure helpers are exercised through the dot-source guard, on small synthetic .jsonl
    fixtures under $TestDrive - never a real transcript. The end-to-end cases run the script in a
    child pwsh inside a throw-away git repo with -ProjectsRoot pointing at $TestDrive, so nothing
    reads ~/.claude and -Recover needs no token and no network. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Board-Handoff.ps1' | Resolve-Path
    $env:ABIOS_HANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_DOTSOURCE = ''

    # One transcript line per call, shaped like Claude Code's own entries.
    function New-UserLine([string]$Text, [string]$Ts = '2026-10-01T10:00:00Z') {
        @{ type = 'user'; timestamp = $Ts; gitBranch = 'issue-42-thing'; cwd = 'X'
           message = @{ role = 'user'; content = $Text } } | ConvertTo-Json -Depth 8 -Compress
    }
    function New-UserBlocksLine([object[]]$Blocks) {
        @{ type = 'user'; timestamp = '2026-10-01T10:00:00Z'; message = @{ role = 'user'; content = $Blocks } } |
            ConvertTo-Json -Depth 8 -Compress
    }
    function New-ToolResultLine {
        @{ type = 'user'; timestamp = '2026-10-01T10:00:01Z'; toolUseResult = @{ stdout = 'SECRET TOOL OUTPUT' }
           message = @{ role = 'user'; content = @(@{ type = 'tool_result'; content = 'SECRET TOOL OUTPUT' }) } } |
            ConvertTo-Json -Depth 8 -Compress
    }
    function New-AssistantLine([string]$Text) {
        @{ type = 'assistant'; timestamp = '2026-10-01T10:00:02Z'; gitBranch = 'issue-42-thing'
           message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }, @{ type = 'tool_use'; name = 'Bash'; input = @{ command = 'TOOL CMD' } }) } } |
            ConvertTo-Json -Depth 8 -Compress
    }
    function Write-Jsonl([string]$Path, [string[]]$Lines) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        return (Get-Item -LiteralPath $Path)
    }
}

Describe 'Get-TranscriptSlugCandidates' {
    It 'maps a Windows repo path to Claude Code''s project folder name' {
        Get-TranscriptSlugCandidates 'D:\MIS-REPO\agentic-board' | Should -Contain 'D--MIS-REPO-agentic-board'
    }
    It 'gives the same slug for the forward-slash form git prints' {
        Get-TranscriptSlugCandidates 'D:/MIS-REPO/agentic-board' | Should -Contain 'D--MIS-REPO-agentic-board'
    }
    It 'offers both the full and the narrow rule when the path has other punctuation' {
        $s = @(Get-TranscriptSlugCandidates '/home/u/my_repo.v2')
        $s | Should -Contain '-home-u-my-repo-v2'
        $s | Should -Contain '-home-u-my_repo.v2'
    }
    It 'returns nothing for an empty path' {
        @(Get-TranscriptSlugCandidates '').Count | Should -Be 0
    }
}

Describe 'Find-RecoverTranscript' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'projects'
        $slugDir = Join-Path $script:Root 'C--work-repo'
        $old = Write-Jsonl (Join-Path $slugDir 'old-session.jsonl') @(New-UserLine 'old')
        $mid = Write-Jsonl (Join-Path $slugDir 'lost-session.jsonl') @(New-UserLine 'lost')
        $cur = Write-Jsonl (Join-Path $slugDir 'current-session.jsonl') @(New-UserLine 'current')
        $script:Now = [datetime]'2026-10-02T12:00:00Z'
        $old.LastWriteTimeUtc = $script:Now.AddDays(-2)
        $mid.LastWriteTimeUtc = $script:Now.AddHours(-3)
        $cur.LastWriteTimeUtc = $script:Now.AddSeconds(-10)
        # Another repo's transcript, newer than all of them: must never be picked.
        $other = Write-Jsonl (Join-Path $script:Root 'C--work-other' 'zzz.jsonl') @(New-UserLine 'other')
        $other.LastWriteTimeUtc = $script:Now
    }
    It 'picks the newest transcript of THIS slug, excluding the running session id' {
        $r = Find-RecoverTranscript -ProjectsRoot $script:Root -Slugs 'C--work-repo' -ExcludeSessionId 'current-session' -Now $script:Now
        $r.File.BaseName | Should -BeExactly 'lost-session'
        $r.Skipped       | Should -BeExactly 'current-session'
        $r.Considered    | Should -Be 3
    }
    It 'without an id, skips the newest file only when it is being written right now' {
        $r = Find-RecoverTranscript -ProjectsRoot $script:Root -Slugs 'C--work-repo' -ExcludeNewestIfLive -Now $script:Now
        $r.File.BaseName | Should -BeExactly 'lost-session'
    }
    It 'without an id and with a stale newest file, the newest IS the lost session' {
        $r = Find-RecoverTranscript -ProjectsRoot $script:Root -Slugs 'C--work-repo' -ExcludeNewestIfLive -Now $script:Now.AddHours(1)
        $r.File.BaseName | Should -BeExactly 'current-session'
    }
    It 'returns no file (not an error) when the slug has no folder' {
        $r = Find-RecoverTranscript -ProjectsRoot $script:Root -Slugs 'C--nowhere' -Now $script:Now
        $r.File | Should -BeNullOrEmpty
        $r.Considered | Should -Be 0
    }
    It 'returns no file when the projects root itself is missing' {
        (Find-RecoverTranscript -ProjectsRoot (Join-Path $TestDrive 'nope') -Slugs 'x').File | Should -BeNullOrEmpty
    }
    It 'returns no file when the only transcript is the running session' {
        $solo = Join-Path $TestDrive 'solo'
        $null = Write-Jsonl (Join-Path $solo 'S' 'me.jsonl') @(New-UserLine 'me')
        (Find-RecoverTranscript -ProjectsRoot $solo -Slugs 'S' -ExcludeSessionId 'me').File | Should -BeNullOrEmpty
    }
}

Describe 'Read-TranscriptDigest' {
    It 'keeps real user turns and drops harness noise and tool results' {
        $f = Write-Jsonl (Join-Path $TestDrive 'd1' 'a.jsonl') @(
            (New-UserLine 'Implement the checkpoint for 771')
            (New-UserLine '<system-reminder>global rules here</system-reminder>')
            (New-UserLine '   <task-notification>done</task-notification>')
            (New-ToolResultLine)
            (New-UserBlocksLine @(@{ type = 'text'; text = 'and add tests' }, @{ type = 'tool_result'; content = 'x' }))
            (@{ type = 'user'; isMeta = $true; message = @{ role = 'user'; content = 'Caveat: meta' } } | ConvertTo-Json -Compress -Depth 5)
            (New-AssistantLine "Done.`n`nPR opened and merged.")
            '{"type":"user", this line is truncated json'
            (@{ type = 'summary'; summary = 'compacted' } | ConvertTo-Json -Compress)
        )
        $d = Read-TranscriptDigest -Path $f.FullName
        @($d.UserTurns.text) | Should -Be @('Implement the checkpoint for 771', 'and add tests')
        ($d.UserTurns.text -join ' ') | Should -Not -Match 'system-reminder|task-notification|SECRET|Caveat'
        @($d.AssistantLines) | Should -Be @('Done.', 'PR opened and merged.')
        ($d.AssistantLines -join ' ') | Should -Not -Match 'TOOL CMD'
        $d.Malformed | Should -Be 1
        $d.LinesRead | Should -Be 9
        $d.GitBranch | Should -BeExactly 'issue-42-thing'
        $d.SessionId | Should -BeExactly 'a'
    }
    It 'keeps only the last N user turns, truncated, and the last N assistant lines' {
        $lines = @()
        foreach ($i in 1..30) { $lines += New-UserLine ("turn $i " + ('x' * 300)) }
        $lines += New-AssistantLine ((1..60 | ForEach-Object { "line $_" }) -join "`n")
        $f = Write-Jsonl (Join-Path $TestDrive 'd2' 'b.jsonl') $lines
        $d = Read-TranscriptDigest -Path $f.FullName -MaxUserTurns 20 -MaxChars 200 -MaxAssistantLines 45
        @($d.UserTurns).Count | Should -Be 20
        $d.UserTurns[0].text  | Should -Match '^turn 11 '
        $d.UserTurns[-1].text | Should -Match '^turn 30 '
        $d.UserTurns[0].text.Length | Should -Be 200
        $d.UserTurns[0].text  | Should -Match '\.\.\.$'
        @($d.AssistantLines).Count | Should -Be 45
        $d.AssistantLines[0]  | Should -BeExactly 'line 16'
        $d.AssistantLines[-1] | Should -BeExactly 'line 60'
    }
    It 'streams: never loads the whole file (no Get-Content, no ReadAllText/ReadAllLines)' {
        Mock Get-Content { throw 'Read-TranscriptDigest must stream, not Get-Content' }
        $f = Write-Jsonl (Join-Path $TestDrive 'd3' 'c.jsonl') @((New-UserLine 'hello'), (New-AssistantLine 'bye'))
        { Read-TranscriptDigest -Path $f.FullName } | Should -Not -Throw
        Should -Invoke Get-Content -Times 0 -Exactly
        $src = (Get-Command Read-TranscriptDigest).ScriptBlock.ToString()
        $src | Should -Not -Match 'ReadAllText|ReadAllLines|ReadToEnd|Get-Content'
        $src | Should -Match 'ReadLine\(\)'
    }
    It 'reads a transcript that another process still holds open for writing' {
        $p = Join-Path $TestDrive 'd4' 'live.jsonl'
        $null = Write-Jsonl $p @(New-UserLine 'still going')
        $w = [IO.FileStream]::new($p, 'Open', 'Write', 'ReadWrite')
        try { (Read-TranscriptDigest -Path $p).UserTurns[0].text | Should -BeExactly 'still going' }
        finally { $w.Dispose() }
    }
    It 'an empty transcript gives an empty digest, not an error' {
        $p = Join-Path $TestDrive 'd5' 'empty.jsonl'
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        New-Item -ItemType File -Path $p | Out-Null
        $d = Read-TranscriptDigest -Path $p
        @($d.UserTurns).Count | Should -Be 0
        @($d.AssistantLines).Count | Should -Be 0
    }
}

Describe 'Format-RecoverReport' {
    BeforeAll {
        $script:Digest = [pscustomobject]@{
            Path = 'p'; SessionId = 'lost'; LinesRead = 10; Malformed = 0; LastTimestamp = '2026-10-01T10:00:00Z'
            GitBranch = 'issue-42-thing'; Cwd = ''
            UserTurns = @([pscustomobject]@{ at = ''; text = 'ship it' })
            AssistantLines = @('Merged PR #9 and deployed.')
        }
    }
    It 'separates ATTEMPTED (transcript) from LANDED (git) and never upgrades a claim to a fact' {
        $out = (Format-RecoverReport -Digest $script:Digest -Branch 'issue-42-thing' -StatusLines @('## issue-42-thing...origin/issue-42-thing [ahead 2]', ' M a.ps1') `
                    -Upstream 'origin/issue-42-thing' -Ahead 2 -Behind 0 -LogLines @('abc123 feat: x')) -join "`n"
        $out | Should -Match 'ATTEMPTED'
        $out | Should -Match 'LANDED'
        $out | Should -Match 'Do not report a merge,'
        $out | Should -Match '2 local commit\(s\) are NOT pushed'
        $out | Should -Match '1 uncommitted change'
        $out | Should -Match '> ship it'
        $out | Should -Match '\| Merged PR #9 and deployed\.'
        $out | Should -Match 'Board-Handoff\.ps1 -Save'
        $out.IndexOf('ATTEMPTED') | Should -BeLessThan $out.IndexOf('LANDED')
    }
    It 'says plainly when the branch has no upstream' {
        (Format-RecoverReport -Digest $script:Digest -Branch 'issue-42-thing') -join "`n" | Should -Match 'nothing on this branch is pushed'
    }
    It 'flags that the lost session was on another branch' {
        (Format-RecoverReport -Digest $script:Digest -Branch 'main') -join "`n" | Should -Match "was on 'issue-42-thing'; you are on 'main'"
    }
}

Describe 'Board-Handoff.ps1 -Recover end to end (child pwsh, no token, no network)' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init --quiet 2>&1 | Out-Null
        git -C $script:Repo config user.email 't@example.com'
        git -C $script:Repo config user.name 't'
        git -C $script:Repo config commit.gpgsign false
        git -C $script:Repo commit --allow-empty --quiet -m 'feat: first' 2>&1 | Out-Null
        $top = (git -C $script:Repo rev-parse --show-toplevel).Trim()
        $script:Projects = Join-Path $TestDrive 'cc-projects'
        $script:SlugDir = Join-Path $script:Projects (@(Get-TranscriptSlugCandidates $top)[0])

        function Invoke-Recover([string[]]$Extra = @()) {
            $psi = @('-NoProfile', '-File', $script:Script, '-Recover', '-ProjectsRoot', $script:Projects) + $Extra
            Push-Location $script:Repo
            try {
                $saved = @{}
                foreach ($v in 'GH_TOKEN', 'GITHUB_TOKEN', 'CLAUDE_CODE_SESSION_ID', 'CLAUDECODE') { $saved[$v] = [Environment]::GetEnvironmentVariable($v); [Environment]::SetEnvironmentVariable($v, $null) }
                $out = & pwsh @psi 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
                Pop-Location
            }
            [pscustomobject]@{ Out = $out; Code = $code }
        }
    }
    It 'handles "no transcript" gracefully: exit 0, a clear message, no token needed' {
        $r = Invoke-Recover
        $r.Code | Should -Be 0
        $r.Out  | Should -Match 'No earlier session transcript found'
        $r.Out  | Should -Match 'same machine'
    }
    It 'recovers the lost session, skips the current one, and crosses it with live git' {
        $lost = Write-Jsonl (Join-Path $script:SlugDir 'lost-1.jsonl') @(
            (New-UserLine 'please finish issue 42')
            (New-UserLine '<system-reminder>noise</system-reminder>')
            (New-AssistantLine 'I merged the PR.')
        )
        $lost.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
        $cur = Write-Jsonl (Join-Path $script:SlugDir 'running-2.jsonl') @(New-UserLine 'recover my last session')
        $r = Invoke-Recover @('-ExcludeSessionId', 'running-2')
        $r.Code | Should -Be 0
        $r.Out  | Should -Match 'lost-1'
        $r.Out  | Should -Match 'please finish issue 42'
        $r.Out  | Should -Not -Match 'recover my last session'
        $r.Out  | Should -Not -Match 'noise'
        $r.Out  | Should -Match 'I merged the PR\.'
        $r.Out  | Should -Match 'feat: first'
        $r.Out  | Should -Match 'nothing on this branch is pushed'
        $r.Out  | Should -Match 'git and the forge say what LANDED'
        $r.Out  | Should -Match '-Save'
    }
}
