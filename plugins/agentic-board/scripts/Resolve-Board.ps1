<#  Resolve-Board.ps1 - find-or-reuse the board for a repo; create only if none exists.
    Prevents the "new duplicate board every time" bug. Returns the project NUMBER on stdout.
    Requires $env:GH_TOKEN (via gh-account).
    Usage: $num = & ./Resolve-Board.ps1 -Owner CSalcedoDataBI -Repo CSalcedoDataBI/agentic-board
    NOTE: source is pure ASCII; the em-dash in the canonical title is built at runtime so the file
          parses under Windows PowerShell 5.1 regardless of file encoding.  #>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Owner,
  [Parameter(Mandatory)][string]$Repo,     # owner/name
  [string]$Title,
  [bool]$CreateIfMissing = $true,
  # Language of the preset applied to a NEWLY created board (en|es). Ignored when reusing.
  [ValidateSet('en','es')][string]$Lang = 'en',
  # Escape hatch: create the bare board without applying the canonical preset.
  [switch]$SkipPreset
)
$ErrorActionPreference = 'Stop'

# A gh failure must NOT read as "no boards exist" — that empty result is the exact premise
# this script would then CREATE a board from, duplicating the one it could not read (#303/#86).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

$dash     = [char]0x2014                       # em-dash, built in code (no non-ASCII in source)
$repoName = $Repo.Split('/')[-1]
if (-not $Title) { $Title = "$repoName $dash Roadmap" }

$projects   = (Invoke-Gh -GhArgs @('project','list','--owner',$Owner,'--format','json') `
                         -What "listar los boards de $Owner" -Json).projects
$candidates = $projects | Where-Object { $_.title -notmatch '(?i)backup' }

$match = $candidates | Where-Object { $_.title -eq $Title } | Select-Object -First 1
if (-not $match) { $match = $candidates | Where-Object { $_.title -like "*$repoName*" } | Select-Object -First 1 }

if ($match) {
  Write-Host ("REUSE existing board #{0}: '{1}'" -f $match.number, $match.title) -ForegroundColor Green
  return $match.number
}
if (-not $CreateIfMissing) { Write-Host "No board found for $Repo (CreateIfMissing=false)"; return $null }

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
