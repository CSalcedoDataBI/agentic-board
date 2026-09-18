#Requires -Modules Pester
<#  Tests for scripts/board-sync.sh - the workflow that reconciles the board (#679).

    The items query started failing in CI with a bare "Something went wrong while executing your
    query" and the script died with no cause. The script now pages in small chunks, retries, and on a
    persistent failure says which part of the query breaks. These drive the REAL script with a fake
    `gh` on PATH, so no network and no token are involved. #>

BeforeDiscovery {
    $script:BashExe = if ($IsWindows) {
        # Never the WSL launcher in System32: it would run the script in a different userland.
        @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe') |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    } else { (Get-Command bash -ErrorAction SilentlyContinue).Source }
    $script:HasJq = [bool](Get-Command jq -ErrorAction SilentlyContinue)
    $script:CanRun = ($script:BashExe -and $script:HasJq)
}

Describe 'board-sync.sh items load (#679)' -Skip:(-not $script:CanRun) {

    BeforeAll {
        $script:BashExe = if ($IsWindows) {
            @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe') |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        } else { (Get-Command bash).Source }
        $script:Sync = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'board-sync.sh' | Resolve-Path
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("boardsync-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force $script:Root | Out-Null

        # A fake `gh`: answers the project query, serves FAKE_PAGES pages of one issue each (an open
        # PR, currently Backlog), fails the first FAKE_FAIL_FIRST items calls, and fails every items
        # call whose query still contains "timelineItems" when FAKE_FAIL_TIMELINE is set.
        $fake = @'
#!/usr/bin/env bash
state="$FAKE_STATE"
if [ "$1" = "--version" ]; then echo "gh version 0.0.0-fake"; exit 0; fi
q=""; cursor=""
for ((i=1; i<=$#; i++)); do
  a="${!i}"; n=$((i+1)); v="${!n}"
  [ "$a" = "-f" ] && case "$v" in query=*) q="${v#query=}";; esac
  [ "$a" = "-F" ] && case "$v" in cursor=*) cursor="${v#cursor=}";; esac
done
case "$q" in
  *"fields(first:30)"*)
    echo '{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"DONE","name":"Done"},{"id":"INPROG","name":"In Progress"},{"id":"BACKLOG","name":"Backlog"}]}]}}}}}'; exit 0;;
  *"items(first:25"*)
    n=$(cat "$state/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$state/calls"
    if [ "$n" -le "${FAKE_FAIL_FIRST:-0}" ]; then echo "gh: Something went wrong while executing your query" >&2; exit 1; fi
    if [ -n "$FAKE_FAIL_TIMELINE" ] && [[ "$q" == *timelineItems* ]]; then echo "gh: Something went wrong while executing your query" >&2; exit 1; fi
    page=1; [ -n "$cursor" ] && page=$((cursor+1))
    more=false; [ "$page" -lt "${FAKE_PAGES:-1}" ] && more=true
    echo "{\"data\":{\"node\":{\"items\":{\"pageInfo\":{\"hasNextPage\":$more,\"endCursor\":\"$page\"},\"nodes\":[{\"id\":\"I$page\",\"fieldValues\":{\"nodes\":[{\"field\":{\"name\":\"Status\"},\"optionId\":\"BACKLOG\"}]},\"content\":{\"number\":$((100+page)),\"state\":\"OPEN\",\"assignees\":{\"nodes\":[{\"login\":\"x\"}]},\"timelineItems\":{\"nodes\":[{\"willCloseTarget\":true,\"source\":{\"number\":9,\"state\":\"OPEN\",\"merged\":false}}]}}}]}}}}"; exit 0;;
  *"updateProjectV2ItemFieldValue"*)
    for ((i=1; i<=$#; i++)); do a="${!i}"; n=$((i+1)); v="${!n}"; [ "$a" = "-F" ] && case "$v" in opt=*) echo "${v#opt=}" >> "$state/mutations";; esac; done
    echo '{}'; exit 0;;
esac
echo '{}'
'@
        $script:Bin = Join-Path $script:Root 'bin'
        New-Item -ItemType Directory -Force $script:Bin | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Bin 'gh'), ($fake -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { & chmod +x (Join-Path $script:Bin 'gh') }

        function script:RunSync {
            param([hashtable]$Env = @{})
            $state = Join-Path $script:Root ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Force $state | Out-Null
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:BashExe)
            $psi.ArgumentList.Add($script:Sync.Path)
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
            $sep = [IO.Path]::PathSeparator
            $psi.Environment['PATH'] = "$script:Bin$sep$($env:PATH)"
            $psi.Environment['FAKE_STATE'] = $state
            $psi.Environment['BOARD_SYNC_BACKOFF'] = '0'
            foreach ($k in $Env.Keys) { $psi.Environment[$k] = "$($Env[$k])" }
            $p = [System.Diagnostics.Process]::Start($psi)
            try {
                $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(60000)) { throw 'board-sync.sh did not finish within 60 seconds' }
                $muts = Join-Path $state 'mutations'
                [pscustomobject]@{
                    Exit      = $p.ExitCode
                    Out       = $o.GetAwaiter().GetResult()
                    Err       = $e.GetAwaiter().GetResult()
                    Mutations = @(if (Test-Path -LiteralPath $muts) { Get-Content -LiteralPath $muts })
                }
            }
            finally { if (-not $p.HasExited) { try { $p.Kill($true) } catch { } }; $p.Dispose() }
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads every page and, on a board whose not-started option is Backlog, still moves an issue with an open PR to In Progress' {
        $r = script:RunSync @{ FAKE_PAGES = 3 }
        $r.Exit | Should -Be 0
        $r.Out | Should -Match 'Items found: 3\s+\(3 page\(s\)\)'
        # One update per item, to the In Progress option: the Backlog fallback resolved the not-started id.
        @($r.Mutations | Where-Object { $_ -eq 'INPROG' }).Count | Should -Be 3
    }

    It 'rides out a transient server-side failure' {
        $r = script:RunSync @{ FAKE_PAGES = 1; FAKE_FAIL_FIRST = 2 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match 'attempt 2/3'
        $r.Out | Should -Match 'Items found: 1'
    }

    It 'when the query keeps failing, exits non-zero and names the part that breaks' {
        $r = script:RunSync @{ FAKE_PAGES = 1; FAKE_FAIL_TIMELINE = 1 }
        $r.Exit | Should -Not -Be 0
        $r.Err | Should -Match "variant 'full': FAILS"
        $r.Err | Should -Match "variant 'without timelineItems': OK"
    }
}
