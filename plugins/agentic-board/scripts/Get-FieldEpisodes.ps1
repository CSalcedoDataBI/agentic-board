<#
.SYNOPSIS
    Stage 2 of /board field (#476) — turn transcript events into candidate episodes.

.DESCRIPTION
    The deterministic half of the field sweep: no model. It finds every agentic-board invocation
    and classifies what happened around it into four mechanical signals — repetition, abandonment,
    correction, silence. Hundreds of megabytes go in; a few hundred episodes come out, and only
    those are worth a model's attention.

    Every detector is written to be wrong in the cheap direction: when the shape is ambiguous it
    stays quiet. A sweep that flags everything is indistinguishable from a sweep that flags
    nothing.

    Pure core behind $env:ABIOS_FIELDEPISODES_DOTSOURCE for unit tests.

.EXAMPLE
    . .\Get-FieldEpisodes.ps1 ; Get-FieldEpisodes -Events $ev -Window 6
#>
[CmdletBinding()]
param(
    [string]$Path,
    [int]$FromEvent = 0,
    [int]$Window = 6,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ── Pure core ───────────────────────────────────────────────────────────────────

$script:ToolCommandPattern = '(?i)(/agentic-board:[a-z-]+|(?<![\w/])/board)\b'

# The set of plugin scripts is read from the directory this file lives in — it IS that directory.
# Guessing by verb prefix was wrong (New-BoardPR.ps1, Add-KnowledgeRef.ps1 and Invoke-Gh.ps1 do not
# start with Board-/Expert-), and an embedded list would drift every time a script is added.
$script:KnownScripts = @{}
try {
    foreach ($f in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File -ErrorAction Stop) {
        $script:KnownScripts[$f.Name.ToLowerInvariant()] = $true
    }
} catch { }

function Get-InvokedTool {
    <#  Returns the tool this command invokes, or $null. Plain gh/git must never count: treating
        them as tool usage would report agentic-board in sessions that never touched it. Matching
        the leaf name makes the long version-pinned cache path in front of it irrelevant (#470). #>
    [CmdletBinding()]
    param([string]$Command)
    if (-not $Command) { return $null }

    foreach ($m in [regex]::Matches($Command, '(?i)([A-Za-z][A-Za-z0-9]*-[A-Za-z][A-Za-z0-9]*\.ps1)')) {
        $leaf = $m.Groups[1].Value
        if ($script:KnownScripts.ContainsKey($leaf.ToLowerInvariant())) { return $leaf }
        # A script the local checkout does not have is still the tool's when the path says so.
        if ($Command -match '(?i)agentic-board') { return $leaf }
    }

    $c = [regex]::Match($Command, $script:ToolCommandPattern)
    if ($c.Success) { return $c.Groups[1].Value }
    $null
}

function Test-IsFallbackCommand {
    # Doing the job by hand: bare gh/git, with no plugin script involved.
    [CmdletBinding()]
    param([string]$Command)
    if (-not $Command) { return $false }
    if (Get-InvokedTool -Command $Command) { return $false }
    [bool]([regex]::IsMatch($Command, '(?im)(^|[;&|]\s*)(gh|git)\s+\w'))
}

function Test-IsCorrection {
    <#  A correction is the user reversing what just happened. Kept deliberately narrow: "no" alone
        is far too common in Spanish to mean disagreement ("no hay problema"). #>
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return $false }
    $t = $Text.ToLowerInvariant()
    $patterns = @(
        'no,\s', '\beso (no|est[aá] mal)\b', '\bestá mal\b', '\besta mal\b',
        '\brevi[eé]rte?lo\b', '\brevierte\b', '\bdeshaz\b', '\bno era eso\b',
        '\bte equivocaste\b', '\bmal\b.*\bcorrige\b', '\bundo\b', '\bthat.s wrong\b'
    )
    foreach ($p in $patterns) { if ([regex]::IsMatch($t, $p)) { return $true } }
    $false
}

function Get-FieldEpisodes {
    <#  One episode per invocation, carrying the signals observed in the following window. The
        event index travels with it so every claim can be traced back to the transcript. #>
    [CmdletBinding()]
    param([object[]]$Events, [int]$Window = 6)

    $ev = @($Events | Where-Object { $_ })
    $out = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $ev.Count; $i++) {
        $tool = Get-InvokedTool -Command $ev[$i].command
        if (-not $tool) { continue }

        $signals = [System.Collections.Generic.List[string]]::new()
        $failed  = [bool]$ev[$i].isError

        $sawSameTool = $false; $sawAnyTool = $false; $sawFallback = $false; $sawCorrection = $false
        for ($j = $i + 1; $j -lt $ev.Count; $j++) {
            if (($ev[$j].index - $ev[$i].index) -gt $Window) { break }
            $t2 = Get-InvokedTool -Command $ev[$j].command
            if ($t2) {
                $sawAnyTool = $true
                if ($t2 -eq $tool) { $sawSameTool = $true }
            }
            elseif (Test-IsFallbackCommand -Command $ev[$j].command) { $sawFallback = $true }
            if ($ev[$j].role -eq 'user' -and (Test-IsCorrection -Text $ev[$j].text)) { $sawCorrection = $true }
        }

        if ($sawSameTool) { $signals.Add('repetition') }
        # Abandonment needs BOTH a failure and a hand-rolled substitute. A failure followed by a
        # retry of the tool is a retry, not abandonment.
        if ($failed -and $sawFallback -and -not $sawSameTool) { $signals.Add('abandonment') }
        if ($sawCorrection) { $signals.Add('correction') }
        if (-not $sawAnyTool -and -not $sawFallback -and -not $sawCorrection) { $signals.Add('silence') }

        $out.Add([pscustomobject]@{
            index   = $ev[$i].index
            tool    = $tool
            failed  = $failed
            signals = $signals.ToArray()
        })
    }
    $out.ToArray()
}

function Protect-FieldText {
    <#  Redaction before anything leaves the machine. Over-redaction is its own failure: an episode
        scrubbed into unreadability teaches nothing, so this targets secrets and the home path
        only. #>
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text

    # Token shapes, leading with a character class so this line never matches itself.
    $t = [regex]::Replace($t, '[g]h[pousr]_[A-Za-z0-9]{16,}', '<REDACTED-TOKEN>')
    $t = [regex]::Replace($t, '[g]ithub_pat_[A-Za-z0-9_]{20,}', '<REDACTED-TOKEN>')
    $t = [regex]::Replace($t, '(?i)(authorization:\s*(bearer|token)\s+)\S+', '$1<REDACTED-TOKEN>')

    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    $leaf = if ($userHome) { Split-Path $userHome -Leaf } else { $null }
    if ($leaf) {
        $t = [regex]::Replace($t, [regex]::Escape($leaf), '<USER>')
    }
    $t
}

function ConvertTo-FieldEvent {
    <#  Normalizes one raw transcript line into the shape the detectors consume. Unknown shapes
        return $null rather than a half-filled object — a malformed line must not become a
        phantom episode. #>
    [CmdletBinding()]
    param([string]$Line, [int]$Index)
    if (-not $Line) { return $null }
    try { $o = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $o.type) { return $null }
    if ($o.type -ne 'assistant' -and $o.type -ne 'user') { return $null }

    $cmd = ''; $text = ''; $isErr = $false
    $useIds  = [System.Collections.Generic.List[string]]::new()
    $failedFor = [System.Collections.Generic.List[string]]::new()

    $content = $o.message.content
    foreach ($c in @($content)) {
        if (-not $c) { continue }
        switch ($c.type) {
            'tool_use'    {
                if ($c.input.command) { $cmd += "$($c.input.command)`n" }
                if ($c.id) { $useIds.Add([string]$c.id) }
            }
            'tool_result' {
                if ($c.is_error) { $isErr = $true; if ($c.tool_use_id) { $failedFor.Add([string]$c.tool_use_id) } }
            }
            'text'        { $text += "$($c.text)`n" }
        }
    }
    if (-not $cmd -and $o.message.content -is [string]) { $text = [string]$o.message.content }

    [pscustomobject]@{
        index = $Index; role = $o.type; command = $cmd.Trim(); isError = $isErr; text = $text.Trim()
        toolUseIds = $useIds.ToArray(); failedFor = $failedFor.ToArray()
    }
}

function Join-FieldResults {
    <#  A tool_result arrives in its OWN later event, so the invocation itself never carries the
        failure. Without this correlation `isError` is always false on the event that holds the
        command, and `abandonment` — which requires a failure — can never fire on a real
        transcript. The synthetic fixtures hid this: they set isError directly. #>
    [CmdletBinding()]
    param([object[]]$Events)
    $ev = @($Events | Where-Object { $_ })

    $failed = @{}
    foreach ($e in $ev) { foreach ($id in @($e.failedFor)) { if ($id) { $failed[$id] = $true } } }

    foreach ($e in $ev) {
        if ($e.isError) { continue }
        foreach ($id in @($e.toolUseIds)) {
            if ($id -and $failed.ContainsKey($id)) { $e.isError = $true; break }
        }
    }
    $ev
}

# Dot-source guard: tests load the pure core only.
if ($env:ABIOS_FIELDEPISODES_DOTSOURCE) { return }

# ── CLI: extract episodes from one transcript ───────────────────────────────────
if (-not $Path) { throw "Get-FieldEpisodes.ps1: -Path <transcript.jsonl> is required." }
if (-not (Test-Path -LiteralPath $Path)) { throw "Get-FieldEpisodes.ps1: no such transcript: $Path" }

$events = [System.Collections.Generic.List[object]]::new()
$i = 0
# Streamed: these files reach tens of MB and must never be loaded whole.
$reader = [System.IO.File]::OpenText($Path)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($i -ge $FromEvent) {
            $e = ConvertTo-FieldEvent -Line $line -Index $i
            if ($e) { $events.Add($e) }
        }
        $i++
    }
} finally { $reader.Dispose() }

$linked   = Join-FieldResults -Events $events.ToArray()
$episodes = Get-FieldEpisodes -Events $linked -Window $Window
$result = [pscustomobject]@{
    path      = $Path
    events    = $i
    fromEvent = $FromEvent
    usedTool  = [bool](@($episodes).Count -gt 0)
    episodes  = @($episodes)
}
if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }
