#Requires -Modules Pester
<#  Probe codes are a closed set, classified per adapter (#770).

    Before #770 one regex list classified every CLI's probe output, and exit 0 with no failure
    word was 'ok' - the shape of the false passes behind #651 / #661. These tests pin, for EACH
    adapter (claude, codex, copilot, jules, antigravity), against recorded sample outputs:
      * the expected answer is OK, and only on exit 0;
      * an auth failure is AUTH and a quota / limit message is QUOTA or RATE_LIMIT - even on exit 0;
      * output no rule recognises fails CLOSED to ERROR, never to OK.
    No CLI is run and nothing touches the network: the classifier is pure.

    Samples marked "recorded" were captured from the real CLI (personal data replaced); the rest
    are the vendor's message shapes as reported by users of those CLIs.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    . (Join-Path $script:ScriptDir 'BoardWork.Adapters.ps1')
    function script:Code { param([string]$Cli, [int]$Exit, [string]$Out) ConvertTo-CliProbeCode -Cli $Cli -ExitCode $Exit -Output $Out }

    # recorded: `jules remote list --session` (rows replaced with invented ones)
    $script:JulesTable = @(
        '           ID                                    Description                                    Repo                Last active                Status         '
        ' 11111111111111111111    fix the rate limit in the importer                            owner/repo              2 days ago              Completed      '
        ' 22222222222222222222    quota report page                                             owner/repo              5 days ago              Awaiting User F'
    ) -join "`n"
}

Describe 'The closed set (#770)' {
    It 'is exactly OK | AUTH | RATE_LIMIT | QUOTA | CONTEXT_WINDOW | ERROR' {
        Get-CliProbeCodes | Should -Be @('OK', 'AUTH', 'RATE_LIMIT', 'QUOTA', 'CONTEXT_WINDOW', 'ERROR')
    }
    It 'keeps NOT_INSTALLED and NEEDS_BYPASS OUTSIDE the probe set - they are availability, not probe results' {
        Get-CliProbeCodes | Should -Not -Contain 'NOT_INSTALLED'
        Get-CliProbeCodes | Should -Not -Contain 'NEEDS_BYPASS'
        Get-CliAvailabilityStates | Should -Contain 'NOT_INSTALLED'
        Get-CliAvailabilityStates | Should -Contain 'NEEDS_BYPASS'
    }
    It 'pins anything outside the set to ERROR, case-sensitively (an old lower-case ok is not OK)' {
        Confirm-CliProbeCode 'OK'       | Should -BeExactly 'OK'
        Confirm-CliProbeCode 'ok'       | Should -BeExactly 'ERROR'
        Confirm-CliProbeCode 'no-quota' | Should -BeExactly 'ERROR'
        Confirm-CliProbeCode ''         | Should -BeExactly 'ERROR'
    }
    It 'every adapter declares its own ProbeRules, each rule carrying a code from the set and an OK rule' {
        foreach ($a in (Get-CliAdapters)) {
            @($a.ProbeRules).Count | Should -BeGreaterThan 0 -Because $a.Name
            foreach ($r in $a.ProbeRules) { Get-CliProbeCodes | Should -Contain $r.Code -Because $a.Name }
            @($a.ProbeRules | Where-Object Code -ceq 'OK').Count | Should -Be 1 -Because "$($a.Name) needs positive evidence for OK"
        }
    }
    It 'an unknown CLI has no rules, so nothing it prints can be OK' {
        Code 'no-such-cli' 0 'OK' | Should -Be 'ERROR'
    }
    It 'every classification lands in the set, for every adapter and every sample' {
        $samples = @('', 'OK', 'boom', 'HTTP 429', 'quota exceeded', 'Not logged in', 'prompt is too long', $script:JulesTable)
        foreach ($a in (Get-CliAdapters)) {
            foreach ($s in $samples) { foreach ($e in 0, 1) {
                Get-CliProbeCodes | Should -Contain (Code $a.Name $e $s) -Because "$($a.Name) exit $e '$s'"
            } }
        }
    }
}

Describe 'claude' {
    It 'OK: answered' { Code 'claude' 0 'OK' | Should -Be 'OK' }
    It 'the probe itself runs nothing and returns OK (claude hosts this script)' {
        (& (Get-CliAdapters | Where-Object Name -eq 'claude').Probe $null) | Should -BeExactly 'OK'
    }
    It 'AUTH: invalid key / expired login' {
        Code 'claude' 1 'Invalid API key · Please run /login' | Should -Be 'AUTH'
        Code 'claude' 1 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}' | Should -Be 'AUTH'
    }
    It 'QUOTA: the subscription usage limit, even on exit 0' {
        Code 'claude' 0 'Claude AI usage limit reached|1767225600' | Should -Be 'QUOTA'
    }
    It 'RATE_LIMIT: the API rate-limit error' {
        Code 'claude' 1 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}' | Should -Be 'RATE_LIMIT'
    }
    It 'CONTEXT_WINDOW: the prompt does not fit' {
        Code 'claude' 1 'Prompt is too long' | Should -Be 'CONTEXT_WINDOW'
    }
    It 'unknown -> ERROR' {
        Code 'claude' 0 'Welcome to Claude Code!' | Should -Be 'ERROR'
        Code 'claude' 1 'segmentation fault' | Should -Be 'ERROR'
    }
}

