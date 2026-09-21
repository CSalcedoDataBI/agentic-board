<#  Update-AllPlugins.ps1 - update EVERY installed Claude Code plugin in one pass and say what changed
    (epic #711, task #712).

    Claude Code has no "update all": it is `claude plugin marketplace update <m>` and then
    `claude plugin update <plugin>@<m>` for each plugin. This runs both for every marketplace and every
    plugin installed on the machine (not only this one) and reports, per plugin:

        updated    old version (+commit) -> new version (+commit), with a short "what's new" taken from
                   the new build's own release notes when it ships them
        unchanged  Claude found nothing newer
        failed     the update did not go through; the reason is shown and the exit code is non-zero
        skipped    not attempted (marketplace not registered, or the marketplace refresh failed)

    A failed marketplace or plugin is NEVER reported as up to date. The verdict on each plugin comes from
    comparing installed_plugins.json before and after, not from parsing what the CLI prints.

    A marketplace whose source is a local directory (development checkouts) is refreshed too, but a
    failure there is a warning: it does not fail the run.

    -DryRun   print what would be run; change nothing.
    -Only     one or more plugin names (or plugin@marketplace) to limit the run to.
    -Clean    afterwards, delete old builds nobody uses (same guards as the cleanup verb). Without it the
              run only counts them; it never deletes on its own.
    -AcceptMarketplaceCommands   pass --yes to `claude plugin update`. OFF by default: it accepts, without
              asking, a command a marketplace declares for its install. Only for marketplaces you trust.

    The runner is injectable (-Runner) and every path root is a parameter (-ClaudeHome), so tests use a
    fake CLI and a fabricated home; nothing here needs the real one.

    Dot-source guard: set $env:ABIOS_PLUGINUPDATE_DOTSOURCE=1 to load the functions without running.  #>
[CmdletBinding()]
param(
    [string]$ClaudeHome,
    [string[]]$Only = @(),
    [switch]$DryRun,
    [switch]$Clean,
    [switch]$AcceptMarketplaceCommands,
    [int]$TimeoutSec = 300
)

. (Join-Path $PSScriptRoot 'PluginState.ps1')

# ---------------------------------------------------------------------------- the CLI runner

# Run the claude CLI with stdin closed (an update that wants to ask a question must fail, not hang) and
# a timeout. Returns { ExitCode; Output; TimedOut }. -Executable exists so a test can point it at any
# harmless program; the real default is the claude on the PATH.
function Invoke-ClaudeCli {
    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Executable = '')
    if (-not $Executable) {
        $found = @(Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)
        $pick = $found | Where-Object { $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
        if (-not $pick) { $pick = $found | Select-Object -First 1 }
        if (-not $pick) { return [pscustomobject]@{ ExitCode = -1; Output = 'no encuentro el programa claude en este equipo'; TimedOut = $false } }
        $Executable = $pick.Source
    }
    # A .cmd/.bat shim is parsed by cmd.exe, whose metacharacters (& | ^ % ...) .NET does not escape. Our
    # arguments are always plain words (marketplace and plugin names, --yes), so anything else is refused
    # rather than escaped: a name read from a data file must never become a command.
    if ($Executable -match '\.(cmd|bat)$') {
        foreach ($a in $Arguments) {
            if ($a -notmatch '^[A-Za-z0-9._@:=/-]+$') {
                return [pscustomobject]@{ ExitCode = -1; Output = "no ejecuto claude: un argumento tiene caracteres no permitidos ($a)"; TimedOut = $false }
            }
        }
    }
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Executable)
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
        }
        # The process is gone, but a grandchild it started may still hold the pipes open: wait for the
        # readers only briefly, and report what was read (nothing) rather than hang past the timeout.
        $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 5000)
        $text = if ($drained) { ("$($outTask.Result)`n$($errTask.Result)").Trim() } else { '(la salida no se pudo leer por completo)' }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text; TimedOut = $false }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "no pude ejecutar claude: $($_.Exception.Message)"; TimedOut = $false }
    }
}

# ---------------------------------------------------------------------------- "what's new"

