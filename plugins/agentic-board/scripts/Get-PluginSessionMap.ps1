<#  Get-PluginSessionMap.ps1 - which OPEN Claude Code sessions still run an old build of a plugin
    (epic #711, task #713). Read-only.

    Updating a plugin installs the new build on disk; every session that is already open keeps the build
    it loaded at startup. This lists, for each open session, the plugins it loaded at a build other than
    the one installed now, and says what fixes each one:
        - skills, commands, agents, hooks  -> type /reload-plugins in THAT session (only the user can)
        - the plugin ships an MCP server   -> open a NEW session (reload does not reconnect MCP servers)

    Three rules keep it honest:
        - only sessions that are provably open are listed (process id AND start time match what the
          session recorded, so a recycled id is not mistaken for a session); a session that is gone never
          has its name or folder printed
        - a session with no record at all of what it loaded is "sin datos", never "al dia"
        - a session whose liveness cannot be confirmed is counted, not listed

    -Json   emit the map as JSON (name and folder of open sessions only) for other tools.

    Dot-source guard: set $env:ABIOS_SESSIONMAP_DOTSOURCE=1 to load the functions without running.  #>
[CmdletBinding()]
param(
    [string]$ClaudeHome,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'PluginState.ps1')

# Free text that came from a file on disk (a session name, a folder) is printed as data.
function ConvertTo-SafeLabel([string]$Text) {
    if (-not $Text) { return '' }
    return ($Text -replace '[\x00-\x1f\x7f]', ' ').Trim()
}

# Map -> lines for the screen: @{ Text; Color }. Pure.
function Format-SessionMap {
    param($Map)
    $acc = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $c) $acc.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    if (-not $Map.Ok) {
        & $add "No pude comprobar las sesiones: $($Map.Reason)." 'Red'
        return @($acc)
    }
    $ss = @($Map.Sessions)
    $stale = @($ss | Where-Object { $_.State -eq 'stale' })
    $current = @($ss | Where-Object { $_.State -eq 'current' })
    $nodata = @($ss | Where-Object { $_.State -eq 'unknown' })
    & $add "Sesiones abiertas de Claude Code: $($ss.Count)" 'Cyan'
    & $add ("  {0} con plugins desactualizados | {1} al dia | {2} sin datos para comprobarlo" -f $stale.Count, $current.Count, $nodata.Count) 'Gray'
    & $add '' 'Gray'

    foreach ($s in $stale) {
        $name = ConvertTo-SafeLabel $s.Name; if (-not $name) { $name = '(sin nombre)' }
        & $add ("`"{0}`"  carpeta: {1}" -f $name, (ConvertTo-SafeLabel $s.Cwd)) 'Yellow'
        foreach ($p in $s.Stale) {
            $fix = if ($p.NeedsNewSession) { 'abre una sesion nueva (trae un servidor MCP, o no pude comprobarlo)' } else { 'basta con /reload-plugins en esa sesion' }
            & $add ("    {0}: cargo {1} -> instalado {2}   [{3}]" -f $p.Key, ($p.Loaded -join ', '), $p.Installed, $fix) 'Yellow'
        }
    }
    foreach ($s in $current) {
        $name = ConvertTo-SafeLabel $s.Name; if (-not $name) { $name = '(sin nombre)' }
        & $add ("`"{0}`"  carpeta: {1}  -> al dia" -f $name, (ConvertTo-SafeLabel $s.Cwd)) 'Green'
    }
    foreach ($s in $nodata) {
        $name = ConvertTo-SafeLabel $s.Name; if (-not $name) { $name = '(sin nombre)' }
        & $add ("`"{0}`"  carpeta: {1}  -> SIN DATOS: no encuentro que plugins cargo, asi que no puedo decir que este al dia" -f $name, (ConvertTo-SafeLabel $s.Cwd)) 'Yellow'
    }
    if ($Map.UnknownLiveness -gt 0) {
        & $add ("Hay {0} sesion(es) mas cuyo estado no pude confirmar; no se listan." -f $Map.UnknownLiveness) 'Gray'
    }
    if ($Map.Unreadable -gt 0) {
        & $add ("Hay {0} registro(s) de sesion que no pude leer." -f $Map.Unreadable) 'Gray'
    }
    if ($stale.Count -gt 0) {
        & $add '' 'Gray'
        & $add 'Solo el usuario puede escribir /reload-plugins dentro de una sesion; ni otro agente ni el control remoto pueden hacerlo por ti.' 'Gray'
    }
    return @($acc)
}

if ($env:ABIOS_SESSIONMAP_DOTSOURCE) { return }

# The recycled-pid rule lives in Board-Work.ps1 (Test-SessionStartConsistent, #520/#557) and is reused,
# not copied. Its guard loads functions only; its param() block would reset any shared parameter name
# in this scope, so what the caller passed is replayed afterwards.
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

$map = Get-LiveSessionMap -ClaudeHome $ClaudeHome
if ($Json) {
    [pscustomobject]@{
        ok = $map.Ok; reason = $map.Reason; unknownLiveness = $map.UnknownLiveness; unreadable = $map.Unreadable
        sessions = @($map.Sessions | ForEach-Object {
            [pscustomobject]@{ name = $_.Name; folder = $_.Cwd; state = $_.State
                stale = @($_.Stale | ForEach-Object { [pscustomobject]@{ plugin = $_.Key; loaded = @($_.Loaded); installed = $_.Installed; needsNewSession = $_.NeedsNewSession } }) }
        })
    } | ConvertTo-Json -Depth 6
    if (-not $map.Ok) { exit 1 }
    exit 0
}
foreach ($line in (Format-SessionMap -Map $map)) { Write-Host $line.Text -ForegroundColor $line.Color }
if (-not $map.Ok) { exit 1 }
exit 0
