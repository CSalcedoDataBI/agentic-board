<#
.SYNOPSIS
    Find-FilesPruned — a directory walk that never DESCENDS into the directories it would only
    discard afterwards, with a depth cap and a wall-clock budget.

.DESCRIPTION
    Dot-source this file; it defines one function and runs nothing.

    `Get-ChildItem -Recurse -Filter X | Where-Object { path has no /node_modules/ }` visits every
    file of every excluded directory first and filters afterwards, so a working tree with a
    node_modules/ (or a plugin cache holding every cached version of every plugin) costs the full
    walk even when nothing in it can match. This walker prunes the excluded names BEFORE
    descending, so their cost is zero. It also:

      - does not follow symlinks / junctions (same as Get-ChildItem -Recurse on PowerShell 7,
        and the thing that keeps a link cycle from walking forever);
      - stops at -MaxDepth directory levels below the root;
      - stops at -Deadline (a [datetime]) and says so with a warning, so a partial result is
        never mistaken for a complete one.

    -UnderDirNamed restricts the result to files that sit below a directory of that name (the
    root itself counts when its own path contains the segment) — that is how agent definitions
    (`<root>/**/agents/*.md`) are found without reading every other markdown file of the tree.

.PARAMETER Root
    Directory to walk. A missing root yields nothing.
.PARAMETER Filter
    Wildcard the leaf file name must match (e.g. 'SKILL.md', '*.md').
.PARAMETER ExcludeDirs
    Directory names (any depth below Root, case-insensitive) that are never entered.
.PARAMETER UnderDirNamed
    Only emit files that have an ancestor directory with this name.
.PARAMETER Deadline
    Stop walking when [datetime]::UtcNow passes it. Default: no limit.
.PARAMETER MaxDepth
    Directory levels below Root that are still entered. Default 40.
.PARAMETER State
    A hashtable the caller keeps. On an exhausted budget the walk sets State.Partial = $true, so a
    caller can tell "found nothing" from "stopped before it finished looking" (the warning alone
    is not visible to code). It is only ever set to $true, never reset.
.PARAMETER CheckEvery
    While listing ONE directory, the deadline is re-checked every this many entries, so a single
    huge directory cannot run past the budget. Default 256. The one thing that cannot be bounded is
    a single blocking call into the file system (a stalled network share): the budget is honoured
    between entries, not inside the OS call.
.PARAMETER Clock
    Test seam: returns "now". Default [datetime]::UtcNow.
#>

$script:PrunedWalkDefaultExclude = @('node_modules','.git','dist','build','vendor','bin','obj','out','.next','coverage')

function Find-FilesPruned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Filter,
        [string[]]$ExcludeDirs = $script:PrunedWalkDefaultExclude,
        [string]$UnderDirNamed = '',
        [datetime]$Deadline = [datetime]::MaxValue,
        [int]$MaxDepth = 40,
        [hashtable]$State,
        [int]$CheckEvery = 256,
        [scriptblock]$Clock = { [datetime]::UtcNow }
    )
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }

    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($ExcludeDirs)) { if ($d) { [void]$skip.Add($d) } }

    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $rootUnder = $true
    if ($UnderDirNamed) {
        $rootUnder = (($rootFull -replace '\\','/') -split '/') -contains $UnderDirNamed
    }

    $found = [System.Collections.Generic.List[string]]::new()
    # Depth-first with an explicit stack: no recursion limit, and the deadline is checked per dir.
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@($rootFull, 0, $rootUnder))
    $timedOut = $false
    if ($CheckEvery -lt 1) { $CheckEvery = 1 }

    while ($stack.Count -gt 0) {
        if ((& $Clock) -gt $Deadline) { $timedOut = $true; break }
        $frame = $stack.Pop()
        $dir = $frame[0]; $depth = $frame[1]; $under = $frame[2]

        if ($under) {
            $n = 0
            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $Filter)) {
                    if ((++$n % $CheckEvery) -eq 0 -and (& $Clock) -gt $Deadline) { $timedOut = $true; break }
                    # The OS-level pattern can over-match (8.3 names); re-check the leaf exactly.
                    if ([System.IO.Path]::GetFileName($f) -like $Filter) { $found.Add($f) }
                }
            } catch { <# unreadable directory: skip it, keep walking #> }
            if ($timedOut) { break }
        }

        if ($depth -ge $MaxDepth) { continue }
        $subs = [System.Collections.Generic.List[object]]::new()
        $n = 0
        try {
            # DirectoryInfo carries the attributes from the listing itself, so there is no second
            # per-entry call that could throw and abandon the siblings already collected.
            foreach ($di in [System.IO.DirectoryInfo]::new($dir).EnumerateDirectories()) {
                if ((++$n % $CheckEvery) -eq 0 -and (& $Clock) -gt $Deadline) { $timedOut = $true; break }
                $leaf = $di.Name
                if ($skip.Contains($leaf)) { continue }
                if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $subs.Add(@($di.FullName, ($depth + 1), ($under -or ($UnderDirNamed -and $leaf -eq $UnderDirNamed))))
            }
        } catch { <# unreadable directory: keep whatever was listed before the failure #> }
        if ($timedOut) { break }
        # Pushed in reverse so the first subdirectory is popped first: the same pre-order
        # (a directory's files, then each subdirectory in turn) Get-ChildItem -Recurse gives,
        # so results keep the order callers already saw. Outside the try: a listing that fails
        # part-way still descends into the subdirectories it did return.
        for ($k = $subs.Count - 1; $k -ge 0; $k--) { $stack.Push($subs[$k]) }
    }

    if ($timedOut) {
        if ($State) { $State.Partial = $true }
        Write-Warning "scan of '$Root' stopped at its time budget - the result is PARTIAL."
    }
    # Callers wrap the call in @( ) so an empty or single-file result keeps its shape.
    $found.ToArray()
}
