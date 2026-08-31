<#  Resolve-SkillOwner.ps1 — where does a skill's failure feedback belong?

    A skill's issues must go to the repo that OWNS the skill — never to the private
    project you happen to be working in. This resolves the routing:

      - plugin  'agentic-board'  -> file to CSalcedoDataBI/agentic-board (this tool's board)
      - plugin  (other/third-party)-> LOCAL report only (never open issues in someone else's repo)
      - project (this repo's own)  -> file to the current repo's board
      - personal (global)          -> LOCAL report only

    Returns { scope, ownerRepo, filing('file'|'local'), note }. It does NOT create
    anything — the filing recipe (references/filing.md) does, after the human gate.

    EXAMPLE
      Resolve-SkillOwner -Scope plugin -Plugin agentic-board
      Resolve-SkillOwner -Scope project -CurrentRepo CSalcedoDataBI/agentic-board
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('plugin','personal','project')][string]$Scope,
    [string]$Plugin,
    [string]$CurrentRepo,
    [string]$ToolRepo = 'CSalcedoDataBI/agentic-board'
)

switch ($Scope) {
    'plugin' {
        if ($Plugin -in 'agentic-board','agentic-bi-ops') {   # accept the deprecated alias too
            [pscustomobject]@{ scope=$Scope; ownerRepo=$ToolRepo; filing='file'
                note='This tool. File a sanitized issue on its own board (abios-feedback flow).' }
        } else {
            [pscustomobject]@{ scope=$Scope; ownerRepo=$Plugin; filing='local'
                note="Third-party plugin '$Plugin'. Do NOT open an issue in someone else's repo — local report only; hand it to the user to file upstream." }
        }
    }
    'project' {
        if (-not $CurrentRepo) { $CurrentRepo = (git rev-parse --is-inside-work-tree 2>$null) ? (gh repo view --json nameWithOwner -q .nameWithOwner 2>$null) : $null }
        if ($CurrentRepo) {
            [pscustomobject]@{ scope=$Scope; ownerRepo=$CurrentRepo; filing='file'
                note="Project-owned skill. File on THIS project's own board ($CurrentRepo) — never the tool's board." }
        } else {
            [pscustomobject]@{ scope=$Scope; ownerRepo=$null; filing='local'
                note='Project skill but no repo resolved — local report only.' }
        }
    }
    'personal' {
        [pscustomobject]@{ scope=$Scope; ownerRepo=$null; filing='local'
            note='Personal/global skill. Local report only — no board to file to.' }
    }
}
