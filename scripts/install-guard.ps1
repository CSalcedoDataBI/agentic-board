<#  install-guard.ps1 — wire the private-content guard into THIS clone of the public repo.
    Run once after cloning:  pwsh -File scripts/install-guard.ps1  #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# point git at the committed hooks/ directory
git config core.hooksPath hooks
Write-Host "core.hooksPath set to 'hooks' (pre-commit + pre-push guard active)."

# seed the local-only denylist from the template if missing
$deny = '.abios/private-denylist.txt'
if (-not (Test-Path $deny)) {
    Copy-Item '.abios/private-denylist.example.txt' $deny
    Write-Host "Seeded $deny — EDIT it with your private terms (it is gitignored, never committed)."
} else {
    Write-Host "$deny already exists — leaving it untouched."
}
Write-Host "Done. Test it:  echo 'my-private-repo' >> tmp.txt; git add tmp.txt; git commit -m x   (should be BLOCKED)"
