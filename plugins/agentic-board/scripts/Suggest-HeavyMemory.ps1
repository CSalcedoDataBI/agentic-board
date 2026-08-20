<#  Suggest-HeavyMemory.ps1 - the security-gated "heavy memory" escalation (#143).

    The lightweight, git-committed HANDOFF.md is the DEFAULT. For the HEAVY case only -
    persistent SEMANTIC memory across projects - this script does NOT reinvent memory
    infrastructure; it proposes installing a reliable existing tool, **Basic Memory**
    (local Markdown + SQLite, exposed over MCP), from its official upstream.

    HARD RULE (license): Basic Memory is AGPL-3.0 (strong copyleft). We stay clean ONLY by
    installing from upstream and talking to it over MCP (a separate process = mere
    aggregation). This script NEVER vendors, forks, or copies Basic Memory's source - doing
    so would force agentic-board itself to become AGPL.

    Default run = PROPOSAL only: live provenance check against PyPI + the security checklist
    + the exact pinned commands. It installs nothing. `-Install` performs the guarded install
    but REQUIRES `-AcceptAgpl` (the explicit human gate) and pins an exact version.

    Dot-source guard: set $env:ABIOS_HEAVYMEM_DOTSOURCE=1 to load the pure helpers for Pester
    without any network call or install side effect.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$AcceptAgpl,
    [string]$Version = "",
    [string]$McpConfig = ""
)

# ==============================================================================
# Pure helpers (unit-testable; no network, no install, no file writes)
# ==============================================================================

$script:HeavyMemPackage = "basic-memory"
$script:HeavyMemRepo    = "basicmachines-co/basic-memory"

# Given a PyPI `info` object (from /pypi/<pkg>/json), verify provenance: the canonical
# package name (anti-typosquatting) and that the license really is AGPL. Returns a
# normalized result object - never throws.
function Test-BasicMemoryProvenance($info) {
    $name    = if ($info -and $info.name) { [string]$info.name } else { "" }
    $version = if ($info -and $info.version) { [string]$info.version } else { "" }
    $license = if ($info -and $info.license) { [string]$info.license } else { "" }
    $classifiers = @()
    if ($info -and $info.classifiers) { $classifiers = @($info.classifiers) }
    $isAgpl = ($license -match '(?i)AGPL') -or (@($classifiers | Where-Object { $_ -match '(?i)Affero' }).Count -gt 0)
    return [pscustomobject]@{
        nameOk  = ($name.ToLower() -eq $script:HeavyMemPackage)
        name    = $name
        version = $version
        isAgpl  = [bool]$isAgpl
        license = if ($license) { $license } elseif ($isAgpl) { "AGPL-3.0 (from classifiers)" } else { "unknown" }
    }
}

# The pinned install invocation (exact version, isolated env) as exe + explicit arg array,
# so the tool never receives quotes-as-literals from a split string. NEVER a floating range.
# uv is preferred; pipx is the fallback.
function Get-HeavyMemoryInstallInvocation([string]$version, [string]$manager = "uv") {
    if (-not $version) { return $null }
    if ($manager -eq "pipx") {
        return [pscustomobject]@{ exe = "pipx"; args = @("install", "$script:HeavyMemPackage==$version") }
    }
    return [pscustomobject]@{ exe = "uv"; args = @("tool", "install", "$script:HeavyMemPackage==$version") }
}

