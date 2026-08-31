<#  Worktree-Ghosts.ps1 - inventory of managed worktree directories that git no longer knows.

    THE GAP THIS CLOSES (#618). The doctor's existing ghost check trusts git's own `prunable`
    marker, which git sets when the METADATA survives but the DIRECTORY is gone. The inverse
    case is invisible to it: the directory is still on disk under `.claude/worktrees/`, but its
    `.git` link is broken, so git already pruned its metadata and the worktree does not appear
    in `git worktree list` at all. Never listed -> never a record -> never `prunable`.

    Those orphans are not inert. The agent host keeps them in a machine-wide registry and
    retries pruning them on a timer; every attempt fails and the cycle repeats, piling up failed
    git invocations. On repos that live on slow disks the cost is felt, not theoretical.

    They are born from abnormal session termination: the directory survives, the lease is never
    released.

    FOUR STATES, and the difference between the last two is the whole safety story:

      ok             git lists it, directory present            leave alone
      prunable       git lists it, directory gone               `git worktree prune` (existing)
      orphan-empty   directory present + EMPTY, git blind       safe to auto-remove
      orphan-content directory present + FILES, git blind       REPORT ONLY - may hold work

    `orphan-empty` is the only class anything here removes automatically, and the removal is a
    NON-RECURSIVE delete that fails when the directory is not empty. The emptiness check and the
    delete are therefore not a promise made twice - the filesystem enforces it. A race that drops
    a file between the two loses nothing: the delete simply fails.

    Dot-source guard: set $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE=1 to load the helpers for Pester
    without touching git or the filesystem.
#>
[CmdletBinding()]
param()

# The directory an agent host manages inside a repo. Worktrees anywhere else are somebody
# else's business and are never classified, never reported and never removed.
$script:ManagedRelPath = '.claude/worktrees'

# ------------------------------------------------------------------------------
# PURE CORE. Every fact arrives as an argument - no git, no gh, no filesystem.
# ------------------------------------------------------------------------------

# Classify ONE worktree from facts the caller gathered.
#
#   $KnownToGit   does `git worktree list` mention this path?
#   $PathExists   is the directory on disk?
#   $IsEmpty      does it contain zero files? (only meaningful when $PathExists)
#
# `prunable` is deliberately derived from (known + absent) rather than read from git's marker,
# so one predicate covers both directions and the tests can pin them side by side.
function Get-WorktreeGhostClass {
    param(
        [Parameter(Mandatory)][bool]$KnownToGit,
        [Parameter(Mandatory)][bool]$PathExists,
        [bool]$IsEmpty = $false
    )
    if ($KnownToGit) {
        if ($PathExists) { return 'ok' }
        return 'prunable'
    }
    # Not known to git. A path that does not exist is not an orphan directory - there is
    # nothing on disk to orphan, and saying otherwise would invent work.
    if (-not $PathExists) { return 'ok' }
    if ($IsEmpty) { return 'orphan-empty' }
    return 'orphan-content'
}

# Is this class safe to delete without asking a human? Exactly one is.
#
# AllowEmptyString is deliberate: a malformed or missing class must RETURN false, not throw.
# This sits on the delete path inside a hook that swallows exceptions, so a throw here would
# read as "skipped" and hide a real bug. Refusing is the answer that is safe either way, and
# the comparison is case-sensitive so a near-miss like 'Orphan-Empty' is refused too.
function Test-WorktreeAutoRemovable {
    param([AllowEmptyString()][string]$Class)
    return $Class -ceq 'orphan-empty'
}

# Normalize a path for comparison against `git worktree list`, which reports forward slashes
# on Windows while the filesystem hands back backslashes. Casing is folded because Windows
# paths are case-insensitive; on case-sensitive filesystems this can only merge entries that
# the agent host would not have created differently anyway.
function ConvertTo-ComparablePath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# Parse the paths out of `git worktree list --porcelain` output. Pure: takes the text.
function Get-WorktreePathsFromPorcelain {
    param([string]$Porcelain)
    if (-not $Porcelain) { return @() }
    $paths = @()
    foreach ($line in ($Porcelain -split "`r?`n")) {
        if ($line -match '^worktree\s+(.+)$') { $paths += (ConvertTo-ComparablePath $matches[1]) }
    }
    return $paths
}

# The NAMES of the worktrees git knows that live in a managed directory.
#
# WHY NAMES AND NOT PATHS. Comparing absolute paths looked obvious and is wrong: git prints the
# path it recorded while the filesystem hands back whatever alias you walked in through - an 8.3
# short name (C:\Users\CRISTO~1\...), a junction, a substituted drive. The two strings differ for
# the same directory, the worktree looks unknown to git, and a LIVE worktree gets classified as
# an orphan. An empty one would then be swept. Caught by running it against a real repo.
#
# Every managed worktree is a direct child of `.claude/worktrees/`, so within that one directory
# a name is unique and is the only part of the path both sides agree on. Matching the parent by
# SUFFIX keeps the comparison clear of the aliased prefix entirely.
function Get-KnownWorktreeNames {
    param(
        [string]$Porcelain,
        [string]$ManagedRelPath = '.claude/worktrees'
    )
    $suffix = ConvertTo-ComparablePath $ManagedRelPath
    $names = @()
    foreach ($p in (Get-WorktreePathsFromPorcelain $Porcelain)) {
        $parent = ConvertTo-ComparablePath (Split-Path $p -Parent)
        if ($parent.EndsWith($suffix)) { $names += (Split-Path $p -Leaf) }
    }
    return $names
}

# Decide which registry entries are stale. Pure: the caller supplies the existence verdict,
# so this stays testable without a filesystem.
#
# $Entries: objects with .Name and .Path; $ExistsMap: hashtable comparable-path -> [bool].
function Select-StaleRegistryEntries {
    param(
        [object[]]$Entries = @(),
        [hashtable]$ExistsMap = @{}
    )
    $stale = @()
    foreach ($e in $Entries) {
        if (-not $e.Path) { continue }
        $key = ConvertTo-ComparablePath $e.Path
        if (-not $ExistsMap.ContainsKey($key) -or -not $ExistsMap[$key]) { $stale += $e }
    }
    return $stale
}

# ------------------------------------------------------------------------------
# IMPURE EDGE. Thin wrappers that gather the facts the pure core consumes.
# ------------------------------------------------------------------------------

# Where the agent host keeps its machine-wide worktree registry. Returns $null when the host
# is not installed - a perfectly normal state that must not be an error.
function Get-WorktreeRegistryPath {
    $roots = @()
    if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'Claude') }
    if ($env:HOME)    { $roots += (Join-Path $env:HOME 'Library/Application Support/Claude') }
    if ($HOME)        { $roots += (Join-Path $HOME '.config/Claude') }
    foreach ($r in $roots) {
        $p = Join-Path $r 'git-worktrees.json'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# Read the registry into {Name, Path} objects. Never throws: an unreadable or malformed
# registry means "no entries", not a failed audit.
function Get-RegistryWorktrees {
    param([string]$RegistryPath)
    if (-not $RegistryPath) { $RegistryPath = Get-WorktreeRegistryPath }
    if (-not $RegistryPath -or -not (Test-Path -LiteralPath $RegistryPath)) { return @() }
    try {
        $json = Get-Content -LiteralPath $RegistryPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch { return @() }
    if (-not $json.worktrees) { return @() }
    $out = @()
    foreach ($p in $json.worktrees.PSObject.Properties) {
        $out += [pscustomobject]@{ Name = $p.Name; Path = [string]$p.Value.path }
    }
    return $out
}

# Does this directory hold zero files? Recursive, because a worktree whose only content is an
# empty nested directory still holds nothing worth protecting.
function Test-DirectoryEmpty {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $f = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction Stop
        return (@($f).Count -eq 0)
    } catch {
        # Unreadable -> treat as NOT empty. Refusing to call something empty is the safe
        # failure: the worst outcome is that a human is asked about a directory that was junk.
        return $false
    }
}

# The full inventory for ONE repo: every directory under the managed path, classified.
function Get-WorktreeGhosts {
    param(
        [string]$RepoRoot = '.',
        [string]$Porcelain
    )
    $managed = Join-Path $RepoRoot ($script:ManagedRelPath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $managed)) { return @() }

    # IsNullOrEmpty, NOT `$null -eq`: an unbound [string] parameter arrives as '', never $null,
    # so the null check silently skipped the git call and left the known-set empty - which
    # classifies EVERY live worktree as an orphan. The pure tests could not see it because they
    # all pass -Porcelain explicitly; only running it against a real repo showed it.
    if ([string]::IsNullOrEmpty($Porcelain)) {
        $Porcelain = (& git -C $RepoRoot worktree list --porcelain 2>$null) -join "`n"
    }
    # Names, not paths - see Get-KnownWorktreeNames for why the obvious version was unsafe.
    $known = @(Get-KnownWorktreeNames -Porcelain $Porcelain -ManagedRelPath $script:ManagedRelPath)

    $out = @()
    foreach ($d in (Get-ChildItem -LiteralPath $managed -Directory -Force -ErrorAction SilentlyContinue)) {
        $isKnown = $known -contains $d.Name
        $empty   = if ($isKnown) { $false } else { Test-DirectoryEmpty $d.FullName }
        $class   = Get-WorktreeGhostClass -KnownToGit $isKnown -PathExists $true -IsEmpty $empty
        if ($class -eq 'ok') { continue }
        $out += [pscustomobject]@{
            Name          = $d.Name
            Path          = $d.FullName
            Class         = $class
            AutoRemovable = (Test-WorktreeAutoRemovable $class)
        }
    }
    return $out
}

# Remove ONE orphan directory. The delete is non-recursive on purpose: .NET refuses to delete a
# non-empty directory, so the filesystem - not this code - is what guarantees no work is lost.
# Returns $true only when the directory is actually gone.
function Remove-EmptyWorktreeOrphan {
    param([Parameter(Mandatory)][string]$Path)
    try {
        [System.IO.Directory]::Delete($Path, $false)   # $false = non-recursive
        return -not (Test-Path -LiteralPath $Path)
    } catch {
        return $false
    }
}

if ($env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE) { return }
