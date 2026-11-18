<#
.SYNOPSIS
    Builds (never pushes) the next commit of the `stable` branch: the tree holds ONLY
    plugins/agentic-board/ taken from a released commit, and its parent is the current
    origin/stable, so pushing it is a fast-forward.

.DESCRIPTION
    The Anthropic plugin directory tracks `stable` and scans every file on it (#768). A commit of
    the whole repository brings scripts, workflows and tests along, and the directory refuses
    those. So `stable` carries one folder, copied from the released commit with git plumbing
    (a throw-away index + `git commit-tree`): no checkout, no working-tree changes, the blobs are the
    released ones byte for byte.

    Before it builds anything it checks what the directory accepts: allowed file types only, no
    file that starts with `#!`, no `hooks/` folder and no `hooks` key in plugin.json, no `.claude/`
    folder, fewer than 512 files. Any finding stops it with exit 1 and builds nothing.

    Push is left to a person, after measuring the commit with the plugin-directory measurer:
        git push origin <sha>:refs/heads/stable
    A plain push (never --force): a non-fast-forward is refused by git.

.PARAMETER Rev
    The released commit to take the plugin folder from. Default: HEAD.

.PARAMETER Remote
    Remote that holds `stable`. Default: origin.

.EXAMPLE
    pwsh scripts/Build-Stable.ps1 -Rev v0.45.0
#>
[CmdletBinding()]
param(
    [string]$Rev = 'HEAD',
    [string]$Remote = 'origin',
    [string]$Branch = 'stable',
    [string]$PluginPath = 'plugins/agentic-board',
    [switch]$NoFetch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Allowed = @('.md', '.txt', '.json', '.yaml', '.yml', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico')
$script:MaxFiles = 512

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)." }
    $out
}

# Every reason the directory would refuse this tree; empty means it can be built.
function Get-StableFindings {
    param([string]$TreeSha)
    $findings = [System.Collections.Generic.List[string]]::new()
    $entries = @(Invoke-Git ls-tree -r --full-tree $TreeSha)
    if ($entries.Count -ge $script:MaxFiles) { $findings.Add("$($entries.Count) files (limit is below $script:MaxFiles)") }
    foreach ($line in $entries) {
        # <mode> SP <type> SP <sha> TAB <path>
        $meta, $path = $line -split "`t", 2
        $mode, $type, $sha = $meta -split ' '
        if ($type -ne 'blob') { $findings.Add("$path is a $type, not a file"); continue }
        if ($mode -eq '120000') { $findings.Add("$path is a symbolic link") }
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($ext -notin $script:Allowed) { $findings.Add("$path has a type the directory refuses ($(if ($ext) { $ext } else { 'no extension' }))") }
        if ($path -match '(^|/)hooks/') { $findings.Add("$path is in a hooks/ folder") }
        if ($path -match '(^|/)\.claude/') { $findings.Add("$path is in a .claude/ folder") }
        $blob = @(& git cat-file blob $sha 2>$null)
        $head = if ($blob.Count) { [string]$blob[0] } else { '' }
        if ($head -and $head.TrimStart([char]0xFEFF).StartsWith('#!')) { $findings.Add("$path starts with #!") }
    }
    $manifest = $entries | Where-Object { $_ -match "`t\.claude-plugin/plugin\.json$" } | Select-Object -First 1
    if (-not $manifest) {
        $findings.Add('.claude-plugin/plugin.json is missing')
    } else {
        $sha = (($manifest -split "`t")[0] -split ' ')[2]
        $json = (Invoke-Git cat-file blob $sha) -join "`n" | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'hooks') { $findings.Add('plugin.json declares hooks') }
    }
    $findings.ToArray()
}

if ($env:ABIOS_BUILDSTABLE_DOTSOURCE -eq '1') { return }

$commit = (Invoke-Git rev-parse --verify "$Rev^{commit}").Trim()
$subtree = (Invoke-Git rev-parse --verify "${commit}:$PluginPath").Trim()
$version = ((Invoke-Git cat-file blob "${commit}:$PluginPath/.claude-plugin/plugin.json") -join "`n" | ConvertFrom-Json).version

$findings = @(Get-StableFindings -TreeSha $subtree)
if ($findings.Count) {
    Write-Host "Not built: $($findings.Count) finding(s) in $PluginPath at $commit."
    $findings | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

# A throw-away index rebuilds the nested path, so the directory's fixed Plugin path still resolves.
# (Piping entries into `git mktree` from pwsh on Windows appends CR to every name.)
$tmpIndex = Join-Path ([System.IO.Path]::GetTempPath()) ('stable-index-' + [guid]::NewGuid().ToString('N'))
$savedIndex = $env:GIT_INDEX_FILE
try {
    $env:GIT_INDEX_FILE = $tmpIndex
    Invoke-Git read-tree --empty | Out-Null
    Invoke-Git read-tree "--prefix=$($PluginPath.Trim('/'))/" $subtree | Out-Null
    $tree = (Invoke-Git write-tree).Trim()
} finally {
    $env:GIT_INDEX_FILE = $savedIndex
    Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
}

if (-not $NoFetch) { & git fetch --quiet $Remote "+refs/heads/${Branch}:refs/remotes/$Remote/$Branch" 2>$null }
$parent = (& git rev-parse --verify --quiet "refs/remotes/$Remote/$Branch" 2>$null)
$parentArgs = @()
if ($LASTEXITCODE -eq 0 -and $parent) {
    $parent = $parent.Trim()
    if ((Invoke-Git rev-parse "$parent^{tree}").Trim() -eq $tree) {
        Write-Host "Unchanged: $Remote/$Branch ($parent) already holds this tree. Nothing to push."
        exit 0
    }
    $parentArgs = @('-p', $parent)
}

$new = (& git commit-tree $tree @parentArgs -m "release: agentic-board $version" -m "$PluginPath/ from $commit, nothing else.").Trim()
if ($LASTEXITCODE -ne 0) { throw 'git commit-tree failed.' }

$files = @(Invoke-Git ls-tree -r --name-only $new).Count
Write-Host "Built $new (agentic-board $version, $files files, parent $(if ($parentArgs) { $parent } else { 'none' }))."
Write-Host "Measure it, then push with: git push $Remote ${new}:refs/heads/$Branch"
$new
