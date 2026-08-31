<#
    The single resolver for "which owner/name is this clone?" — dot-source it, never invoke it.

    WHY THIS FILE EXISTS (#281). The derivation was copy-pasted into eleven scripts in two
    different versions. Three of them (Board-Merge, New-BoardPR, Publish-KnowledgeWiki) carried
    a correct one; the other eight still carried the original:

        github\.com[/:]([^/]+)/([^/.]+)          <-- excludes '.' to drop the .git suffix

    That class also drops any dot BELONGING TO THE NAME, so a repo called `midominio.com`
    derived as `midominio` and every gh call 404'd. Someone fixed it three times and never
    propagated it — which is exactly why this is now one file instead of eleven copies.

    Contract:
      Get-RepoFromOriginUrl <url>   pure   -> "owner/name" or $null. Unit-tested.
      Get-RepoFromOrigin [-Path p]  live   -> reads git remote origin, throws a usable message.

    Accepts: https (with or without user@/token@), git@ ssh, ssh:// , optional .git, optional
    trailing slash, and dots anywhere in the owner or the name.

    Known ambiguity: a repo literally NAMED "foo.git" has the clone URL ".../foo.git.git" and
    resolves to "foo" — indistinguishable from the suffix without asking the API. git itself
    makes the same guess, so we match it rather than invent a rule.
#>

# PURE -> unit-testable. Returns $null (never throws) so callers choose their own error text.
function Get-RepoFromOriginUrl {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Url)
    if (-not $Url) { return $null }
    $u = $Url.Trim()
    # Host: github.com, or ssh.github.com — the alias for SSH over 443, which people behind a
    # firewall really do set as their origin. The OLD regex mangled that one into "443/owner"
    # (it matched the "github.com" inside "ssh.github.com", then took the port as the owner).
    # Protocols: https, http, ssh AND git — git:// is deprecated by GitHub but the old regex
    # accepted it by accident (it was unanchored), so dropping it would be a silent regression
    # for anyone who still has such a remote (Codex review, PR #284).
    # <proto>://[user@](ssh.)github.com[:port]/owner/name[.git][/]
    if ($u -match '(?i)^(?:https?|ssh|git)://(?:[^@/]+@)?(?:ssh\.)?github\.com(?::\d+)?/(.+?)/(.+?)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    # scp-like: [user@](ssh.)github.com:owner/name[.git]
    if ($u -match '(?i)^(?:[^@/]+@)?(?:ssh\.)?github\.com:(.+?)/(.+?)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    return $null
}

# Read the issue number out of the URL `gh issue create` prints. PURE -> unit-testable.
# Returns 0 when the text is not an issue/PR URL, and the CALLER must treat 0 as a failure.
#
# This lives here because the old inline version was the other half of #281:
#     $num = [int]($url -split '/')[-1]
# When gh failed it printed nothing, `$url` was empty, and `[int]''` yields 0 WITHOUT throwing
# - so the script cheerfully announced "OK #0" for seven issues that were never created. Parse
# strictly and let 0 mean "no".
function Get-IssueNumberFromUrl {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Url)
    if (-not $Url) { return 0 }
    if ($Url.Trim() -match '/(?:issues|pull)/(\d+)/?\s*$') { return [int]$Matches[1] }
    return 0
}

# Live: derive from this clone's `origin`. -Path runs git elsewhere (Install-RepoTemplates).
# Throws with the same actionable message every script used to write by hand.
function Get-RepoFromOrigin {
    param([string]$Path = '')
    $url = if ($Path) { git -C $Path remote get-url origin 2>$null } else { git remote get-url origin 2>$null }
    if (-not $url) { throw "No hay remote 'origin' aqui - usa -Repo owner/name." }
    $repo = Get-RepoFromOriginUrl $url
    if (-not $repo) { throw "No pude derivar owner/name desde '$url' - usa -Repo owner/name." }
    return $repo
}
