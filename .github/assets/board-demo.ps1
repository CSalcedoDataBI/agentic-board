#!/usr/bin/env pwsh
# board-demo.ps1 — scripted playback for the README hero GIF (issue #210).
#
# This is NOT a live Claude Code session: it reproduces, with simulated typing,
# the exact commands a user runs to INSTALL and USE agentic-board. The commands
# shown are the real ones; only the execution is a scripted reproduction so the
# recording is deterministic. Recorded by board-work.tape via VHS.

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

$green = 'Green'; $dim = 'DarkGray'; $soft = 'Gray'; $white = 'White'

function P {                               # Claude Code-style prompt
    Write-Host ''
    Write-Host -NoNewline '❯ ' -ForegroundColor Magenta
}
function T([string]$t, [int]$ms = 34) {    # "type" a command, char by char
    foreach ($c in $t.ToCharArray()) {
        Write-Host -NoNewline $c -ForegroundColor White
        Start-Sleep -Milliseconds $ms
    }
    Write-Host ''
}
function Pause([int]$ms) { Start-Sleep -Milliseconds $ms }

Clear-Host
Pause 450

# ── 1. Install ────────────────────────────────────────────────
P; T '/plugin marketplace add CSalcedoDataBI/agentic-board'
Pause 250
Write-Host '  ✓ marketplace added' -ForegroundColor $dim
Pause 600

P; T '/plugin install agentic-board'
Pause 350

# ── 2. Banner splash ──────────────────────────────────────────
Write-Host ''
Write-Host '   ▄▀█ █▀▀ █▀▀ █▄░█ ▀█▀ █ █▀▀   █▄▄ █▀█ ▄▀█ █▀█ █▀▄' -ForegroundColor $green
Write-Host '   █▀█ █▄█ ██▄ █░▀█ ░█░ █ █▄▄   █▄█ █▄█ █▀█ █▀▄ █▄▀' -ForegroundColor $green
Write-Host ''
Write-Host '   Run coding agents off your real GitHub Projects board.' -ForegroundColor $soft
Write-Host '   ✓ installed  ·  16 board commands  ·  type ' -NoNewline -ForegroundColor $dim
Write-Host '/board' -NoNewline -ForegroundColor $green
Write-Host ' to begin' -ForegroundColor $dim
Pause 1100

# ── 3. Usage ──────────────────────────────────────────────────
P; T '/board'
Pause 300
Write-Host ''
Write-Host '  agentic-board · what do you want to do?' -ForegroundColor $white
Write-Host ''
$rows = @(
    @('work',    'pick the next issue → branch → PR → review gate → merge'),
    @('plan',    'turn a plan into a tracked epic + native sub-issues'),
    @('fill',    'detect & fix board gaps — status, priority, size, type'),
    @('field',   'apply field presets · bulk-fill any field by rule'),
    @('handoff', 'save / resume context across sessions')
)
foreach ($r in $rows) {
    Write-Host ('    {0,-10}' -f $r[0]) -NoNewline -ForegroundColor $green
    Write-Host $r[1] -ForegroundColor $soft
    Pause 130
}
Write-Host ''
Write-Host '  → or just say it:  ' -NoNewline -ForegroundColor $dim
Write-Host '"what''s pending?"   "start #42"   "move these to Done"' -ForegroundColor $white
Pause 1700
