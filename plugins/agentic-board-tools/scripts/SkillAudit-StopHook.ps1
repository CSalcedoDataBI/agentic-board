<#  SkillAudit-StopHook.ps1 — passive, suggest-only skill health nudge (Phase 2).

    Meant to be wired as a Claude Code Stop hook (OPT-IN — see
    skills/skills-audit/references/stop-hook.md). On each stop it runs a fast static
    audit of the CURRENT repo's project skills and, IF there are findings, appends ONE
    suggestion line to <Root>/.agentic-board/skill-suggestions.jsonl (gitignored, local).

    It NEVER opens an issue, NEVER edits a skill, NEVER blocks, and NEVER throws — a Stop
    hook that errors would disrupt the session. It only leaves a breadcrumb suggesting the
    user run `/skills audit`. The human stays in the loop; this is the passive capture, not
    the action.

    Exits 0 always. Emits nothing to stdout unless -Verbose.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Quiet
)

try {
    $audit = Join-Path $PSScriptRoot 'Invoke-SkillAudit.ps1'
    if (-not (Test-Path $audit)) { return }

    $res = & $audit -Root $Root -Scope project 2>$null
    if (-not $res -or $res.summary.findings -le 0) { return }

    # The single resolver for the internal state dir (new name + migration + fallback).
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir -Root $Root
    $line = [pscustomobject]@{
        time     = (Get-Date).ToString('s')
        findings = $res.summary.findings
        high     = $res.summary.high
        med      = $res.summary.med
        low      = $res.summary.low
        hint     = 'run /skills audit to review and (with your OK) file sanitized issues'
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $dir 'skill-suggestions.jsonl') -Value $line -Encoding utf8

    if (-not $Quiet) {
        Write-Host "skills-ops: $($res.summary.findings) skill finding(s) — run /skills audit." -ForegroundColor DarkYellow
    }
}
catch {
    # Suggest-only: swallow everything. A Stop hook must never fail the session,
    # so any error here is intentionally ignored and the script completes with 0.
}
