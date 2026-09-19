<#  Resolve-Board.ps1 - find-or-reuse the board for a repo; create only if none exists.
    Prevents the "new duplicate board every time" bug. Returns the project NUMBER on stdout.
    Requires $env:GH_TOKEN (via gh-account).
    Usage: $num = & ./Resolve-Board.ps1 -Owner CSalcedoDataBI -Repo CSalcedoDataBI/agentic-board

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
  # Language of the preset applied to a NEWLY created board (en|es). Ignored when reusing.
  [ValidateSet('en','es')][string]$Lang = 'en',
  # Escape hatch: create the bare board without applying the canonical preset.
  [switch]$SkipPreset
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
                      -What "leer los boards vinculados a $Repo" -Graphql
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
    Write-Host ("  WARN {0} tiene {1} boards vinculados ({2}); uso #{3}. Pasa -Title para elegir otro." -f `
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
                             -What "listar los boards de $Owner" -Json).projects | Where-Object { $null -ne $_ })
  $candidates = $projects | Where-Object { $_.title -notmatch '(?i)backup' }
  $match = $candidates | Where-Object { $_.title -eq $Title } | Select-Object -First 1
  if (-not $match -and -not $titleGiven) { $match = $candidates | Where-Object { $_.title -like "*$repoName*" } | Select-Object -First 1 }
  if (-not $match -and $projects.Count -ge $listLimit) {
    throw "$Owner tiene $listLimit boards o mas: la lista se corto y no puedo probar que ninguno es el que busco, asi que no creo otro. Pasa -Title exacto o elige el board a mano."
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
                  -What "enlazar el board #$($match.number) a $Repo" | Out-Null
        Write-Host ("  linked board #{0} '{1}' to {2} (it was reused by title and was not linked)." -f $match.number, $match.title, $Repo) -ForegroundColor DarkYellow
      } catch {
        Write-Host ("  WARN no pude vincular el board #{0} a {1}: {2}" -f $match.number, $Repo, $_.Exception.Message) -ForegroundColor DarkYellow
      }
    }
  }
  # A board reused through the title HEURISTICS (no -Title) is not linked either. Linking on a guess
  # could attach the repo to the wrong board, so only say how.
  if ($match -and -not $titleGiven) {
    Write-Host ("  NOTE el board #{0} '{1}' se encontro por titulo, no por vinculo; Board-Work -ListBoards no lo vera hasta vincularlo: gh project link {0} --owner {2} --repo {3}" -f `
                $match.number, $match.title, $Owner, $Repo) -ForegroundColor DarkYellow
  }
}

# The link read is capped at one page. If it was cut and nothing matched, "no linked board" is not
# proven for a lookup by REPO - a linked board of any title may sit past the cap, and creating one now
# would duplicate it. An explicit -Title is different: it was checked against the owner's whole board
# list above, so its absence there IS proven.
if (-not $match -and $linkedTruncated -and -not $titleGiven) {
  throw "El repo $Repo tiene mas de 100 boards vinculados: no puedo probar que ninguno es el que busco, asi que no creo otro. Pasa -Title exacto o elige el board a mano."
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
  Write-Host ("  {0} ya tiene {1} board(s) vinculado(s) ({2}); creo un board aparte '{3}' porque se pidio por -Title." -f `
              $Repo, $linkedBoards.Count, (($linkedBoards | ForEach-Object { "#$($_.number)" }) -join ', '), $Title) -ForegroundColor Yellow
}

$WhatIfPreference  = $whatIfRequested     # only the create below is a WhatIf / Confirm target
$ConfirmPreference = $confirmRequested
if (-not $PSCmdlet.ShouldProcess("board '$Title' for $Repo", 'create and link')) { return $null }
$WhatIfPreference  = $false
$ConfirmPreference = 'High'

$num = (Invoke-Gh -GhArgs @('project','create','--owner',$Owner,'--title',$Title,'--format','json') `
                  -What "crear el board '$Title'" -Json).number
Invoke-Gh -GhArgs @('project','link',"$num",'--owner',$Owner,'--repo',$Repo) `
          -What "enlazar el board #$num a $Repo" | Out-Null
Invoke-Gh -GhArgs @('project','edit',"$num",'--owner',$Owner,'--description',"Roadmap + issue tracking for $Repo. Anchored to that repo.") `
          -What "describir el board #$num" | Out-Null
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
  try {
    $applyPreset = Join-Path $PSScriptRoot 'Apply-FieldPreset.ps1'
    & $applyPreset -Number $num -Owner $Owner -Lang $Lang -Yes | Out-Null
    Write-Host ("  preset '{0}' applied - board born on the canonical vocabulary (no legacy 'Todo')." -f $Lang) -ForegroundColor DarkGreen
  } catch {
    Write-Host ("  WARN could not apply the '{0}' preset to the new board #{1}: {2}" -f $Lang, $num, $_.Exception.Message) -ForegroundColor DarkYellow
    Write-Host ("        apply it by hand: /board field apply -Number {0} -Owner {1} -Lang {2}" -f $num, $Owner, $Lang) -ForegroundColor DarkGray
  }
}
return $num
