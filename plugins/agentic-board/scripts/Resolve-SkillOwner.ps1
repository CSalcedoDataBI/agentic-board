<#  Resolve-SkillOwner.ps1 — where does a skill's failure feedback belong?

    A skill's issues must go to the repo that OWNS the skill — never to the private
    project you happen to be working in. This resolves the routing:

      - plugin  'agentic-board'  -> file to CSalcedoDataBI/agentic-board (this tool's board)
      - plugin  (other/third-party)-> LOCAL report only (never open issues in someone else's repo)
      - project (this repo's own)  -> file to the current repo's board
      - personal (global)          -> LOCAL report only

    Returns { scope, ownerRepo, filing('file'|'local'), note }. It does NOT create
    anything — the filing recipe (references/filing.md) does, after the human gate.

    ownerRepo is ALWAYS an `owner/repo` or $null — never a plugin or marketplace name. FAIL CLOSED:
    anything that is not positively established as the tool's own is `local` (nothing is filed).

    -PluginRepo is the repo the plugin's OWN manifest (plugin.json repository/homepage) declares.
    When the caller passes it (even empty), a plugin is the tool's only if its name is the tool's
    AND that declared repo is the tool repo: a name alone (a plugin can call itself anything) or a
    missing manifest never routes a finding to the tool's board. Callers that do not pass it
    (legacy, name-only) keep the old name-only check.

    EXAMPLE
      Resolve-SkillOwner -Scope plugin -Plugin agentic-board -PluginRepo CSalcedoDataBI/agentic-board
      Resolve-SkillOwner -Scope project -CurrentRepo CSalcedoDataBI/agentic-board
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('plugin','personal','project')][string]$Scope,
    [string]$Plugin,
    [string]$PluginRepo,
    [string]$CurrentRepo,
    [string]$ToolRepo = 'CSalcedoDataBI/agentic-board'
)

switch ($Scope) {
    'plugin' {
        $verified = $PSBoundParameters.ContainsKey('PluginRepo')
        $declared = if ($PluginRepo -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { $PluginRepo } else { $null }
        $isToolName = $Plugin -in 'agentic-board','agentic-bi-ops'   # accept the deprecated alias too
        if ($isToolName -and (-not $verified -or ($declared -and $declared -ieq $ToolRepo))) {
            [pscustomobject]@{ scope=$Scope; ownerRepo=$ToolRepo; filing='file'
                note='This tool. File a sanitized issue on its own board (abios-feedback flow).' }
        } else {
            $why = if ($Plugin) { "Plugin '$Plugin' is not established as this tool's" } else { 'The plugin of this skill could not be identified' }
            [pscustomobject]@{ scope=$Scope; ownerRepo=$declared; filing='local'
                note="$why. Do NOT open an issue in someone else's repo (or a guessed one) — local report only; hand it to the user to file upstream." }
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
