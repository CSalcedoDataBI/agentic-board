<#  Remove-OldPluginVersions.ps1 - safe cleanup of old cached plugin builds (epic #711, task #715).

    Every update leaves the previous build in the plugin cache. Claude Code itself removes orphaned builds
    only after 14 days. This removes them sooner, but only the ones that are provably unused.

    DEFAULT IS A LISTING: nothing is deleted unless -Execute is passed.

    A cached build is removed only when ALL of these hold; any doubt keeps it:
      1. it is not the installed build of any plugin in installed_plugins.json
      2. no live process holds it: every .in_use marker belongs to a process that is gone (or whose pid
         was reused by a later process). A live holder, a holder whose liveness cannot be confirmed, or
         a marker that cannot be read keeps the build.
      3. its real path is strictly inside <claude home>/plugins/cache/<marketplace>/<plugin>/ (canonical
         paths; 8.3 short names and .. cannot defeat the check), and neither it nor anything in it is a
         link or junction
      4. it was not touched in the last -GraceMinutes (an install in progress is not yet in the list)
    If the installed list itself cannot be read (or is empty) nothing is removed.

    Dot-source guard: set $env:ABIOS_PLUGINCLEAN_DOTSOURCE=1 to load the functions without running.  #>
[CmdletBinding()]
param(
    [string]$ClaudeHome,
    [switch]$Execute,
    [switch]$ShowKept,
    [int]$GraceMinutes = 60
)

. (Join-Path $PSScriptRoot 'PluginState.ps1')

function Format-CleanupMegabytes([long]$Bytes) {
    if ($Bytes -lt 1MB) { return '<1 MB' }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

# Plan (+ optional results of executing it) -> lines: @{ Text; Color }. Pure.
#   -Removed / -Failed are the outcomes of an execution ($null in a listing).
function Format-CleanupReport {
    param($Plan, [object[]]$Removed = $null, [object[]]$Failed = $null, [switch]$ShowKept)
    $acc = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $c) $acc.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    if (-not $Plan.Ok) {
        & $add "No borro nada: $($Plan.Reason)." 'Red'
        return @($acc)
    }
    $rm = @($Plan.Items | Where-Object { $_.Action -eq 'remove' })
    $kept = @($Plan.Items | Where-Object { $_.Action -ne 'remove' })
    $executed = ($null -ne $Removed)
    if ($rm.Count -eq 0) {
        & $add 'No hay versiones viejas sin uso que borrar.' 'Green'
    } elseif (-not $executed) {
        $total = [long](($rm | Measure-Object SizeBytes -Sum).Sum)
        & $add ("Versiones viejas que nadie usa: {0} (unos {1}). NO se ha borrado nada; para borrarlas usa /board plugins clean -Execute." -f $rm.Count, (Format-CleanupMegabytes $total)) 'Cyan'
        foreach ($i in $rm) { & $add ("  {0}@{1}  version {2}  ({3})" -f $i.Plugin, $i.Marketplace, $i.Version, (Format-CleanupMegabytes $i.SizeBytes)) 'Gray' }
    } else {
        $freed = [long](($Removed | Measure-Object SizeBytes -Sum).Sum)
        & $add ("Borradas: {0} (unos {1} liberados)." -f @($Removed).Count, (Format-CleanupMegabytes $freed)) 'Green'
        foreach ($i in $Removed) { & $add ("  {0}@{1}  version {2}" -f $i.Plugin, $i.Marketplace, $i.Version) 'Gray' }
        if (@($Failed).Count -gt 0) {
            & $add ("No se pudieron borrar: {0}" -f @($Failed).Count) 'Red'
            foreach ($i in $Failed) { & $add ("  {0}@{1}  version {2}: {3}" -f $i.Plugin, $i.Marketplace, $i.Version, $i.FailReason) 'Red' }
        }
    }
    if ($kept.Count -gt 0) {
        $names = @{
            'installed' = 'instaladas'; 'in-use' = 'en uso por una sesion abierta'
            'unknown-holder' = 'sin poder confirmar quien las usa'; 'link' = 'enlaces o con enlaces dentro'
            'outside' = 'fuera de la carpeta de versiones'; 'recent' = 'tocadas hace muy poco'
        }
        $parts = @($kept | Group-Object Category | Sort-Object Name | ForEach-Object { "{0} {1}" -f $_.Count, $(if ($names.ContainsKey($_.Name)) { $names[$_.Name] } else { $_.Name }) })
        & $add ("Se conservan {0}: {1}." -f $kept.Count, ($parts -join '; ')) 'Gray'
        if ($ShowKept) { foreach ($i in $kept) { & $add ("  {0}@{1}  version {2}: {3}" -f $i.Plugin, $i.Marketplace, $i.Version, $i.Reason) 'DarkGray' } }
    }
    return @($acc)
}

# Plan -> deletions. Only 'remove' items are attempted, and each is re-verified by Remove-PluginVersionDir.
function Invoke-PluginCleanup {
    param($Plan, [string]$ClaudeHome)
    $removed = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($i in @($Plan.Items | Where-Object { $_.Action -eq 'remove' })) {
        $r = Remove-PluginVersionDir -Path $i.Path -ClaudeHome $ClaudeHome
        if ($r.Removed) { $removed.Add($i) }
        else { $i | Add-Member -NotePropertyName FailReason -NotePropertyValue $r.Reason -Force; $failed.Add($i) }
    }
    return [pscustomobject]@{ Removed = @($removed); Failed = @($failed) }
}

if ($env:ABIOS_PLUGINCLEAN_DOTSOURCE) { return }

# Reuse of the recycled-pid rule from Board-Work.ps1 (see Get-PluginSessionMap for why it is replayed).
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

$plan = Get-VersionCleanupPlan -ClaudeHome $ClaudeHome -GraceMinutes $GraceMinutes
if (-not $plan.Ok) {
    foreach ($line in (Format-CleanupReport -Plan $plan)) { Write-Host $line.Text -ForegroundColor $line.Color }
    exit 1
}
if ($Execute) {
    $out = Invoke-PluginCleanup -Plan $plan -ClaudeHome $ClaudeHome
    foreach ($line in (Format-CleanupReport -Plan $plan -Removed $out.Removed -Failed $out.Failed -ShowKept:$ShowKept)) { Write-Host $line.Text -ForegroundColor $line.Color }
    if (@($out.Failed).Count -gt 0) { exit 1 }
    exit 0
}
foreach ($line in (Format-CleanupReport -Plan $plan -ShowKept:$ShowKept)) { Write-Host $line.Text -ForegroundColor $line.Color }
exit 0
