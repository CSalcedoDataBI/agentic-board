<#  Resolve-Board.ps1 - find-or-reuse the board for a repo; create only if none exists.
    Prevents the "new duplicate board every time" bug. Returns the project NUMBER on stdout.
    IDENTITY (#793). The token is decided by the one resolver every other script uses
    (Resolve-GhTokenVar's Get-GhTokenForContext): the -Owner's account from your account map
    (~/.agentic-board/accounts.json), the agent identity inside a brake-armed run, else the ambient
    GH_TOKEN / `gh auth token`. -TokenVar names the variable explicitly - judged, not honoured
    blindly: inside an armed run only the agent's is accepted. So a third account of yours is a
    line in the map (or one -TokenVar), never a hand-set $env:GH_TOKEN.
    Usage: $num = & ./Resolve-Board.ps1 -Owner your-login -Repo CSalcedoDataBI/agentic-board
           $num = & ./Resolve-Board.ps1 -Owner other-login -Repo other-login/app -TokenVar GITHUB_TOKEN_OTHER

    HOW THE BOARD IS FOUND (#498, #666). GitHub records which boards are linked to a repository
    (repository.projectsV2) - the same link Board-Work -ListBoards reads - so that is the lookup, not
    the board's TITLE. Matching by title made a board named after the PRODUCT (not the repo slug)
    invisible, and the not-found path then pointed the user at `/board init`, i.e. at creating the
    DUPLICATE this script exists to prevent.
      * no -Title  : the repo's linked board (the canonical '<repo> EM-DASH Roadmap' one - U+2014, not a hyphen - when several are
                     linked, else the lowest number, with a warning naming the others). Only when the
                     repo has NO linked board does it fall back to the old title heuristics.
      * -Title 'X' : -Title is a SELECTOR, not a decoration. The linked board titled exactly 'X' is
                     reused; if the repo has none, a board 'X' is created (a second board for the repo
                     is legitimate). It never hands back a board with a different title - that returned
                     a bare number the caller took for 'X' and wrote fields onto the wrong board. A board
                     found only by that exact title (not linked to the repo yet) is reused AND linked, so
                     a later lookup without -Title finds it through the link instead of duplicating it.
    A lookup that was cut short (more than 100 linked boards, or a full 200-board owner list) with no
    match THROWS: absence is not proven, so it never falls through to a create.
    -WhatIf is honoured: it reports the board it would create/link and changes nothing.
    NOTE: source is pure ASCII; the em-dash in the canonical title is built at runtime so the file
          parses under Windows PowerShell 5.1 regardless of file encoding.  #>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string]$Owner,
  [Parameter(Mandatory)][string]$Repo,     # owner/name
  # A board title to SELECT (reuse the linked board with exactly this title) or, when the repo has
  # none, to CREATE. Omit it to mean "the board for this repo" (#666).
  [string]$Title,
  [bool]$CreateIfMissing = $true,
  # Language of the preset applied to a NEWLY created board (en|es). Ignored when reusing. Status
  # is canonical (Backlog / In Progress / In Review / Blocked / Done) in both (#794).
  [ValidateSet('en','es')][string]$Lang = 'en',
  # Escape hatch: create the bare board without applying the canonical preset.
  [switch]$SkipPreset,
  # The env var holding the token to use (#793). Omitted, the account map decides from -Owner.
  [string]$TokenVar = ''
)
$ErrorActionPreference = 'Stop'

# -WhatIf must gate the board CREATE and nothing else. $WhatIfPreference is inherited by every
# cmdlet below - including the temp-file redirect and Remove-Item inside Invoke-Gh's runner - so it
# is parked here and restored just before the one ShouldProcess call; otherwise a rehearsal would
# also switch off the reads that decide whether a board exists.
$whatIfRequested  = $WhatIfPreference
$WhatIfPreference = $false
# Same for -Confirm: it raises $ConfirmPreference to 'Low', and every ShouldProcess-aware cmdlet in
# the read path would then stop and ask, in the middle of a lookup that must run unattended.
$confirmRequested  = $ConfirmPreference
$ConfirmPreference = 'High'

# A gh failure must NOT read as "no boards exist" — that empty result is the exact premise
# this script would then CREATE a board from, duplicating the one it could not read (#303/#86).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Canonical Status vocabulary: what the post-preset check below compares the live options with.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

# Identity (#793): the owner's account from the map, or the agent's inside a braked run - the same
# resolver as New-BoardPR / Board-Depend. Before, this script used whatever $env:GH_TOKEN held, so an
# account the old hardcoded map did not know could only be reached by setting it by hand.
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
$ctx = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner $Owner -ExplicitVar $TokenVar
$env:GH_TOKEN = $ctx.token
Write-Verbose "identity: $($ctx.var) - $($ctx.reason)"

# Which Status options a board really carries, against the canonical set (#794). Pure.
# Returns @{ ok; legacy = names that MEAN a canonical option under an old name (Todo); missing }.
function Get-StatusVerdict {
  param([string[]]$Options)
  $legacy  = @($Options | Where-Object {
    $canon = Get-CanonicalOptionName 'Status' $_
    $canon -and $canon -cne $_
  })
  $missing = @(Get-CanonicalOptionNames 'Status' | Where-Object { @($Options) -notcontains $_ })
  @{ ok = ($legacy.Count -eq 0 -and $missing.Count -eq 0); legacy = $legacy; missing = $missing }
}

$dash       = [char]0x2014                     # em-dash, built in code (no non-ASCII in source)
# A bare repo name cannot be looked up through the link (that needs owner/name) and would fall back to
# title guessing - the very path that hid a product-named board. Read it as a repo of -Owner.
if ($Repo -notmatch '/') { $Repo = "$Owner/$Repo" }
$repoName   = $Repo.Split('/')[-1]
$titleGiven = $PSBoundParameters.ContainsKey('Title') -and "$Title".Trim() -ne ''
$canonical  = "$repoName $dash Roadmap"
if (-not $titleGiven) { $Title = $canonical }

# 1. The boards GitHub says are linked to this repository. -Graphql fails closed: a failed read must
#    not read as "the repo has no linked board" - that is the premise the create below would act on.
$linkedBoards    = @()
$linkedTruncated = $false
if ($Repo -match '^[^/]+/[^/]+$') {
  $rp = $Repo -split '/'
  $linkedQuery = '
query($o:String!, $r:String!) {
  repository(owner:$o, name:$r) {
    projectsV2(first:100) {
      pageInfo { hasNextPage }
      nodes {
        number title closed
        owner { ... on User { login } ... on Organization { login } }
      }
    }
  }
}'
  $linked = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$linkedQuery",'-f',"o=$($rp[0])",'-f',"r=$($rp[1])") `
                      -What "read the boards linked to $Repo" -Graphql
  $linkedTruncated = [bool]$linked.data.repository.projectsV2.pageInfo.hasNextPage
  # Only boards of THIS owner: the number is meaningless without the owner it is used with.
  $linkedBoards = @($linked.data.repository.projectsV2.nodes |
                    Where-Object { $_ -and -not $_.closed -and $_.title -notmatch '(?i)backup' -and "$($_.owner.login)" -ieq $Owner })
}

$match = $null
if ($titleGiven) {
  # -Title is a selector (#666): exactly this title among the linked boards, never another one.
  $match = $linkedBoards | Where-Object { $_.title -eq $Title } | Select-Object -First 1
} elseif ($linkedBoards.Count -gt 0) {
  $match = $linkedBoards | Where-Object { $_.title -eq $canonical } | Select-Object -First 1
  if (-not $match) { $match = $linkedBoards | Sort-Object { [int]$_.number } | Select-Object -First 1 }
  if ($linkedBoards.Count -gt 1) {
    Write-Host ("  WARN {0} has {1} linked boards ({2}); using #{3}. Pass -Title to pick another." -f `
                $Repo, $linkedBoards.Count, (($linkedBoards | ForEach-Object { "#$($_.number) '$($_.title)'" }) -join ', '), $match.number) -ForegroundColor DarkYellow
  }
}

# 2. Title heuristics - the old behaviour, now only the fallback. An explicit -Title needs an EXACT
#    title; without one they apply only when the repo has no linked board at all, so a stray board
#    whose name merely contains the repo name can never shadow the real link.
if (-not $match -and ($titleGiven -or $linkedBoards.Count -eq 0)) {
  # gh's default is 30 boards: past that, "not in the list" proves nothing, so ask for plenty and treat
  # a full page as a cut-short read below.
  $listLimit  = 200
  $projects   = @((Invoke-Gh -GhArgs @('project','list','--owner',$Owner,'--format','json','--limit',"$listLimit") `
                             -What "list the boards of $Owner" -Json).projects | Where-Object { $null -ne $_ })
  $candidates = $projects | Where-Object { $_.title -notmatch '(?i)backup' }
  $match = $candidates | Where-Object { $_.title -eq $Title } | Select-Object -First 1
  if (-not $match -and -not $titleGiven) { $match = $candidates | Where-Object { $_.title -like "*$repoName*" } | Select-Object -First 1 }
  if (-not $match -and $projects.Count -ge $listLimit) {
    throw "$Owner has $listLimit boards or more: the list was cut short and I cannot prove none is the one I am looking for, so I will not create another. Pass an exact -Title or pick the board by hand."
  }
  # Found by title alone, so nothing yet ties it to THIS repo. The caller asked for exactly this
  # title for this repo, so LINK it: otherwise the next lookup without -Title (which reads the link)
  # would not find it and would create a duplicate. Gated by ShouldProcess (-WhatIf / -Confirm) and
  # fail-soft: the board is still the one that was asked for.
  if ($match -and $titleGiven) {
    $WhatIfPreference  = $whatIfRequested
    $ConfirmPreference = $confirmRequested
    $doLink = $PSCmdlet.ShouldProcess("board #$($match.number) '$($match.title)'", "link to $Repo")
    $WhatIfPreference  = $false
    $ConfirmPreference = 'High'
    if ($doLink) {
      try {
        Invoke-Gh -GhArgs @('project','link',"$($match.number)",'--owner',$Owner,'--repo',$Repo) `
                  -What "link board #$($match.number) to $Repo" | Out-Null
        Write-Host ("  linked board #{0} '{1}' to {2} (it was reused by title and was not linked)." -f $match.number, $match.title, $Repo) -ForegroundColor DarkYellow
      } catch {
        Write-Host ("  WARN could not link board #{0} to {1}: {2}" -f $match.number, $Repo, $_.Exception.Message) -ForegroundColor DarkYellow
      }
    }
  }
  # A board reused through the title HEURISTICS (no -Title) is not linked either. Linking on a guess
  # could attach the repo to the wrong board, so only say how.
  if ($match -and -not $titleGiven) {
    Write-Host ("  NOTE board #{0} '{1}' was found by title, not by link; Board-Work -ListBoards will not see it until it is linked: gh project link {0} --owner {2} --repo {3}" -f `
                $match.number, $match.title, $Owner, $Repo) -ForegroundColor DarkYellow
  }
}

# The link read is capped at one page. If it was cut and nothing matched, "no linked board" is not
# proven for a lookup by REPO - a linked board of any title may sit past the cap, and creating one now
# would duplicate it. An explicit -Title is different: it was checked against the owner's whole board
# list above, so its absence there IS proven.
if (-not $match -and $linkedTruncated -and -not $titleGiven) {
  throw "Repo $Repo has more than 100 linked boards: I cannot prove none is the one I am looking for, so I will not create another. Pass an exact -Title or pick the board by hand."
}

if ($match) {
  Write-Host ("REUSE existing board #{0}: '{1}'" -f $match.number, $match.title) -ForegroundColor Green
  return $match.number
}
if (-not $CreateIfMissing) {
  Write-Host ("No board found for $Repo (CreateIfMissing=false): looked at the boards linked to the repository" +
              $(if ($titleGiven) { " with the title '$Title'" } else { ", then at board titles" }) + ".")
  Write-Host "  Check /board work -ListBoards -Repo $Repo before creating one: creating a board when one already exists is how duplicate boards happen." -ForegroundColor DarkGray
  return $null
}
if ($linkedBoards.Count -gt 0) {
  Write-Host ("  {0} already has {1} linked board(s) ({2}); creating a separate board '{3}' because -Title asked for it." -f `
              $Repo, $linkedBoards.Count, (($linkedBoards | ForEach-Object { "#$($_.number)" }) -join ', '), $Title) -ForegroundColor Yellow
}

$WhatIfPreference  = $whatIfRequested     # only the create below is a WhatIf / Confirm target
$ConfirmPreference = $confirmRequested
if (-not $PSCmdlet.ShouldProcess("board '$Title' for $Repo", 'create and link')) { return $null }
$WhatIfPreference  = $false
$ConfirmPreference = 'High'

$num = (Invoke-Gh -GhArgs @('project','create','--owner',$Owner,'--title',$Title,'--format','json') `
                  -What "create board '$Title'" -Json).number
Invoke-Gh -GhArgs @('project','link',"$num",'--owner',$Owner,'--repo',$Repo) `
          -What "link board #$num to $Repo" | Out-Null
Invoke-Gh -GhArgs @('project','edit',"$num",'--owner',$Owner,'--description',"Roadmap + issue tracking for $Repo. Anchored to that repo.") `
          -What "describe board #$num" | Out-Null
Write-Host ("CREATED board #{0}: '{1}' (linked to {2})" -f $num, $Title, $Repo) -ForegroundColor Yellow

# Born canonical (#299). `gh project create` seeds GitHub's default Status field (Todo / In Progress /
# Done). If the board keeps `Todo`, a later plain `apply` renames it onto `Backlog` — but only while
# it is the ONLY vocabulary; once a board carries BOTH `Todo` and `Backlog` no rename can merge them
# (GitHub forbids two options with the same name), which is the exact dead-end #299 reports. Applying
# the preset HERE, at birth, forecloses that: the board never carries the legacy `Todo` at all. It is
# also the cheapest possible moment — a just-created board has zero items, so the `Todo`->`Backlog`
# rename touches nothing and `-Yes` cannot be destructive. A preset failure must NOT fail the resolve:
# the board already exists and is the return value; we warn and let the caller apply it by hand.
if (-not $SkipPreset) {
  $presetApplied = $false
  try {
    $applyPreset = Join-Path $PSScriptRoot 'Apply-FieldPreset.ps1'
    & $applyPreset -Number $num -Owner $Owner -Lang $Lang -Yes | Out-Null
    $presetApplied = $true
  } catch {
    Write-Host ("  WARN could not apply the '{0}' preset to the new board #{1}: {2}" -f $Lang, $num, $_.Exception.Message) -ForegroundColor DarkYellow
    Write-Host ("        apply it by hand: /board field apply -Number {0} -Owner {1} -Lang {2}" -f $num, $Owner, $Lang) -ForegroundColor DarkGray
  }
  if ($presetApplied) {
    # "Born canonical" is a claim about the board, so it is READ from the board (#794): -Lang es once
    # printed it over a Status still on Todo / In Progress / Done, because the localized 'Estado' did
    # not match 'Status' and the step was skipped. The message now follows the live options.
    try {
      $fields = @((Invoke-Gh -GhArgs @('project','field-list',"$num",'--owner',$Owner,'--format','json') `
                             -What "read the Status options of board #$num" -Json).fields)
      $status = $fields | Where-Object { $_ -and $_.name -eq 'Status' } | Select-Object -First 1
      $v = Get-StatusVerdict -Options @($status.options | ForEach-Object { "$($_.name)" })
      if (-not $status) {
        Write-Host ("  WARN preset '{0}' applied, but board #{1} has no 'Status' field to check." -f $Lang, $num) -ForegroundColor DarkYellow
      } elseif ($v.ok) {
        Write-Host ("  preset '{0}' applied - board born on the canonical vocabulary (no legacy 'Todo')." -f $Lang) -ForegroundColor DarkGreen
      } else {
        $why = @()
        if ($v.legacy.Count)  { $why += "legacy: $($v.legacy -join ', ')" }
        if ($v.missing.Count) { $why += "missing: $($v.missing -join ', ')" }
        Write-Host ("  WARN preset '{0}' applied, but Status on board #{1} is NOT canonical ({2})." -f $Lang, $num, ($why -join '; ')) -ForegroundColor DarkYellow
        Write-Host ("        fix it: /board field apply -Number {0} -Owner {1} -Lang en" -f $num, $Owner) -ForegroundColor DarkGray
      }
    } catch {
      Write-Host ("  preset '{0}' applied; could not read board #{1} back to confirm its Status options: {2}" -f $Lang, $num, $_.Exception.Message) -ForegroundColor DarkYellow
    }
    if ($Lang -eq 'es') {
      # The es preset names its OTHER fields in Spanish (Prioridad, Tamano, Tipo...). The suite reads
      # both names, but a standard board uses the English ones - say so instead of letting it surprise.
      Write-Host "  NOTE -Lang es names Priority/Size/Type/Area/Estimate/Target in Spanish; Status keeps the canonical English options. Standard boards use -Lang en." -ForegroundColor DarkGray
    }
  }
}
return $num