# Strip control characters and ANSI escapes: release notes are somebody else's text, printed as data.
function ConvertTo-PlainText([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ''
    return ($t -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
}

# The block of a changelog that belongs to ONE version. Understands "## [1.2.3] - date", "## 1.2.3" and
# "# v1.2.3"; the block ends at the next heading of the same or a higher level. '' when there is none.
function Get-ChangelogVersionSection {
    param([string]$Text, [string]$Version)
    if (-not $Text -or -not $Version) { return '' }
    $v = [regex]::Escape($Version.TrimStart('v', 'V'))
    $lines = $Text -split "`r?`n"
    $start = -1; $level = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(#{1,3})\s*\[?[vV]?$v\]?(?:\s|$|[-(])") { $start = $i; $level = $Matches[1].Length; break }
    }
    if ($start -lt 0) { return '' }
    $body = [System.Collections.Generic.List[string]]::new()
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^(#{1,6})\s' -and $Matches[1].Length -le $level) { break }
        $body.Add($lines[$j])
    }
    return ($body -join "`n")
}

# A short, bounded excerpt of what changed in $Version, from the release notes the build itself ships
# (the plugin folder first, then the marketplace checkout). Never throws; '' when there is nothing.
function Get-WhatsNewExcerpt {
    param([string[]]$SearchDirs, [string]$Version, [int]$MaxLines = 6, [int]$MaxChars = 480)
    if (-not $Version) { return '' }
    foreach ($dir in @($SearchDirs)) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($name in 'CHANGELOG.md', 'RELEASE_NOTES.md', 'RELEASES.md', 'HISTORY.md', 'NEWS.md') {
            $file = Join-Path $dir $name
            try {
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
                if ((Get-Item -LiteralPath $file).Length -gt 2MB) { continue }
                $section = Get-ChangelogVersionSection -Text ([System.IO.File]::ReadAllText($file)) -Version $Version
            } catch { continue }
            if (-not $section) { continue }
            $picked = @(
                (ConvertTo-PlainText $section) -split "`n" |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and $_ -notmatch '^#' } |
                    ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 157) + '...' } else { $_ } } |
                    Select-Object -First $MaxLines
            )
            if ($picked.Count -eq 0) { continue }
            $text = $picked -join "`n"
            if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars - 3) + '...' }
            return $text
        }
    }
    return ''
}

# ---------------------------------------------------------------------------- the run

