<#  Get-AbiosProcess.ps1 - the process table, the same shape on every platform (#767).

    The fleet's reaper, liveness checks and ownership records read ProcessId, ParentProcessId,
    CommandLine and the start time of processes. On Windows that is Win32_Process through CIM (kept
    as-is, filters included, so existing behaviour does not move). Elsewhere it is Get-Process,
    whose objects carry the command line (/proc on Linux) and the parent in PowerShell 7.

    Names are given WITHOUT an extension ('pwsh', 'node', 'agy'); the Windows query adds '.exe'.
    Function definitions only; safe to dot-source.  #>

function Test-AbiosWindows { return [bool]($IsWindows -or $env:OS -eq 'Windows_NT') }

# {ProcessId, ParentProcessId, Name, CommandLine, CreationDate} for the processes asked for:
# -Id one process, -Names those executables, neither = every process. Unreadable fields are $null.
function Get-AbiosProcessList {
    param([string[]]$Names = @(), [int]$Id = 0)
    if (Test-AbiosWindows) {
        $filter = if ($Id) { "ProcessId=$Id" }
                  elseif ($Names.Count) { (@($Names | ForEach-Object { "Name='$_.exe'" })) -join ' OR ' }
                  else { '' }
        $q = @{ ClassName = 'Win32_Process'; ErrorAction = 'SilentlyContinue' }
        if ($filter) { $q.Filter = $filter }
        return @(Get-CimInstance @q | Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate)
    }
    $procs = if ($Id) { @(Get-Process -Id $Id -ErrorAction SilentlyContinue) }
             elseif ($Names.Count) { @(Get-Process -Name $Names -ErrorAction SilentlyContinue) }
             else { @(Get-Process -ErrorAction SilentlyContinue) }
    return @(foreach ($p in $procs) {
        [pscustomobject]@{
            ProcessId       = $p.Id
            ParentProcessId = $(try { $p.Parent.Id } catch { $null })
            Name            = $p.ProcessName
            CommandLine     = $(try { $p.CommandLine } catch { $null })
            CreationDate    = $(try { $p.StartTime } catch { $null })
        }
    })
}

# The parent of a process (default: this one), 0 when it cannot be read.
function Get-AbiosParentPid {
    param([int]$Id = $PID)
    $p = @(Get-AbiosProcessList -Id $Id) | Select-Object -First 1
    if ($p -and $p.ParentProcessId) { return [int]$p.ParentProcessId }
    return 0
}