# Human-readable form of the pinned install command (display only).
function Get-HeavyMemoryInstallCommand([string]$version, [string]$manager = "uv") {
    $inv = Get-HeavyMemoryInstallInvocation $version $manager
    if (-not $inv) { return "" }
    return ("$($inv.exe) " + (($inv.args | ForEach-Object { if ($_ -match '==') { "`"$_`"" } else { $_ } }) -join ' '))
}

# The .mcp.json server entry that runs the MCP server from the PINNED version. The command
# MUST match the manager actually used to install, or .mcp.json would point at a missing exe.
#   uv   -> uvx --from basic-memory==<v> basic-memory mcp
#   pipx -> pipx run --spec basic-memory==<v> basic-memory mcp
function New-BasicMemoryMcpEntry([string]$version, [string]$manager = "uv") {
    if ($manager -eq "pipx") {
        return [ordered]@{
            command = "pipx"
            args    = @("run", "--spec", "$script:HeavyMemPackage==$version", $script:HeavyMemPackage, "mcp")
        }
    }
    return [ordered]@{
        command = "uvx"
        args    = @("--from", "$script:HeavyMemPackage==$version", $script:HeavyMemPackage, "mcp")
    }
}

# Upsert a named server into an .mcp.json body under mcpServers. Idempotent (replaces the
# same key). Returns pretty JSON. Accepts an empty/missing body.
function Add-McpServerEntry([string]$jsonBody, [string]$name, $entry) {
    $root = $null
    if ($jsonBody -and $jsonBody.Trim()) { try { $root = $jsonBody | ConvertFrom-Json } catch { $root = $null } }
    if (-not $root) { $root = [pscustomobject]@{} }
    if (-not ($root.PSObject.Properties.Name -contains 'mcpServers') -or -not $root.mcpServers) {
        $root | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $root.mcpServers | Add-Member -NotePropertyName $name -NotePropertyValue $entry -Force
    return ($root | ConvertTo-Json -Depth 10)
}

# ==============================================================================
# Main. Dot-source guard for tests.
# ==============================================================================
if ($env:ABIOS_HEAVYMEM_DOTSOURCE) { return }

$ErrorActionPreference = "Stop"

Write-Host "=== Heavy-memory escalation (Basic Memory) - security-gated proposal ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "The default is the lightweight HANDOFF.md. This is ONLY for persistent semantic" -ForegroundColor Gray
Write-Host "memory across projects. We install a reliable existing tool, never reinvent it." -ForegroundColor Gray
Write-Host ""

# -- Provenance: live PyPI lookup ---------------------------------------------
$prov = $null
try {
    $pypi = Invoke-RestMethod -Uri "https://pypi.org/pypi/$script:HeavyMemPackage/json" -TimeoutSec 15
    $prov = Test-BasicMemoryProvenance $pypi.info
} catch {
    Write-Host "  WARN could not reach PyPI for provenance ($($_.Exception.Message))." -ForegroundColor DarkYellow
}

$provOk = [bool]($prov -and $prov.nameOk -and $prov.isAgpl)
if ($prov) {
    Write-Host "  Provenance (PyPI):" -ForegroundColor Cyan
    Write-Host "    package name matches '$script:HeavyMemPackage' : $($prov.nameOk)  (anti-typosquatting)" -ForegroundColor $(if ($prov.nameOk) { 'Green' } else { 'Red' })
    Write-Host "    latest version                    : $($prov.version)"
    Write-Host "    license                           : $($prov.license)  (AGPL: $($prov.isAgpl))" -ForegroundColor $(if ($prov.isAgpl) { 'Yellow' } else { 'Gray' })
    Write-Host "    upstream                          : https://github.com/$script:HeavyMemRepo"
    if (-not $prov.nameOk) { throw "Provenance FAILED: PyPI package name '$($prov.name)' != '$script:HeavyMemPackage'. Refusing - possible typosquat." }
}
# The pin the user WOULD install: an explicit -Version, else the verified latest (display).
$pin = if ($Version) { $Version } elseif ($prov) { $prov.version } else { "<pin-an-exact-version>" }
Write-Host ""

# -- Detect env managers -------------------------------------------------------
$uv   = Get-Command uv   -ErrorAction SilentlyContinue
$pipx = Get-Command pipx -ErrorAction SilentlyContinue
$mgr  = if ($uv) { "uv" } elseif ($pipx) { "pipx" } else { "" }

# -- AGPL notice + security checklist (reflects ACTUAL verification) -----------
Write-Host "  LICENSE (hard rule): Basic Memory is AGPL-3.0 (strong copyleft)." -ForegroundColor Yellow
Write-Host "    We NEVER vendor/fork its code - we install from upstream and talk over MCP" -ForegroundColor Yellow
Write-Host "    (separate process = mere aggregation). agentic-board stays MIT." -ForegroundColor Yellow
Write-Host ""
function Show-Check([bool]$ok, [string]$text) {
    $mark = if ($ok) { "[x]" } else { "[ ]" }
    Write-Host "    $mark $text" -ForegroundColor $(if ($ok) { 'Gray' } else { 'DarkYellow' })
}
Write-Host "  Security checklist (this run):" -ForegroundColor Cyan
Show-Check ([bool]($prov -and $prov.nameOk)) "provenance: canonical package name verified against PyPI"
Show-Check ([bool]($prov -and $prov.isAgpl)) "license: AGPL confirmed from PyPI metadata"
Show-Check ([bool]$Version) "pinned EXACT version explicitly ($pin) - install refuses a blind 'latest'"
Show-Check ([bool]$mgr) "isolated env available (uv tool / pipx) - no global pip"
Write-Host "    [x] human gate: install requires -Install -AcceptAgpl (no silent install)" -ForegroundColor Gray
Write-Host "    [x] reversible uninstall + update-review, not auto-update (below)" -ForegroundColor Gray
Write-Host ""

$mgrLabel   = if ($mgr) { $mgr } else { "uv" }
$installCmd = Get-HeavyMemoryInstallCommand $pin $mgrLabel
$mcpEntry   = New-BasicMemoryMcpEntry $pin $mgrLabel
$installVia = if ($mgr) { $mgr } else { "uv/pipx once installed" }

Write-Host "  Proposed install (pinned, via $installVia):" -ForegroundColor Cyan
Write-Host "    $installCmd"
Write-Host ""
Write-Host "  Proposed .mcp.json entry (server 'basic-memory', pinned, matches the $mgrLabel install):" -ForegroundColor Cyan
Write-Host ("    " + (($mcpEntry | ConvertTo-Json -Depth 6) -replace "`n", "`n    "))
Write-Host ""
Write-Host "  Reversible uninstall:  $(if ($mgr -eq 'pipx') { 'pipx uninstall' } else { 'uv tool uninstall' }) $script:HeavyMemPackage  +  remove the .mcp.json entry" -ForegroundColor Gray
Write-Host "                         (your .md notes are preserved - data survives)." -ForegroundColor Gray
Write-Host ""

# -- Guarded install -----------------------------------------------------------
if (-not $Install) {
    Write-Host "PROPOSAL ONLY - nothing installed. To proceed, confirm the install (AGPL, version $pin)." -ForegroundColor Cyan
    return [pscustomobject]@{ installed=$false; proposed=$true; version=$pin; provenanceOk=$provOk; agpl=$([bool]($prov -and $prov.isAgpl)) }
}

# Enforce every control before touching the system.
if (-not $AcceptAgpl) {
    throw "Refusing to install without -AcceptAgpl. Basic Memory is AGPL-3.0; pass -AcceptAgpl to confirm you accept installing it from upstream (we never vendor it)."
}
if (-not $Version) {
    throw "Refusing to install without an explicit -Version (no blind 'latest'). Run the proposal to see the verified version, then pin it: -Version $pin."
}
if (-not $provOk) {
    throw "Refusing to install: provenance/AGPL was NOT verified this run (PyPI unreachable or metadata mismatch). Re-run with connectivity so the package name + AGPL license are confirmed first."
}
if (-not $mgr) { throw "Neither 'uv' nor 'pipx' is available - install one first (isolated env is required; no global pip)." }

$inv = Get-HeavyMemoryInstallInvocation $Version $mgr
Write-Host "  Installing $script:HeavyMemPackage==$Version via $mgr ..." -ForegroundColor Cyan
& $inv.exe @($inv.args)   # explicit args - no quotes-as-literals from string splitting
if ($LASTEXITCODE -ne 0) { throw "Install failed ($($inv.exe) $($inv.args -join ' '))." }

# Write the pinned MCP entry (matches the manager used).
if (-not $McpConfig) {
    $root = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if (-not $root) { $root = (Get-Location).Path }
    $McpConfig = Join-Path $root ".mcp.json"
}
$existing = if (Test-Path $McpConfig) { Get-Content $McpConfig -Raw } else { "" }
Set-Content -Path $McpConfig -Value (Add-McpServerEntry $existing "basic-memory" (New-BasicMemoryMcpEntry $Version $mgr)) -Encoding UTF8
Write-Host "  OK  installed and wrote the pinned MCP entry to $McpConfig" -ForegroundColor Green
Write-Host "  Review the server's tools before relying on it; re-pin deliberately on updates." -ForegroundColor Gray
return [pscustomobject]@{ installed=$true; version=$Version; manager=$mgr; mcpConfig=$McpConfig }