function Select-Only([object[]]$Entries, [string[]]$Only) {
    $wanted = @($Only | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($wanted.Count -eq 0) { return @($Entries) }
    return @($Entries | Where-Object { $wanted -contains $_.Plugin.ToLowerInvariant() -or $wanted -contains $_.Key.ToLowerInvariant() })
}

# The last few lines of CLI output as a bounded reason, plain text.
function Get-FailureReason($Run) {
    if ($Run.TimedOut) { return 'se agoto el tiempo de espera' }
    $lines = @((ConvertTo-PlainText "$($Run.Output)") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 3)
    $why = if ($lines.Count -gt 0) { $lines -join ' | ' } else { "codigo de salida $($Run.ExitCode)" }
    if ($why.Length -gt 300) { $why = $why.Substring(0, 297) + '...' }
    if ("$($Run.Output)" -match '(?i)--yes|confirm') {
        $why += ' (el mercado pide confirmar un comando; si confias en el, vuelve a correr aceptandolo)'
    }
    return $why
}

function Get-EntryFor($Entries, [string]$Key) {
    $user = @($Entries | Where-Object { $_.Key -eq $Key -and $_.Scope -eq 'user' })
    if ($user.Count -gt 0) { return $user[0] }
    return $null
}

# The whole run. Returns the result object the report is built from; performs no printing.
function Invoke-PluginUpdate {
    param(
        [string]$ClaudeHome,
        [string[]]$Only = @(),
        [switch]$DryRun,
        [switch]$Clean,
        [switch]$AcceptMarketplaceCommands,
        [scriptblock]$Runner,
        [scriptblock]$GetProcess,
        [scriptblock]$OnProgress,
        [int]$TimeoutSec = 300,
        [int]$GraceMinutes = 60
    )
    if (-not $Runner) { $Runner = { param($cliArgs) Invoke-ClaudeCli -Arguments $cliArgs -TimeoutSec $TimeoutSec } }
    $say = { param($m) if ($OnProgress) { & $OnProgress $m } }
    $result = [pscustomobject]@{
        Fatal = ''; DryRun = [bool]$DryRun; Marketplaces = @(); Plugins = @(); Commands = @()
        Sessions = $null; Cleanup = $null; ExitCode = 0
    }
    $fatal = { param($why) $result.Fatal = $why; $result.ExitCode = 1; return $result }

    $inst = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
    if (-not $inst.Ok) { return (& $fatal "no pude leer que plugins tienes instalados ($($inst.Reason))") }
    $mkt = Get-KnownMarketplaces -ClaudeHome $ClaudeHome
    if (-not $mkt.Ok) { return (& $fatal "no pude leer los mercados registrados ($($mkt.Reason))") }

    $targets = @(Select-Only $inst.Entries $Only)
    $filtered = @($Only | Where-Object { $_ }).Count -gt 0
    if ($filtered -and $targets.Count -eq 0) { return (& $fatal "no hay ningun plugin instalado que coincida con: $($Only -join ', ')") }

    $mkRows = [System.Collections.Generic.List[object]]::new()
    $failedMk = @{}
    $cmds = [System.Collections.Generic.List[string]]::new()
    $needed = @($targets | ForEach-Object { $_.Marketplace } | Select-Object -Unique)
    foreach ($m in $mkt.Items) {
        if ($filtered -and $needed -notcontains $m.Name) { continue }
        $isDir = ($m.SourceKind -eq 'directory')
        $cliArgs = @('plugin', 'marketplace', 'update', $m.Name)
        if ($DryRun) {
            $cmds.Add('claude ' + ($cliArgs -join ' '))
            $mkRows.Add([pscustomobject]@{ Name = $m.Name; SourceKind = $m.SourceKind; Status = 'planned'; Warning = $false; Reason = '' })
            continue
        }
        & $say "Refrescando el mercado '$($m.Name)'..."
        $run = & $Runner $cliArgs
        if ($run.ExitCode -eq 0 -and -not $run.TimedOut) {
            $mkRows.Add([pscustomobject]@{ Name = $m.Name; SourceKind = $m.SourceKind; Status = 'refreshed'; Warning = $false; Reason = '' })
        } else {
            $why = Get-FailureReason $run
            $mkRows.Add([pscustomobject]@{ Name = $m.Name; SourceKind = $m.SourceKind; Status = 'failed'; Warning = $isDir; Reason = $why })
            if (-not $isDir) { $failedMk[$m.Name] = $why }
        }
    }
    $knownNames = @($mkt.Items | ForEach-Object { $_.Name })

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($t in $targets) {
        if ($seen.ContainsKey($t.Key)) { continue }
        $seen[$t.Key] = $true
        $old = Get-EntryFor $inst.Entries $t.Key
        $row = [pscustomobject]@{ Key = $t.Key; Plugin = $t.Plugin; Marketplace = $t.Marketplace; Status = ''; Old = $null; New = $null; Reason = ''; Excerpt = ''; Failure = $false }
        if (-not $old) {
            $row.Status = 'skipped'; $row.Reason = "solo esta instalado para un proyecto ($($t.Scope)); actualizalo desde esa carpeta"
            $rows.Add($row); continue
        }
        $row.Old = [pscustomobject]@{ Version = $old.Version; Sha = $old.Sha }
        if ($knownNames -notcontains $t.Marketplace) {
            $row.Status = 'skipped'; $row.Reason = "el mercado '$($t.Marketplace)' ya no esta registrado"
            $rows.Add($row); continue
        }
        if ($failedMk.ContainsKey($t.Marketplace)) {
            $row.Status = 'skipped'; $row.Failure = $true
            $row.Reason = "no se pudo refrescar su mercado, asi que no se sabe si hay algo nuevo: $($failedMk[$t.Marketplace])"
            $rows.Add($row); continue
        }
        $cliArgs = @('plugin', 'update', $t.Key)
        if ($AcceptMarketplaceCommands) { $cliArgs += '--yes' }
        if ($DryRun) {
            $cmds.Add('claude ' + ($cliArgs -join ' '))
            $row.Status = 'planned'; $rows.Add($row); continue
        }
        & $say "Actualizando '$($t.Key)'..."
        $run = & $Runner $cliArgs
        if ($run.ExitCode -ne 0 -or $run.TimedOut) {
            $row.Status = 'failed'; $row.Failure = $true; $row.Reason = Get-FailureReason $run
            $rows.Add($row); continue
        }
        $after = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
        $now = if ($after.Ok) { Get-EntryFor $after.Entries $t.Key } else { $null }
        if (-not $now) {
            # The CLI said yes but the installed list no longer (or cannot be shown to) contain it: not a success we can vouch for.
            $row.Status = 'failed'; $row.Failure = $true
            $row.Reason = 'Claude dijo que termino, pero no puedo confirmar el resultado en la lista de plugins instalados'
            $rows.Add($row); continue
        }
        $row.New = [pscustomobject]@{ Version = $now.Version; Sha = $now.Sha }
        if ($now.Version -ne $old.Version -or $now.Sha -ne $old.Sha) {
            $row.Status = 'updated'
            $loc = @($mkt.Items | Where-Object { $_.Name -eq $t.Marketplace } | ForEach-Object { $_.InstallLocation })
            $row.Excerpt = Get-WhatsNewExcerpt -SearchDirs (@($now.InstallPath) + $loc) -Version $now.Version
        } else {
            $row.Status = 'unchanged'
        }
        $rows.Add($row)
    }

    $result.Marketplaces = @($mkRows)
    $result.Plugins = @($rows)
    $result.Commands = @($cmds)

    # Sessions still on old builds - measured AFTER the update, against what is installed now.
    $map = Get-LiveSessionMap -ClaudeHome $ClaudeHome -GetProcess $GetProcess
    if ($map.Ok) {
        $result.Sessions = [pscustomobject]@{
            Available = $true; Live = @($map.Sessions).Count
            Stale = @($map.Sessions | Where-Object { $_.State -eq 'stale' }).Count
            NoData = @($map.Sessions | Where-Object { $_.State -eq 'unknown' }).Count
            UnknownLiveness = $map.UnknownLiveness
        }
    } else {
        $result.Sessions = [pscustomobject]@{ Available = $false; Live = 0; Stale = 0; NoData = 0; UnknownLiveness = 0 }
    }

    # Old builds nobody uses: counted always, deleted only with -Clean (and never in a dry run).
    $plan = Get-VersionCleanupPlan -ClaudeHome $ClaudeHome -GetProcess $GetProcess -GraceMinutes $GraceMinutes
    if ($plan.Ok) {
        $cand = @($plan.Items | Where-Object { $_.Action -eq 'remove' })
        $removed = 0; $failed = 0
        if ($Clean -and -not $DryRun) {
            $done = Invoke-PluginCleanup -Plan $plan -ClaudeHome $ClaudeHome -GetProcess $GetProcess -GraceMinutes $GraceMinutes
            $removed = @($done.Removed).Count; $failed = @($done.Failed).Count
        }
        $result.Cleanup = [pscustomobject]@{
            Available = $true; Candidates = $cand.Count; Bytes = [long](($cand | Measure-Object SizeBytes -Sum).Sum)
            Ran = ([bool]$Clean -and -not $DryRun); Removed = $removed; Failed = $failed
        }
    } else {
        $result.Cleanup = [pscustomobject]@{ Available = $false; Candidates = 0; Bytes = 0L; Ran = $false; Removed = 0; Failed = 0; Reason = $plan.Reason }
    }

    $badMk = @($result.Marketplaces | Where-Object { $_.Status -eq 'failed' -and -not $_.Warning }).Count
    $badPl = @($result.Plugins | Where-Object { $_.Failure }).Count
    $badCl = if ($result.Cleanup.Available) { $result.Cleanup.Failed } else { 0 }
    if ($badMk + $badPl + $badCl -gt 0) { $result.ExitCode = 1 }
    return $result
}

# ---------------------------------------------------------------------------- the report (pure)

function Format-ShortBuild($Build) {
    if (-not $Build) { return '?' }
    $sha = "$($Build.Sha)"
    $v = "$($Build.Version)"
    if ($sha.Length -gt 7) { $sha = $sha.Substring(0, 7) }
    if ($sha -and $v -notlike "$sha*") { return "$v ($sha)" }
    return $v
}

# ---------------------------------------------------------------------------- the report (pure)

function Format-ShortBuild($Build) {
    if (-not $Build) { return '?' }
    $sha = "$($Build.Sha)"
    $v = "$($Build.Version)"
    if ($sha.Length -gt 7) { $sha = $sha.Substring(0, 7) }
    if ($sha -and $v -notlike "$sha*") { return "$v ($sha)" }
    return $v
}

function Format-Megabytes([long]$Bytes) {
    if ($Bytes -lt 1MB) { return '<1 MB' }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

# Result -> lines for the screen: @{ Text; Color }. Words for a BI professional, not a programmer.
# Pure: no printing, no reading. The wording never claims "up to date" for anything that failed.
function Format-PluginUpdateReport {
    param($Result)
    $acc = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $c) $acc.Add([pscustomobject]@{ Text = $t; Color = $c }) }

    if ($Result.Fatal) {
        & $add "No pude actualizar: $($Result.Fatal)." 'Red'
        return @($acc)
    }
    $by = { param($s) @($Result.Plugins | Where-Object { $_.Status -eq $s }) }
    $updated = & $by 'updated'; $unchanged = & $by 'unchanged'; $failed = & $by 'failed'
    $skipped = & $by 'skipped'
    $blocked = @($skipped | Where-Object { $_.Failure })
    $harmless = @($skipped | Where-Object { -not $_.Failure })
    $mkFail = @($Result.Marketplaces | Where-Object { $_.Status -eq 'failed' })

    if ($Result.DryRun) {
        & $add 'SIMULACION - no se cambio nada. Esto es lo que se haria:' 'Cyan'
        foreach ($c in $Result.Commands) { & $add "  $c" 'Gray' }
        if (@($Result.Commands).Count -eq 0) { & $add '  (no hay nada que hacer)' 'Gray' }
        foreach ($p in $skipped) { & $add "  Se omitiria $($p.Key): $($p.Reason)" 'Yellow' }
    } else {
        & $add 'Resumen de la actualizacion de plugins' 'Cyan'
        $refreshed = @($Result.Marketplaces | Where-Object { $_.Status -eq 'refreshed' }).Count
        $warn = @($mkFail | Where-Object { $_.Warning }).Count
        $bad = $mkFail.Count - $warn
        & $add "  Mercados: $refreshed refrescados, $warn con aviso, $bad con fallo" 'Gray'
        & $add ("  Plugins:  {0} actualizados | {1} sin cambios | {2} con fallo | {3} omitidos" -f $updated.Count, $unchanged.Count, ($failed.Count + $blocked.Count), $skipped.Count) 'Gray'
        & $add '' 'Gray'

        if ($updated.Count -gt 0) {
            & $add 'Actualizados' 'Green'
            foreach ($p in $updated) {
                & $add ("  {0}: {1} -> {2}" -f $p.Key, (Format-ShortBuild $p.Old), (Format-ShortBuild $p.New)) 'Green'
                if ($p.Excerpt) {
                    & $add '      Que hay de nuevo:' 'Gray'
                    foreach ($l in ($p.Excerpt -split "`n")) { & $add "        $l" 'Gray' }
                }
            }
            & $add '' 'Gray'
        }
        if ($failed.Count -gt 0 -or $blocked.Count -gt 0) {
            & $add 'NO se pudieron actualizar (no dar por buenos)' 'Red'
            foreach ($p in @($failed) + @($blocked)) { & $add ("  {0}: {1}" -f $p.Key, $p.Reason) 'Red' }
            & $add '' 'Gray'
        }
        if ($harmless.Count -gt 0) {
            & $add 'Omitidos' 'Yellow'
            foreach ($p in $harmless) { & $add ("  {0}: {1}" -f $p.Key, $p.Reason) 'Yellow' }
            & $add '' 'Gray'
        }
        if ($unchanged.Count -gt 0) {
            & $add ("Sin cambios (Claude no encontro nada mas nuevo): " + (($unchanged | ForEach-Object { $_.Plugin }) -join ', ')) 'Gray'
            & $add '' 'Gray'
        }
        $warns = @($mkFail | Where-Object { $_.Warning })
        $hard = @($mkFail | Where-Object { -not $_.Warning })
        if ($warns.Count -gt 0 -or $hard.Count -gt 0) {
            & $add 'Mercados con problemas' 'Yellow'
            foreach ($m in $hard)  { & $add ("  {0}: {1}" -f $m.Name, $m.Reason) 'Red' }
            foreach ($m in $warns) { & $add ("  {0} (carpeta local, solo aviso): {1}" -f $m.Name, $m.Reason) 'Yellow' }
            & $add '' 'Gray'
        }
    }

    $s = $Result.Sessions
    if ($s -and $s.Available) {
        $none = $s.Live - $s.Stale - $s.NoData
        $msg = "Sesiones abiertas: $($s.Live). $($s.Stale) siguen con una version vieja de algun plugin"
        $msg += ", $none al dia, $($s.NoData) sin datos para comprobarlo"
        if ($s.UnknownLiveness -gt 0) { $msg += " (y $($s.UnknownLiveness) mas que no pude confirmar que sigan abiertas)" }
        & $add ($msg + '. Para ver cuales: /board plugins sessions') $(if ($s.Stale -gt 0) { 'Yellow' } else { 'Gray' })
        if ($s.Stale -gt 0) {
            & $add '  En cada una: escribe /reload-plugins (skills, comandos y hooks). Si el plugin trae un servidor MCP, abre una sesion nueva.' 'Gray'
        }
    } else {
        & $add 'Sesiones abiertas: no pude comprobarlas. No asumas que estan al dia.' 'Yellow'
    }

    $c = $Result.Cleanup
    if ($c -and $c.Available) {
        if ($c.Ran) {
            & $add ("Versiones viejas: se borraron {0}{1}." -f $c.Removed, $(if ($c.Failed -gt 0) { ", $($c.Failed) no se pudieron borrar" } else { '' })) $(if ($c.Failed -gt 0) { 'Red' } else { 'Gray' })
        } elseif ($c.Candidates -gt 0) {
            & $add ("Versiones viejas sin uso: {0} (unos {1}). No se borra nada solo: para limpiarlas usa /board plugins clean (o repite esto con -Clean)." -f $c.Candidates, (Format-Megabytes $c.Bytes)) 'Gray'
        }
    }
    return @($acc)
}

