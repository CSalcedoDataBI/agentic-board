#Requires -Modules Pester
<#  Tests for scripts/board-sync.sh - the workflow that reconciles the board (#679).

    The items query started failing in CI with a bare "Something went wrong while executing your
    query" and the script died with no cause. CI experiments showed the failure is neither transient
    nor about the query shape: one PAGE of items fails as a whole while every item in it reads fine
    on its own. The script therefore pages in small chunks, retries, and re-reads a failing page one
    item at a time, degrading only what cannot be read. These drive the REAL script with a fake
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

        # A fake `gh`. It serves FAKE_ITEMS items (default 3) numbered 101.., each Backlog with one open
        # PR, and honours `first:N` and the cursor. Knobs:
        #   FAKE_FAIL_FIRST=n         the first n items calls fail (a transient error)
        #   FAKE_FAIL_ALL=1           every items call fails
        #   FAKE_POISON=i             any request for MORE THAN ONE item that covers item i fails - the
        #                             real failure: a page fails as a whole, each item reads alone
        #   FAKE_POISON_TIMELINE=i    any request covering item i that asks for timelineItems fails
        #   FAKE_POISON_HARD=i        any request covering item i fails, except the minimal id-only one
        #   FAKE_GARBAGE_BATCH=1      a request for more than one item answers 200 with a body that is not JSON
        #   FAKE_GARBAGE_SINGLE=1     a request for a single item answers 200 with valid JSON that is NOT a page
        #                             (no pageInfo): the case that used to end the pagination silently
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
fail() { echo "gh: Something went wrong while executing your query" >&2; exit 1; }
case "$q" in
  *"fields(first:30)"*)
    echo '{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"DONE","name":"Done"},{"id":"INPROG","name":"In Progress"},{"id":"BACKLOG","name":"Backlog"}]}]}}}}}'; exit 0;;
  *"updateProjectV2ItemFieldValue"*)
    for ((i=1; i<=$#; i++)); do a="${!i}"; n=$((i+1)); v="${!n}"; [ "$a" = "-F" ] && case "$v" in opt=*) echo "${v#opt=}" >> "$state/mutations";; esac; done
    echo '{}'; exit 0;;
  *"items(first:"*)
    n=$(cat "$state/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$state/calls"
    [ "$n" -le "${FAKE_FAIL_FIRST:-0}" ] && fail
    [ -n "$FAKE_FAIL_ALL" ] && fail
    [[ "$q" =~ items\(first:([0-9]+) ]]; size="${BASH_REMATCH[1]}"
    total="${FAKE_ITEMS:-3}"; start=$(( ${cursor:-0} + 1 )); end=$(( start + size - 1 )); [ "$end" -gt "$total" ] && end=$total
    has_tl=0; [[ "$q" == *timelineItems* ]] && has_tl=1
    minimal=0; [[ "$q" != *fieldValues* ]] && minimal=1
    covers() { [ -n "$1" ] && [ "$1" -ge "$start" ] && [ "$1" -le "$end" ]; }
    if covers "$FAKE_POISON" && [ "$size" -gt 1 ]; then fail; fi
    if covers "$FAKE_POISON_TIMELINE" && [ "$has_tl" = 1 ]; then fail; fi
    if covers "$FAKE_POISON_HARD" && [ "$minimal" = 0 ]; then fail; fi
    [ -n "$FAKE_GARBAGE_BATCH" ] && [ "$size" -gt 1 ] && { echo 'not json at all'; exit 0; }
    [ -n "$FAKE_GARBAGE_SINGLE" ] && [ "$size" -eq 1 ] && { echo '{"data":{"node":{"items":{"nodes":[]}}}}'; exit 0; }
    nodes=$(for ((k=start; k<=end; k++)); do
      jq -cn --argjson i "$k" --argjson tl "$has_tl" --argjson min "$minimal" '
        if $min == 1 then {id: ("I" + ($i|tostring))}
        else {id: ("I" + ($i|tostring)),
              fieldValues: {nodes: [{field: {name: "Status"}, optionId: "BACKLOG"}]},
              content: ({number: (100 + $i), state: "OPEN", assignees: {nodes: [{login: "x"}]}}
                        + (if $tl == 1 then {timelineItems: {nodes: [{willCloseTarget: true, source: {number: 9, state: "OPEN", merged: false}}]}} else {} end))} end'
    done | jq -cs '.')
    more=false; [ "$end" -lt "$total" ] && more=true
    jq -cn --argjson nodes "$nodes" --arg more "$more" --arg end "$end" \
      '{data: {node: {items: {pageInfo: {hasNextPage: ($more == "true"), endCursor: $end}, nodes: $nodes}}}}'
    exit 0;;
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
            $psi.Environment['BOARD_SYNC_PAGE_SIZE'] = '2'
            foreach ($k in $Env.Keys) { $psi.Environment[$k] = "$($Env[$k])" }
            $p = [System.Diagnostics.Process]::Start($psi)
            try {
                $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(90000)) { throw 'board-sync.sh did not finish within 90 seconds' }
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
        $r = script:RunSync @{ FAKE_ITEMS = 5 }
        $r.Exit | Should -Be 0
        $r.Out | Should -Match 'Items found: 5\s+\(3 page\(s\)\)'
        # One update per item, to the In Progress option: the Backlog fallback resolved the not-started id.
        @($r.Mutations | Where-Object { $_ -eq 'INPROG' }).Count | Should -Be 5
    }

    It 'rides out a transient server-side failure' {
        $r = script:RunSync @{ FAKE_ITEMS = 2; FAKE_FAIL_FIRST = 1 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match 'attempt 1/3'
        $r.Out | Should -Match 'Items found: 2'
    }

    It 'salvages a page that fails as a whole by reading it one item at a time, losing nothing' {
        # The failure seen in CI: the page holding item 4 fails, yet every item reads fine alone.
        $r = script:RunSync @{ FAKE_ITEMS = 5; FAKE_POISON = 4 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match 'reading it item by item'
        $r.Err | Should -Not -Match '::warning'
        $r.Out | Should -Match 'Items found: 5'
        @($r.Mutations | Where-Object { $_ -eq 'INPROG' }).Count | Should -Be 5
    }

    It 'keeps an item that only fails with its linked PRs, without them, and says which one' {
        $r = script:RunSync @{ FAKE_ITEMS = 5; FAKE_POISON_TIMELINE = 4 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match '::warning::board-sync: item #104 was read WITHOUT its linked PRs'
        $r.Out | Should -Match 'Items found: 5'
        # Item 104 has no PR data, so it is not moved: the other four are.
        @($r.Mutations | Where-Object { $_ -eq 'INPROG' }).Count | Should -Be 4
    }

    It 'skips an item that cannot be read at all, loudly, and carries on with the rest' {
        $r = script:RunSync @{ FAKE_ITEMS = 5; FAKE_POISON_HARD = 4 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match '::warning::board-sync: skipped an item that could not be read at all'
        $r.Out | Should -Match 'Items found: 4'
    }

    It 'treats a 200 with a broken body as a failed page and salvages it, instead of trusting it' {
        $r = script:RunSync @{ FAKE_ITEMS = 5; FAKE_GARBAGE_BATCH = 1 }
        $r.Exit | Should -Be 0
        $r.Err | Should -Match 'the response was not a page'
        $r.Out | Should -Match 'Items found: 5'
    }

    It 'ends the run, rather than truncating the list, when a salvaged response is not a page' {
        # salvage runs where bash suspends set -e; a bad response there used to end the pagination
        # early and the sync reported success over a partial board.
        $r = script:RunSync @{ FAKE_ITEMS = 5; FAKE_POISON = 4; FAKE_GARBAGE_SINGLE = 1 }
        $r.Exit | Should -Not -Be 0
        $r.Err | Should -Match '::error::board-sync'
        $r.Out | Should -Not -Match 'Items found'
    }

    It 'fails loudly when nothing can be read, instead of reporting a clean sync' {
        $r = script:RunSync @{ FAKE_ITEMS = 3; FAKE_FAIL_ALL = 1 }
        $r.Exit | Should -Not -Be 0
        $r.Err | Should -Match '::error::board-sync'
    }
}
