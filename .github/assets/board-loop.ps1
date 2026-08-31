#!/usr/bin/env pwsh
# board-loop.ps1 — scripted playback for the SECOND README GIF (issue #210).
#
# Shows agentic-board IN USE: the natural-language work loop
#   ask what's pending → start an issue → open a review-gated PR → merge to Done.
# Not a live session; simulated typing, deterministic. Recorded by board-loop.tape.

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

function P {                               # Claude Code-style prompt
    Write-Host ''
    Write-Host -NoNewline '❯ ' -ForegroundColor Magenta
}
function T([string]$t, [int]$ms = 34) {    # "type" a request, char by char
    foreach ($c in $t.ToCharArray()) {
        Write-Host -NoNewline $c -ForegroundColor White
        Start-Sleep -Milliseconds $ms
    }
    Write-Host ''
}
function Pause([int]$ms) { Start-Sleep -Milliseconds $ms }
function OK([string]$t) {
    Write-Host '   ' -NoNewline
    Write-Host '✓ ' -NoNewline -ForegroundColor Green
    Write-Host $t -ForegroundColor Gray
}

Clear-Host
Pause 450

# ── 1. Ask what's pending (plain language) ────────────────────
P; T "what's pending on my board?"
Pause 300
Write-Host ''
Write-Host '  Pending · board #13' -ForegroundColor Cyan
Write-Host ''
Write-Host '    #17   ' -NoNewline -ForegroundColor Green; Write-Host 'M4.1 — Release checklist spec for BI artifacts' -ForegroundColor White
Write-Host '    #16   ' -NoNewline -ForegroundColor Green; Write-Host 'M3.3 — Review-gate workflow: block merge on BPA failures' -ForegroundColor White
Write-Host '    #207  ' -NoNewline -ForegroundColor Green; Write-Host 'plan: discoverability & adoption' -ForegroundColor White
Pause 1200

# ── 2. Start it ───────────────────────────────────────────────
P; T 'start #17'
Pause 300
OK '#17  →  In Progress  ·  assigned to you'
OK 'branch  issue-17-m4-1-release-checklist-spec-for-bi'
Pause 1100

# ── 3. PR → review gate → merge ───────────────────────────────
P; T "it's ready — open the PR"
Pause 300
OK 'pushed  ·  PR #312 opened  ·  Closes #17'
Write-Host '   running review gate…' -ForegroundColor DarkGray
Pause 550; OK 'Copilot review requested'
Pause 480; OK 'CI checks green'
Pause 480; OK 'no unresolved threads'
Pause 550
Write-Host '   ' -NoNewline
Write-Host '✓ merged' -NoNewline -ForegroundColor Green
Write-Host ' (squash)  ·  branch deleted  ·  ' -NoNewline -ForegroundColor Gray
Write-Host '#17 → Done' -ForegroundColor Cyan
Pause 1900