# ---------------------------------------------------------------------------- main
if ($env:ABIOS_PLUGINUPDATE_DOTSOURCE) { return }

# The recycled-pid rule the session counts rely on lives in Board-Work.ps1 (Test-SessionStartConsistent).
# Its documented dot-source guard loads only the functions; the param() block of that file would reset
# any shared parameter name in THIS scope, so what the caller passed is replayed afterwards.
$script:PrevDotSource = $env:ABIOS_BOARDWORK_DOTSOURCE
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
try   { . (Join-Path $PSScriptRoot 'Board-Work.ps1') }
finally {
    $env:ABIOS_BOARDWORK_DOTSOURCE = $script:PrevDotSource
    foreach ($k in $PSBoundParameters.Keys) { Set-Variable -Name $k -Value $PSBoundParameters[$k] -Scope Local }
}

trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$run = Invoke-PluginUpdate -ClaudeHome $ClaudeHome -Only $Only -DryRun:$DryRun -Clean:$Clean `
    -AcceptMarketplaceCommands:$AcceptMarketplaceCommands -TimeoutSec $TimeoutSec `
    -OnProgress { param($m) Write-Host $m -ForegroundColor DarkGray }
foreach ($line in (Format-PluginUpdateReport -Result $run)) {
    Write-Host $line.Text -ForegroundColor $line.Color
}
exit $run.ExitCode
