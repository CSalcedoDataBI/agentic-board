<#
.SYNOPSIS
    The house diagram theme: the header for an inline ```mermaid block, and light/dark SVGs
    generated from .mmd sources.

.DESCRIPTION
    The theme lives in skills/diagram-authoring/theme.json; the rules for using it are in that
    skill's SKILL.md. Three actions:

      header  [-Type "flowchart TB"]  print what opens an inline ```mermaid block: the %%{init}%%
                                      line (theme base + light colors) and, for a flowchart, the
                                      standard classDefs (frame, card, root, branch, leaf, warn,
                                      external).
      generate [-Root <repo>]         every <x>.mmd -> <x>-light.svg and <x>-dark.svg, through
                                      mermaid-cli via npx (needs Node; the version is pinned in
                                      theme.json). Only stale SVGs are rebuilt.
      check   [-Root <repo>]          browser-free, for CI: exit 1 when an SVG is missing, stale
                                      (source or theme changed) or edited by hand.

    The .mmd is the source and carries no theme: the script adds the init and the classes. Each
    SVG carries the repo brand in its bottom-right corner (Get-DiagBrand) and starts with a stamp (hash of the themed source, and of the SVG itself), so 'check' needs
    neither Node nor a browser. An SVG is never edited by hand: change the .mmd and regenerate.

    Functions sit behind a dot-source guard ($env:ABIOS_DIAGRAMTHEME_DOTSOURCE) for the tests.

.EXAMPLE
    pwsh Diagram-Theme.ps1 header -Type sequenceDiagram
.EXAMPLE
    pwsh Diagram-Theme.ps1 generate -Root .
.EXAMPLE
    pwsh Diagram-Theme.ps1 check -Root .
    Needs PowerShell 7: Windows PowerShell 5.1 writes utf8 with a BOM, which changes the SVG hash.
#>
#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('header', 'generate', 'check')][string]$Action,
    [string]$Root,
    [string]$Type = 'flowchart TB'
)

$script:DiagThemePath = Join-Path $PSScriptRoot '..' 'skills' 'diagram-authoring' 'theme.json'
$script:DiagStampPattern = '^<!-- diagram-theme src:(?<src>[0-9a-f]{64}) svg:(?<svg>[0-9a-f]{64}) -->\n'
# Diagram types that accept classDef lines after their first line.
$script:DiagWithClasses = '^(flowchart|graph)\b'

function Get-DiagTheme {
    param([string]$Path = $script:DiagThemePath)
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Get-DiagHash {
    param([AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Text -replace "`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
}

function Get-DiagInit {
    # The %%{init}%% line. -Svg adds what only works outside GitHub's viewer: labels as <text>
    # (an SVG served as an image loses foreignObject HTML) and themeCSS (GitHub strips it).
    param($Theme, [ValidateSet('light', 'dark')][string]$Mode = 'light', [switch]$Svg)
    $fc = [ordered]@{}
    foreach ($k in 'curve', 'nodeSpacing', 'rankSpacing', 'padding') { $fc[$k] = $Theme.flowchart.$k }
    if ($Svg) { foreach ($p in $Theme.flowchart.svgOnly.PSObject.Properties) { $fc[$p.Name] = $p.Value } }
    $vars = [ordered]@{}
    foreach ($p in ($Theme.$Mode.themeVariables.PSObject.Properties | Sort-Object Name)) { $vars[$p.Name] = $p.Value }
    $init = [ordered]@{ theme = 'base'; themeVariables = $vars; flowchart = $fc }
    if ($Svg) {
        $init.htmlLabels = $false
        # Monochrome icons (mdi:) paint with currentColor: without this they come out black in dark mode.
        $init.themeCSS = "g{color:$($Theme.$Mode.themeVariables.textColor)}"
    }
    '%%{init: ' + ($init | ConvertTo-Json -Depth 6 -Compress) + '}%%'
}

function Get-DiagClasses {
    param($Theme, [ValidateSet('light', 'dark')][string]$Mode = 'light')
    foreach ($p in $Theme.$Mode.classes.PSObject.Properties) { "    classDef $($p.Name) $($p.Value)" }
}

function Get-DiagHeader {
    # What opens an inline ```mermaid block in a .md: init, diagram type and, for flowcharts, classes.
    param($Theme, [string]$Type = 'flowchart TB')
    $lines = @(Get-DiagInit -Theme $Theme -Mode light) + $Type
    if ($Type -match $script:DiagWithClasses) { $lines += Get-DiagClasses -Theme $Theme -Mode light }
    $lines -join "`n"
}

function Get-DiagThemedSource {
    # The .mmd with the mode's theme applied: init before the first line, classes after it.
    param([string]$Body, $Theme, [ValidateSet('light', 'dark')][string]$Mode)
    # A .mmd's own init is dropped: the script sets the theme (two inits overwrite each other silently).
    $lines = @(($Body -replace "`r`n", "`n").TrimEnd("`n") -split "`n" | Where-Object { $_ -notmatch '^\s*%%\{\s*init' })
    $i = 0
    while ($i -lt $lines.Count -and ($lines[$i] -match '^\s*(%%.*)?$')) { $i++ }
    if ($i -ge $lines.Count) { throw 'The .mmd has no diagram type.' }
    $out = @(Get-DiagInit -Theme $Theme -Mode $Mode -Svg) + $lines[0..$i]
    if ($lines[$i].Trim() -match $script:DiagWithClasses) { $out += Get-DiagClasses -Theme $Theme -Mode $Mode }
    if ($i + 1 -lt $lines.Count) { $out += $lines[($i + 1)..($lines.Count - 1)] }
    $out -join "`n"
}

function Get-DiagBrand {
    # The mark every generated SVG carries in its bottom-right corner. Per repo, from
    # .github/diagram-brand.json: {"text": "...", "icon": "<repo-relative .png>"} or
    # {"enabled": false}. Without that file: "<repo> · <owner>" from the origin remote, no icon.
    param([string]$Root)
    $cfgPath = Join-Path $Root '.github' 'diagram-brand.json'
    $cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    if ($cfg -and $cfg.PSObject.Properties['enabled'] -and -not $cfg.enabled) { return $null }
    $text = if ($cfg -and $cfg.text) { $cfg.text } else {
        $url = git -C $Root remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url -match '[:/](?<owner>[^/:]+)/(?<repo>[^/]+?)(\.git)?/?$') { "$($matches.repo) · $($matches.owner)" }
    }
    if (-not $text) { return $null }
    $icon = $null
    if ($cfg -and $cfg.icon) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $cfg.icon))
        $icon = 'data:image/png;base64,' + [Convert]::ToBase64String($bytes)
    }
    [pscustomobject]@{ Text = $text; Icon = $icon }
}

