<#  Publish-DocsWiki.ps1 — single publisher for the repo's GitHub Wiki.

    Generates ALL wiki pages in one clone → commit → push:
      Product docs (always):
        Docs-Home          — from README.md (HTML stripped)
        Docs-Command-<X>   — one page per commands/*.md file (frontmatter stripped)
      Knowledge registry (when knowledge/registry.json exists at $Root):
        Home               — index of domains and reference counts
        Knowledge-<Domain> — one page per domain

    Navigation:
      _Sidebar — links to all product docs pages + all knowledge domain pages
      _Footer  — "generated from the repo" notice

    All pages carry a <!-- GENERATED --> marker so the wiki is clearly derived output,
    never hand-maintained. Source of truth stays in the repo.

    Testable page generation is exposed via -PagesOnly -OutDir (pure, no git/network).
    The clone -> commit -> push path mirrors Publish-KnowledgeWiki: the token travels ONLY
    as an env var read by a one-shot credential helper, never on the command line or in
    the remote URL. #>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Repo,                        # owner/name; default derived from origin
    [string]$TokenVar = '',               # default resolved from the owner (New-BoardPR map)
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$PagesOnly,                   # generate pages into -OutDir and stop (no git) — for tests/preview
    [string]$OutDir,                      # required with -PagesOnly
    [switch]$DryRun,                      # resolve + generate, but do not push
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

# ── Pure helpers (no side-effects, unit-testable) ───────────────────────────────────────

# Strip HTML elements that do not render usefully on a wiki page.
# Removes: <p>…</p>, <img …>, <sub>…</sub>.  Collapses extra blank lines.
function Strip-ReadmeHtml {
    param([Parameter(Mandatory)][string]$Text)
    # Multiline <p> blocks (also covers self-closing-less <p>…</p>)
    $Text = [regex]::Replace($Text, '<p[^>]*>[\s\S]*?</p>', '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    # Lone <img> tags that may have survived (shouldn't, but belt-and-suspenders)
    $Text = [regex]::Replace($Text, '<img\b[^>]*/?>?', '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    # <sub>…</sub> (the version footer in README)
    $Text = [regex]::Replace($Text, '<sub>[\s\S]*?</sub>', '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    # Collapse runs of 3+ blank lines down to 2
    $Text = [regex]::Replace($Text, '(\r?\n){3,}', "`n`n")
    $Text.Trim()
}

# Extract a frontmatter field value from a Markdown file's leading --- block.
# Returns $null when the file has no frontmatter or the field is absent.
function Get-FrontmatterField {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory)][string]$Field
    )
    $m = [regex]::Match($Raw, '(?s)^\s*---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $null }
    $block = $m.Groups[1].Value
    $fm = [regex]::Match($block, '(?m)^' + [regex]::Escape($Field) + '\s*:\s*(.+?)\s*$')
    if (-not $fm.Success) { return $null }
    $fm.Groups[1].Value.Trim()
}

# Remove the YAML frontmatter block (--- … ---) from the top of a Markdown file.
function Remove-Frontmatter {
    param([Parameter(Mandatory)][string]$Text)
    $stripped = [regex]::Replace($Text, '(?s)^\s*---\r?\n.*?\r?\n---\r?\n?', '')
    $stripped.Trim()
}

# Strip agent-specific template artifacts from a command file's body so the wiki
# page reads as user documentation, not an agent system prompt.
# Removes: "You are running the agentic-board /X command." lines,
#          "Arguments: $ARGUMENTS" trailing lines.
# Replaces: inline $ARGUMENTS occurrences with "<arguments>" for readability.
function Clean-CommandBody {
    param([Parameter(Mandatory)][string]$Text)
    # "You are running …" opener (one or two lines at the very beginning)
    $Text = [regex]::Replace($Text, '(?m)^You are running the agentic-board /\S+ command\.\r?\n?', '')
    # "Arguments: $ARGUMENTS" tail (standalone line)
    $Text = [regex]::Replace($Text, '(?m)^Arguments: \$ARGUMENTS\r?\n?', '')
    # Remaining $ARGUMENTS occurrences (inline in "If $ARGUMENTS is empty …" patterns)
    $Text = $Text.Replace('$ARGUMENTS', '<arguments>')
    $Text.Trim()
}

# Build the wiki-page slug for a command by its base name (e.g. "board" → "Docs-Command-Board").
function Get-CommandSlug {
    param([Parameter(Mandatory)][string]$BaseName)
    'Docs-Command-' + (($BaseName.Substring(0,1).ToUpper() + $BaseName.Substring(1)) -replace '[^\w-]+', '-')
}

# Build the wiki-page slug for a knowledge domain (e.g. "Power-Query" → "Knowledge-Power-Query").
function Get-DomainSlug {
    param([Parameter(Mandatory)][string]$Domain)
    'Knowledge-' + (($Domain -replace '[^\w-]+', '-') -replace '-+', '-').Trim('-')
}

# ── Find source files ────────────────────────────────────────────────────────────────────

# The README lives at the repo root; commands/ is relative to this script's plugin dir.
$readmePath   = Join-Path $Root 'README.md'
$commandsDir  = Join-Path $PSScriptRoot '..' 'commands'

if (-not (Test-Path -LiteralPath $readmePath)) {
    throw "README.md not found at $readmePath. Run from the repo root or pass -Root."
}
$commandsDir = Resolve-Path $commandsDir | Select-Object -ExpandProperty Path
if (-not (Test-Path -LiteralPath $commandsDir)) {
    throw "Commands directory not found at $commandsDir."
}

# ── Build pages in memory ─────────────────────────────────────────────────────────────

$pages = [ordered]@{}
$sourceFiles = [ordered]@{}   # page-name -> source path (for diagnostics / -Json)

# --- Docs-Home from README -------------------------------------------------------
$readmeRaw = [System.IO.File]::ReadAllText($readmePath)
$stripped  = Strip-ReadmeHtml -Text $readmeRaw

$homeSb = [Text.StringBuilder]::new()
[void]$homeSb.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit README.md in the repo. -->")
[void]$homeSb.AppendLine("")
[void]$homeSb.AppendLine($stripped)
[void]$homeSb.AppendLine("")
[void]$homeSb.AppendLine("---")
[void]$homeSb.AppendLine("")

# Navigation index to command pages
$cmdFiles = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.md' -File | Sort-Object Name)
if ($cmdFiles.Count -gt 0) {
    [void]$homeSb.AppendLine("## Command reference")
    [void]$homeSb.AppendLine("")
    foreach ($cf in $cmdFiles) {
        $slug = Get-CommandSlug -BaseName $cf.BaseName
        $desc = Get-FrontmatterField -Raw ([System.IO.File]::ReadAllText($cf.FullName)) -Field 'description'
        $blurb = if ($desc) { " — $desc" } else { '' }
        [void]$homeSb.AppendLine("- [/$($cf.BaseName)]($slug)$blurb")
    }
    [void]$homeSb.AppendLine("")
}
[void]$homeSb.AppendLine("_Last published $Date._")

$pages['Docs-Home'] = $homeSb.ToString()
$sourceFiles['Docs-Home'] = $readmePath

# --- One page per command --------------------------------------------------------
foreach ($cf in $cmdFiles) {
    $raw     = [System.IO.File]::ReadAllText($cf.FullName)
    $desc    = Get-FrontmatterField -Raw $raw -Field 'description'
    $body    = Remove-Frontmatter -Text $raw
    $body    = Clean-CommandBody  -Text $body

    $slug = Get-CommandSlug -BaseName $cf.BaseName

    $pageSb = [Text.StringBuilder]::new()
    [void]$pageSb.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit commands/$($cf.Name) in the repo. -->")
    if ($desc) {
        [void]$pageSb.AppendLine("")
        [void]$pageSb.AppendLine("> $desc")
    }
    [void]$pageSb.AppendLine("")
    [void]$pageSb.AppendLine($body)
    [void]$pageSb.AppendLine("")
    [void]$pageSb.AppendLine("[← Product Docs](Docs-Home)")

    $pages[$slug] = $pageSb.ToString()
    $sourceFiles[$slug] = $cf.FullName
}

# --- Knowledge registry pages (optional) -----------------------------------------
# When knowledge/registry.json (or .yaml) exists, generate Home + Knowledge-<Domain>
# pages and record domain list for use in _Sidebar. Skipped gracefully if no registry.
$knDomains = @()
$regPath = Join-Path $Root 'knowledge' 'registry.json'
$regPathYaml = Join-Path $Root 'knowledge' 'registry.yaml'
$knRegPath = if (Test-Path -LiteralPath $regPath) { $regPath }
             elseif (Test-Path -LiteralPath $regPathYaml) { $regPathYaml }
             else { $null }

