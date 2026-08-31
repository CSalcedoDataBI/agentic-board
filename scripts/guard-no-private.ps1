<#  guard-no-private.ps1 — block private content / secrets from entering this PUBLIC repo.
    Wired as a pre-commit and pre-push git hook (see scripts/install-guard.ps1).
    Scans ONLY the ADDED lines of the change against:
      1. built-in secret patterns (tokens, keys, connection strings)
      2. a local-only denylist: .abios/private-denylist.txt (gitignored, never committed)
    Exits 1 (blocking) if any match is found.  #>
[CmdletBinding()]
param([ValidateSet('commit','push')][string]$Mode = 'commit')

$ErrorActionPreference = 'Stop'

# --- collect the added lines for the relevant change set ---
if ($Mode -eq 'commit') {
    $diff = git diff --cached -U0 --diff-filter=ACM
} else {
    $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    if (-not $upstream) { $upstream = 'origin/main' }
    $diff = git diff -U0 "$upstream..HEAD"
}
if (-not $diff) { exit 0 }

# secret patterns — each leads with a character class so this file never matches its own
# pattern-definition lines (the prefix is not contiguous in the source).
$secretPatterns = @(
    'gh[posru]_[A-Za-z0-9]{30,}',                 # GitHub PATs / tokens
    'github_pat_[A-Za-z0-9_]{20,}',               # fine-grained PAT
    'AKIA[0-9A-Z]{16}',                           # AWS access key id
    'xox[baprs]-[A-Za-z0-9-]{10,}',               # Slack tokens
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',         # private keys
    'AccountKey=[A-Za-z0-9+/=]{20,}',             # Azure storage
    '[S]erver=tcp:[^;]+;.{0,400}Password='        # SQL connection strings
)

# local-only denylist of private fingerprints
$denyTerms = @()
$denyFile = '.abios/private-denylist.txt'
if (Test-Path $denyFile) {
    $denyTerms = Get-Content $denyFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

# --- scan ---
$violations = @()
$currentFile = '(unknown)'
foreach ($line in ($diff -split "`n")) {
    if ($line -match '^\+\+\+ b/(.+)$') { $currentFile = $Matches[1]; continue }
    if ($line -notmatch '^\+' -or $line -match '^\+\+\+') { continue }
    $added = $line.Substring(1)

    foreach ($p in $secretPatterns) {
        if ($added -match $p) { $violations += "  [secret]  $currentFile  — pattern: $p" }
    }
    foreach ($t in $denyTerms) {
        if ($added -like "*$t*") { $violations += "  [private] $currentFile  — term: $t" }
    }
}

if ($violations.Count -gt 0) {
    Write-Host ""
    Write-Host "BLOCKED by agentic-board guard ($Mode): private content / secrets detected." -ForegroundColor Red
    Write-Host "The PUBLIC repo must never receive private project data." -ForegroundColor Red
    Write-Host ""
    $violations | Select-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Fix: abstract the change to the public tool only, or correct .abios/private-denylist.txt." -ForegroundColor Red
    Write-Host "Override (only if you are SURE it is a false positive): git $Mode --no-verify" -ForegroundColor DarkGray
    exit 1
}
exit 0