function Add-DiagBrand {
    # Grows the viewBox by a footer strip and writes the brand there: text right-aligned, icon at
    # the corner. The colors come from the theme mode, so it reads on both pages.
    param([string]$Svg, $Brand, $Theme, [string]$Mode)
    if (-not $Brand) { return $Svg }
    $m = [regex]::Match($Svg, 'viewBox="(?<x>[-\d.]+) (?<y>[-\d.]+) (?<w>[-\d.]+) (?<h>[-\d.]+)"')
    if (-not $m.Success) { throw 'The SVG has no viewBox to add the brand to.' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $x = [double]::Parse($m.Groups['x'].Value, $inv); $y = [double]::Parse($m.Groups['y'].Value, $inv)
    $w = [double]::Parse($m.Groups['w'].Value, $inv); $h = [double]::Parse($m.Groups['h'].Value, $inv)
    $strip = 30; $size = 18
    $right = $x + $w - 4
    $mid = $y + $h + $strip / 2
    $color = $Theme.$Mode.brandColor
    $font = $Theme.$Mode.themeVariables.fontFamily
    $label = [Security.SecurityElement]::Escape($Brand.Text)
    $parts = @()
    if ($Brand.Icon) {
        $right -= $size
        $parts += '<image href="{0}" x="{1}" y="{2}" width="{3}" height="{3}"/>' -f $Brand.Icon, $right.ToString($inv), ($mid - $size / 2).ToString($inv), $size
        $right -= 6
    }
    $parts += '<text x="{0}" y="{1}" text-anchor="end" dominant-baseline="central" font-family="{2}" font-size="12" fill="{3}">{4}</text>' -f $right.ToString($inv), $mid.ToString($inv), $font, $color, $label
    $box = 'viewBox="{0} {1} {2} {3}"' -f $m.Groups['x'].Value, $m.Groups['y'].Value, $m.Groups['w'].Value, ($h + $strip).ToString($inv)
    $Svg = $Svg.Remove($m.Index, $m.Length).Insert($m.Index, $box)
    $end = $Svg.LastIndexOf('</svg>')
    $Svg.Insert($end, '<g class="diagram-brand">' + ($parts -join '') + '</g>')
}

function Get-DiagSourceStamp {
    # What decides whether an SVG is current: the themed source (so a change in how the theme is
    # applied also makes it stale), the mode, the pinned mermaid-cli version and the brand.
    param([string]$Body, $Theme, [string]$Mode, $Brand)
    $mark = if ($Brand) { "$($Brand.Text)`n$(Get-DiagHash ([string]$Brand.Icon))" } else { '' }
    Get-DiagHash ("$Mode`n$($Theme.mermaidCli)`n$mark`n" + (Get-DiagThemedSource -Body $Body -Theme $Theme -Mode $Mode))
}

function Set-DiagStamp {
    param([string]$Svg, [string]$SourceStamp)
    $clean = ($Svg -replace "`r`n", "`n") -replace $script:DiagStampPattern, ''
    "<!-- diagram-theme src:$SourceStamp svg:$(Get-DiagHash $clean) -->`n$clean"
}

function Get-DiagOutputs {
    param([string]$Mmd)
    $base = $Mmd -replace '\.mmd$', ''
    [ordered]@{ light = "$base-light.svg"; dark = "$base-dark.svg" }
}

function Find-DiagSources {
    param([string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.mmd |
        Where-Object { ($_.FullName -replace '\\', '/') -notmatch '/(node_modules|\.git|\.claude/worktrees)/' } |
        Sort-Object FullName
}

function Test-DiagSvg {
    # Why the SVG is not valid, or $null when it is current.
    param([string]$Mmd, [string]$Svg, $Theme, [string]$Mode, $Brand)
    if (-not (Test-Path -LiteralPath $Svg)) { return 'missing: run Diagram-Theme.ps1 generate' }
    $text = (Get-Content -LiteralPath $Svg -Raw -Encoding utf8) -replace "`r`n", "`n"
    $m = [regex]::Match($text, $script:DiagStampPattern)
    if (-not $m.Success) { return 'no stamp: not generated by Diagram-Theme.ps1' }
    if ((Get-DiagHash $text.Substring($m.Length)) -ne $m.Groups['svg'].Value) { return 'edited by hand: regenerate it, never edit it' }
    $body = Get-Content -LiteralPath $Mmd -Raw -Encoding utf8
    if ((Get-DiagSourceStamp -Body $body -Theme $Theme -Mode $Mode -Brand $Brand) -ne $m.Groups['src'].Value) {
        return 'stale: the source, the theme or the brand changed; regenerate'
    }
    $null
}

function Test-DiagRepo {
    # One line per SVG that is missing, stale or edited by hand.
    param([string]$Root, $Theme)
    $brand = Get-DiagBrand $Root
    foreach ($f in Find-DiagSources $Root) {
        $outs = Get-DiagOutputs $f.FullName
        foreach ($mode in $outs.Keys) {
            $why = Test-DiagSvg -Mmd $f.FullName -Svg $outs[$mode] -Theme $Theme -Mode $mode -Brand $brand
            if ($why) { "$([IO.Path]::GetRelativePath($Root, $outs[$mode]) -replace '\\', '/'): $why" }
        }
    }
}

function Resolve-DiagRoot {
    param([string]$Root)
    if ($Root) { return (Resolve-Path -LiteralPath $Root).Path }
    $top = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).Path }
    (Get-Location).Path
}

if ($env:ABIOS_DIAGRAMTHEME_DOTSOURCE) { return }

$ErrorActionPreference = 'Stop'

if (-not $Action) { Get-Help $PSCommandPath; exit 2 }
$theme = Get-DiagTheme
switch ($Action) {
    'header' { Get-DiagHeader -Theme $theme -Type $Type }
    'generate' {
        $rootPath = Resolve-DiagRoot $Root
        $brand = Get-DiagBrand $rootPath
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "diagram-theme-$PID"
        New-Item -ItemType Directory -Force $tmp | Out-Null
        try {
            $n = 0
            foreach ($f in Find-DiagSources $rootPath) {
                $body = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8
                $outs = Get-DiagOutputs $f.FullName
                foreach ($mode in $outs.Keys) {
                    if (-not (Test-DiagSvg -Mmd $f.FullName -Svg $outs[$mode] -Theme $theme -Mode $mode -Brand $brand)) { continue }
                    $in = Join-Path $tmp "$mode.mmd"
                    $out = Join-Path $tmp "$mode.svg"
                    Set-Content -LiteralPath $in (Get-DiagThemedSource -Body $body -Theme $theme -Mode $mode) -NoNewline -Encoding utf8
                    $icons = @(foreach ($p in $theme.iconPacks) { '--iconPacksNamesAndUrls'; $p })
                    npx -y "@mermaid-js/mermaid-cli@$($theme.mermaidCli)" -q -i $in -o $out -b transparent @icons 2>&1 | Write-Verbose
                    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $out)) { throw "mermaid-cli failed on $($f.FullName)" }
                    $svg = Add-DiagBrand -Svg (Get-Content -LiteralPath $out -Raw -Encoding utf8) -Brand $brand -Theme $theme -Mode $mode
                    $svg = Set-DiagStamp -Svg $svg -SourceStamp (Get-DiagSourceStamp -Body $body -Theme $theme -Mode $mode -Brand $brand)
                    Set-Content -LiteralPath $outs[$mode] $svg -NoNewline -Encoding utf8
                    Remove-Item -LiteralPath $out
                    Write-Host "  $([IO.Path]::GetRelativePath($rootPath, $outs[$mode]) -replace '\\', '/')"
                    $n++
                }
            }
            Write-Host "$n SVG generated; the rest were already current"
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    'check' {
        $bad = @(Test-DiagRepo -Root (Resolve-DiagRoot $Root) -Theme $theme)
        if ($bad) { $bad | ForEach-Object { Write-Host "x $_" }; exit 1 }
        Write-Host 'ok: diagram SVGs are current'
    }
}