if ($knRegPath) {
    . (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')
    $reg     = Read-KnowledgeRegistry -Path $knRegPath
    $knRefs  = @($reg.references)
    $knProject = if ($reg.project) { $reg.project } else { Split-Path $Root -Leaf }
    $knDomains = @($knRefs | Select-Object -ExpandProperty domain -Unique | Sort-Object)

    function Format-KnRef  { param([string]$s) if ($s -match '^(https?)://') { "[$s]($s)" } else { "``$s``" } }
    function Format-KnCell { param([string]$s) ([string]$s -replace '\|', '\|') }

    $khomeSb = [Text.StringBuilder]::new()
    [void]$khomeSb.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit knowledge/registry.json in the repo. -->")
    [void]$khomeSb.AppendLine("# Knowledge — $knProject")
    [void]$khomeSb.AppendLine("")
    [void]$khomeSb.AppendLine("Catalog of external references by domain. Source of truth: ``knowledge/registry.json`` in the repo.")
    [void]$khomeSb.AppendLine("")
    if ($knRefs.Count -eq 0) {
        [void]$khomeSb.AppendLine("_No references yet. Add one with ``/knowledge add``._")
    } else {
        [void]$khomeSb.AppendLine("| Domain | References |")
        [void]$khomeSb.AppendLine("|--------|-----------|")
        foreach ($domain in $knDomains) {
            $count = @($knRefs | Where-Object domain -eq $domain).Count
            [void]$khomeSb.AppendLine(("| [{0}]({1}) | {2} |" -f (Format-KnCell $domain), (Get-DomainSlug $domain), $count))
        }
        [void]$khomeSb.AppendLine("")
        [void]$khomeSb.AppendLine("_$($knRefs.Count) reference(s) across $($knDomains.Count) domain(s). Last published $Date._")

        foreach ($domain in $knDomains) {
            $p = [Text.StringBuilder]::new()
            [void]$p.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit knowledge/registry.json in the repo. -->")
            [void]$p.AppendLine("# $domain")
            [void]$p.AppendLine("")
            [void]$p.AppendLine("| Title | Type | Ref | Note |")
            [void]$p.AppendLine("|-------|------|-----|------|")
            foreach ($r in ($knRefs | Where-Object domain -eq $domain | Sort-Object title)) {
                [void]$p.AppendLine(("| {0} | {1} | {2} | {3} |" -f (Format-KnCell $r.title), $r.type, (Format-KnRef $r.ref), (Format-KnCell $r.note)))
            }
            [void]$p.AppendLine("")
            [void]$p.AppendLine("[← Home](Home)")
            $pages[(Get-DomainSlug $domain)] = $p.ToString()
        }
    }
    $pages['Home'] = $khomeSb.ToString()
    $sourceFiles['Home'] = $knRegPath
}

# --- _Sidebar (navigation panel shown on all wiki pages) -------------------------
$sidebarSb = [Text.StringBuilder]::new()
[void]$sidebarSb.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit the repo. -->")
[void]$sidebarSb.AppendLine("")
[void]$sidebarSb.AppendLine("## Product Docs")
[void]$sidebarSb.AppendLine("")
[void]$sidebarSb.AppendLine("- [Home](Docs-Home)")
foreach ($cf in $cmdFiles) {
    $slug = Get-CommandSlug -BaseName $cf.BaseName
    [void]$sidebarSb.AppendLine("- [/$($cf.BaseName)]($slug)")
}
[void]$sidebarSb.AppendLine("")
[void]$sidebarSb.AppendLine("## Knowledge")
[void]$sidebarSb.AppendLine("")
[void]$sidebarSb.AppendLine("- [Knowledge](Home)")
foreach ($domain in $knDomains) {
    [void]$sidebarSb.AppendLine("  - [$domain]($(Get-DomainSlug $domain))")
}
$pages['_Sidebar'] = $sidebarSb.ToString()

# --- _Footer (shown at the bottom of all wiki pages) --------------------------------
$footerSb = [Text.StringBuilder]::new()
[void]$footerSb.AppendLine("<!-- GENERATED by /docs wiki — do not edit here; edit the repo. -->")
[void]$footerSb.AppendLine("")
[void]$footerSb.AppendLine("---")
[void]$footerSb.AppendLine("")
[void]$footerSb.AppendLine("_This wiki is generated from the repository. Do not edit pages here — changes will be overwritten on the next publish._")
$pages['_Footer'] = $footerSb.ToString()

# ── -PagesOnly: write pages to OutDir and stop (testable, no git) ─────────────────────
if ($PagesOnly) {
    if (-not $OutDir) { throw "-PagesOnly requires -OutDir." }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $written = foreach ($name in $pages.Keys) {
        $fp = Join-Path $OutDir "$name.md"
        $pages[$name] | Set-Content -LiteralPath $fp -Encoding utf8
        $fp
    }
    if ($Json) {
        [pscustomobject]@{ pages = @($pages.Keys); files = @($written); sources = $sourceFiles } |
            ConvertTo-Json -Depth 6
    } else {
        @($written)
    }
    return
}

# ── Resolve repo + account (mirror Publish-KnowledgeWiki) ──────────────────────────────
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
if (-not $Repo) { $Repo = Get-RepoFromOrigin }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo must be owner/name (got '$Repo')." }
$owner = ($Repo -split '/')[0]
# One map, not four copies (#550).
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
# Built FROM the resolver, owners included: listing them here was a fifth copy of the same rule.
$ownerVarMap = @{}
foreach ($o in (Get-KnownOwners)) { $ownerVarMap[$o] = (Get-OwnerTokenVar -Owner $o) }
if (-not $TokenVar) {
    if ($ownerVarMap.ContainsKey($owner)) { $TokenVar = $ownerVarMap[$owner] }
    else { $TokenVar = 'GITHUB_TOKEN_PERSONAL'; Write-Host "AVISO: owner '$owner' sin mapear — uso la personal (-TokenVar para forzar)." -ForegroundColor Yellow }
}
$token = [System.Environment]::GetEnvironmentVariable($TokenVar, 'User')
if ([string]::IsNullOrWhiteSpace($token)) { throw "$TokenVar no está en el entorno USER de Windows." }
$env:GH_TOKEN = $token

# Confirm identity + that the wiki is enabled on the repo.
$login = "$(gh api user --jq .login 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $login) { throw "El token de $TokenVar no autentica contra la API." }
$repoInfo = gh api "repos/$Repo" 2>$null | ConvertFrom-Json
if (-not $repoInfo) { throw "'$login' no ve el repo $Repo (no existe o sin acceso). Cuenta equivocada?" }
if (-not $repoInfo.permissions.push) { throw "'$login' NO tiene permiso de push en $Repo." }
if (-not $repoInfo.has_wiki) { throw "El Wiki está deshabilitado en $Repo. Actívalo en Settings → Features → Wikis y reintenta." }

$wikiUrl = "https://github.com/$Repo.wiki.git"
Write-Host "=== docs-wiki  $Repo ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Identidad : $login  (via $TokenVar)"
Write-Host "  Páginas   : $($pages.Count) ($($pages.Keys -join ', '))"
Write-Host "  Wiki      : $wikiUrl"
Write-Host ""

if ($DryRun) {
    Write-Host "DRY-RUN: no se clona ni se empuja nada." -ForegroundColor Yellow
    if ($Json) {
        [pscustomobject]@{ repo=$Repo; pages=@($pages.Keys); wikiUrl=$wikiUrl; dryRun=$true } |
            ConvertTo-Json -Depth 6
    }
    return
}

# ── Clone the wiki, write pages, commit, push ────────────────────────────────────────
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("docswiki-" + [guid]::NewGuid().ToString('N'))
$helper = 'credential.helper=!f(){ echo username=x-access-token; echo password=$ABIOS_WIKI_TOKEN; };f'
$env:ABIOS_WIKI_TOKEN = $token
try {
    git -c credential.helper= -c $helper clone --quiet $wikiUrl $tmp 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw @"
ERROR: El repositorio wiki de $Repo aún no está inicializado.

GitHub crea el wiki git repo de forma lazy: no existe hasta que se guarda
la primera página desde la interfaz web. No hay endpoint REST para crearlo.

Para inicializarlo:
  1. Abre https://github.com/$Repo/wiki en el navegador
  2. Haz clic en "Create the first page"
  3. Escribe cualquier contenido y pulsa "Save Page"
  4. Vuelve a ejecutar este comando

"@
    }
    foreach ($name in $pages.Keys) {
        $pages[$name] | Set-Content -LiteralPath (Join-Path $tmp "$name.md") -Encoding utf8
    }
    git -C $tmp add -A
    $status = git -C $tmp status --porcelain
    if (-not $status) {
        Write-Host "OK  Wiki ya estaba al día (sin cambios)." -ForegroundColor Green
    } else {
        git -C $tmp -c user.name='agentic-board' -c user.email='noreply@agentic-board' `
            commit --quiet -m "docs: publish wiki ($($pages.Count) páginas, $Date)"
        if ($LASTEXITCODE -ne 0) { throw "git commit falló (exit $LASTEXITCODE)." }
        git -c credential.helper= -c $helper -C $tmp push --quiet origin HEAD:master
        if ($LASTEXITCODE -ne 0) { throw "git push al wiki falló (exit $LASTEXITCODE)." }
        Write-Host "OK  Wiki publicado ($($pages.Count) páginas)." -ForegroundColor Green
    }
} finally {
    Remove-Item Env:ABIOS_WIKI_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$viewUrl = "https://github.com/$Repo/wiki"
Write-Host "  Ver: $viewUrl"
if ($Json) {
    [pscustomobject]@{ repo=$Repo; pages=@($pages.Keys); wikiUrl=$wikiUrl; viewUrl=$viewUrl } |
        ConvertTo-Json -Depth 6
}