Describe 'codex' {
    It 'OK: logged in (recorded)' {
        Code 'codex' 0 'Logged in using ChatGPT' | Should -Be 'OK'
        Code 'codex' 0 'Logged in using an API key - sk-proj-***' | Should -Be 'OK'
    }
    It 'AUTH: not logged in - the OK phrase inside it never wins' {
        Code 'codex' 1 'Not logged in' | Should -Be 'AUTH'
        Code 'codex' 0 'Not logged in' | Should -Be 'AUTH'
    }
    It 'RATE_LIMIT / QUOTA' {
        Code 'codex' 1 "stream error: exceeded retry limit, last status: 429 Too Many Requests" | Should -Be 'RATE_LIMIT'
        Code 'codex' 1 "You've hit your usage limit. insufficient_quota" | Should -Be 'QUOTA'
    }
    It 'OK needs exit 0: a logged-in banner on a failing exit is not OK' {
        Code 'codex' 2 'Logged in using ChatGPT' | Should -Be 'ERROR'
    }
    It 'unknown -> ERROR' {
        Code 'codex' 0 'codex-cli 0.160.0' | Should -Be 'ERROR'
        Code 'codex' 0 '' | Should -Be 'ERROR'
    }
}

Describe 'copilot' {
    It 'OK: answered, with the healthy usage footer that mentions premium requests' {
        Code 'copilot' 0 "OK`n`nTotal usage est:        1 Premium request`nTotal duration (API):   2.1s" | Should -Be 'OK'
    }
    It 'AUTH: no credentials' {
        Code 'copilot' 1 'Error: No authentication information found. Please use /login to sign in.' | Should -Be 'AUTH'
    }
    It 'QUOTA: out of premium requests - and NOT OK even when it exits 0 and says OK (#651 shape)' {
        Code 'copilot' 0 "OK`nYou have exceeded your monthly quota of premium requests." | Should -Be 'QUOTA'
        Code 'copilot' 1 'Request failed with status 402: You have no remaining premium requests' | Should -Be 'QUOTA'
    }
    It 'RATE_LIMIT: hit a rate limit' {
        Code 'copilot' 0 "Sorry, you've hit a rate limit that restricts the number of Copilot model requests" | Should -Be 'RATE_LIMIT'
    }
    It 'unknown -> ERROR' {
        Code 'copilot' 0 'Thinking...' | Should -Be 'ERROR'
    }
}

Describe 'jules' {
    It 'OK: the session table (recorded header) - a session TITLE about rate limits or quota is not a failure' {
        Code 'jules' 0 $script:JulesTable | Should -Be 'OK'
    }
    It 'AUTH: not logged in' {
        Code 'jules' 1 'Error: you are not logged in. Run `jules login` first.' | Should -Be 'AUTH'
    }
    It 'RATE_LIMIT / QUOTA from the API, without a table' {
        Code 'jules' 1 'Error: rpc error: code = ResourceExhausted desc = Quota exceeded for quota metric' | Should -Be 'QUOTA'
        Code 'jules' 1 'Error: HTTP 429 Too Many Requests' | Should -Be 'RATE_LIMIT'
    }
    It 'unknown -> ERROR: "Must specify what to list" exits 0 and is NOT OK (recorded, the old false ok)' {
        Code 'jules' 0 'Error: Must specify what to list' | Should -Be 'ERROR'
    }
}

Describe 'antigravity' {
    It 'OK: replied OK' { Code 'antigravity' 0 'OK' | Should -Be 'OK' }
    It 'AUTH: the retired-client answer, printed on exit 0 (#537, #615)' {
        $txt = 'IneligibleTierError: This client is no longer supported (reasonCode: UNSUPPORTED_CLIENT, tierId: free-tier)'
        Code 'antigravity' 0 $txt | Should -Be 'AUTH'
        (Resolve-CliProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output $txt).Reason | Should -Match 'retired'
    }
    It 'QUOTA / RATE_LIMIT, even on exit 0' {
        Code 'antigravity' 0 'Error 429: quota exceeded' | Should -Be 'QUOTA'
        Code 'antigravity' 1 'RESOURCE_EXHAUSTED' | Should -Be 'QUOTA'
        Code 'antigravity' 1 'HTTP 429 Too Many Requests' | Should -Be 'RATE_LIMIT'
    }
    It 'an untrusted directory is ERROR with its reason, even on exit 0' {
        $o = Resolve-CliProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output 'not running in a trusted directory'
        $o.Code   | Should -Be 'ERROR'
        $o.Reason | Should -Match 'trusted directory'
    }
    It 'a healthy line that merely mentions quota, or carries 401/429 inside an id, is not a failure' {
        Code 'antigravity' 0 "Quota remaining: 500 requests`nOK" | Should -Be 'OK'
        Code 'antigravity' 0 'session a4012bc9429d ready: OK' | Should -Be 'OK'
    }
    It 'unknown -> ERROR, including silence on exit 0' {
        Code 'antigravity' 0 'Quota remaining: 500 requests' | Should -Be 'ERROR'
        (Resolve-CliProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output "  `r`n ").Reason | Should -Match 'printed nothing'
        Code 'antigravity' 3 'boom' | Should -Be 'ERROR'
    }
}

Describe 'Test-CliProbeExhausted - the fleet backoff (#770)' {
    It 'is true for QUOTA and RATE_LIMIT only' {
        Test-CliProbeExhausted 'QUOTA'      | Should -BeTrue
        Test-CliProbeExhausted 'RATE_LIMIT' | Should -BeTrue
        foreach ($c in 'OK', 'AUTH', 'CONTEXT_WINDOW', 'ERROR', 'NOT_INSTALLED', 'quota') { Test-CliProbeExhausted $c | Should -BeFalse -Because $c }
    }
}
