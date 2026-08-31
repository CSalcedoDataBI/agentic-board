#Requires -Modules Pester
<#  Tests for scripts/Invoke-Gh.ps1 (#311, part of #303).

    The whole point of the helper is that a gh failure must NOT be readable as an empty
    result, so almost every test here asserts a THROW. The one that matters most is the
    pair: gh exiting non-zero must throw, and gh legitimately returning an empty list must
    NOT - if those two collapse into each other the helper has failed at its only job.

    Invoke-GhRaw is the seam: it is the single place the gh executable is touched, so
    mocking it simulates any exit code / body with no token and no network. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-Gh.ps1' | Resolve-Path
    . $script:Script
}

Describe 'Invoke-Gh (a non-zero exit is a failure, not an empty result)' {

    It 'returns stdout when gh succeeds' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = 'hello'; ExitCode = 0; StdErr = '' } }
        Invoke-Gh -GhArgs @('repo', 'view') | Should -Be 'hello'
    }

    It 'THROWS when gh exits non-zero - the #303 bug in one line' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Invoke-Gh -GhArgs @('project', 'view', '13') } | Should -Throw
    }

    It 'names the operation and the exit code in the message' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 4; StdErr = 'HTTP 401: Bad credentials' } }
        { Invoke-Gh -GhArgs @('project', 'view') -What 'leer el board #13' } |
            Should -Throw -ExpectedMessage '*leer el board #13*'
    }

    It 'surfaces gh stderr in the message (2>$null used to bury it)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Invoke-Gh -GhArgs @('project', 'view') } | Should -Throw -ExpectedMessage '*Bad credentials*'
    }
}

Describe 'Invoke-Gh -Json' {

    It 'parses the body on success' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"name":"board"}'; ExitCode = 0; StdErr = '' } }
        (Invoke-Gh -GhArgs @('project', 'view') -Json).name | Should -Be 'board'
    }

    It 'returns an EMPTY list as an empty list - a real empty board is not an error' {
        # The other half of the contract. If this throws, every caller learns to catch,
        # and the catch swallows the real failures again.
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '[]'; ExitCode = 0; StdErr = '' } }
        @(Invoke-Gh -GhArgs @('issue', 'list') -Json).Count | Should -Be 0
    }

    It 'THROWS on empty stdout - gh --json always emits at least [] or {}' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('project', 'view') -Json } | Should -Throw -ExpectedMessage '*sin salida*'
    }

    It 'THROWS on a body that is not JSON, instead of returning $null' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = 'not json at all'; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('project', 'view') -Json } | Should -Throw
    }

    It 'joins a multi-line body before parsing (gh emits an array of lines)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @('{', '"name":"board"', '}'); ExitCode = 0; StdErr = '' } }
        (Invoke-Gh -GhArgs @('project', 'view') -Json).name | Should -Be 'board'
    }
}

Describe 'Invoke-Gh -RawJson (validate as JSON, hand back the text)' {
    # For callers that PERSIST what gh sent (Backup-Board). Re-serialising a backup would
    # reshape it and -Depth would truncate it, so the text has to survive - but validated,
    # or the snapshot is worthless.

    It 'returns a STRING, not a parsed object' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"title":"My Board"}'; ExitCode = 0; StdErr = '' } }
        $r = Invoke-Gh -GhArgs @('project', 'view') -RawJson
        $r | Should -BeOfType [string]
        $r | Should -Be '{"title":"My Board"}'
    }

    It 'still THROWS on an unparseable body - text, but validated text' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = 'not json'; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('project', 'view') -RawJson } | Should -Throw
    }

    It 'still THROWS on an empty body (it implies -Json)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('project', 'view') -RawJson } | Should -Throw -ExpectedMessage '*sin salida*'
    }

    It 'still THROWS on a non-zero exit' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Invoke-Gh -GhArgs @('project', 'view') -RawJson } | Should -Throw
    }

    It 'still honours the graphql errors[] check when combined with -Graphql' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"errors":[{"message":"nope"}]}'; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('api', 'graphql') -RawJson -Graphql } | Should -Throw -ExpectedMessage '*nope*'
    }

    It 'does not reshape the body it was given' {
        # The whole point: a parsed round-trip would reorder/retype this; the text does not.
        $body = '{"z":1,"a":{"deep":{"deeper":[1,2,3]}}}'
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = $body; ExitCode = 0; StdErr = '' } }.GetNewClosure()
        Invoke-Gh -GhArgs @('x') -RawJson | Should -Be $body
    }
}

Describe 'Invoke-Gh -Graphql (exit 0 WITH an errors[] body)' {
    # graphql's separate failure mode: the request succeeds, the query does not.

    It 'THROWS when the body carries errors[], despite exit 0' {
        Mock Invoke-GhRaw {
            [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"Could not resolve to a node"}]}'; ExitCode = 0; StdErr = '' }
        }
        { Invoke-Gh -GhArgs @('api', 'graphql') -Json -Graphql } |
            Should -Throw -ExpectedMessage '*Could not resolve to a node*'
    }

    It 'does NOT throw on a clean graphql body' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"node":{"id":"X"}}}'; ExitCode = 0; StdErr = '' } }
        (Invoke-Gh -GhArgs @('api', 'graphql') -Json -Graphql).data.node.id | Should -Be 'X'
    }

    It 'does NOT treat a non-graphql field called errors as a failure unless -Graphql is set' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"errors":["a"]}'; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('api', 'x') -Json } | Should -Not -Throw
    }

    It 'ignores an EMPTY errors[] (some responses include it empty)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"x":1},"errors":[]}'; ExitCode = 0; StdErr = '' } }
        { Invoke-Gh -GhArgs @('api', 'graphql') -Json -Graphql } | Should -Not -Throw
    }

    It 'THROWS on errors[] even WITHOUT -Json - the switch must never be a silent no-op' {
        # -Graphql alone used to return the raw body before the errors[] check ran, so a
        # caller that asked for the check silently got none: bug #303 restored at exactly
        # the call sites this switch exists for. -Graphql now implies -Json.
        Mock Invoke-GhRaw {
            [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"Could not resolve to a node"}]}'; ExitCode = 0; StdErr = '' }
        }
        { Invoke-Gh -GhArgs @('api', 'graphql') -What 'mover el item' -Graphql } |
            Should -Throw -ExpectedMessage '*Could not resolve to a node*'
    }

    It 'parses the body under -Graphql alone (it implies -Json)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"node":{"id":"X"}}}'; ExitCode = 0; StdErr = '' } }
        (Invoke-Gh -GhArgs @('api', 'graphql') -Graphql).data.node.id | Should -Be 'X'
    }
}

Describe 'Test-GhTransientError (only retry what retrying can fix)' {
    It 'treats 5xx as transient' {
        Test-GhTransientError -StdErr 'HTTP 502: Bad gateway' | Should -BeTrue
        Test-GhTransientError -StdErr 'HTTP 503' | Should -BeTrue
    }
    It 'treats timeouts and connection resets as transient' {
        Test-GhTransientError -StdErr 'error connecting: i/o timeout' | Should -BeTrue
    }
    It 'does NOT treat auth failure as transient - retrying a 401 is just slower' {
        Test-GhTransientError -StdErr 'HTTP 401: Bad credentials' | Should -BeFalse
    }
    It 'does NOT treat a 404 as transient' {
        Test-GhTransientError -StdErr 'HTTP 404: Not Found' | Should -BeFalse
    }
    It 'is false for empty stderr' {
        Test-GhTransientError -StdErr '' | Should -BeFalse
    }
    It 'treats a SECONDARY rate limit as transient - what -Parallel actually produces' {
        Test-GhTransientError -StdErr 'HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes.' |
            Should -BeTrue
    }
    It 'does NOT treat a plain permissions 403 as transient (matched by text, not status)' {
        Test-GhTransientError -StdErr 'HTTP 403: Resource not accessible by integration' | Should -BeFalse
    }
    It 'matches case-insensitively (gh has changed the casing of these strings before)' {
        Test-GhTransientError -StdErr 'http 502: bad gateway' | Should -BeTrue
    }
}

Describe 'Invoke-Gh -Retries' {
    It 'retries a transient failure and succeeds' {
        $script:calls = 0
        Mock Invoke-GhRaw {
            $script:calls++
            if ($script:calls -lt 3) { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 502: Bad gateway' } }
            else                     { [pscustomobject]@{ Output = 'ok'; ExitCode = 0; StdErr = '' } }
        }
        Invoke-Gh -GhArgs @('project', 'view') -Retries 3 -RetryDelayMs 1 | Should -Be 'ok'
        $script:calls | Should -Be 3
    }

    It 'does NOT retry a 401 - it fails on the first attempt' {
        $script:calls = 0
        Mock Invoke-GhRaw { $script:calls++; [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Invoke-Gh -GhArgs @('project', 'view') -Retries 3 -RetryDelayMs 1 } | Should -Throw
        $script:calls | Should -Be 1
    }

    It 'gives up after the last retry and still THROWS (never returns empty)' {
        $script:calls = 0
        Mock Invoke-GhRaw { $script:calls++; [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 502' } }
        { Invoke-Gh -GhArgs @('project', 'view') -Retries 2 -RetryDelayMs 1 } | Should -Throw
        $script:calls | Should -Be 3      # first attempt + 2 retries
    }
}

Describe 'Invoke-GhRaw against the REAL gh (the seam every other test mocks away)' {
    # These exist because the mocked suite above passed 22/22 while Invoke-GhRaw was
    # broken for EVERY successful call: -Raw on the empty stderr file returns $null, and
    # ([string]$null).Trim() throws. Mocking the seam proves the logic on top of it and
    # nothing about the seam itself, so the seam gets real calls.
    #
    # `gh --version` needs no token and no network, so this is CI-safe.
    #
    # The probe sits in the Describe BODY, not in BeforeAll: -Skip is evaluated at
    # DISCOVERY, so a BeforeAll variable is still $null when Pester reads it and every
    # test below would silently skip - passing while testing nothing.
    $hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)

    It 'reports exit 0 and clean stdout on success, with EMPTY stderr (the null-Trim bug)' -Skip:(-not $hasGh) {
        $r = Invoke-GhRaw -GhArgs @('--version')
        $r.ExitCode | Should -Be 0
        $r.StdErr   | Should -Be ''            # would THROW before, not return ''
        ($r.Output -join ' ') | Should -Match 'gh version'
    }

    It 'reports a non-zero exit and captures stderr on failure' -Skip:(-not $hasGh) {
        $r = Invoke-GhRaw -GhArgs @('this-subcommand-does-not-exist')
        $r.ExitCode | Should -Not -Be 0
        $r.StdErr   | Should -Not -BeNullOrEmpty
    }

    It 'end-to-end: a real failing gh call THROWS through Invoke-Gh' -Skip:(-not $hasGh) {
        { Invoke-Gh -GhArgs @('this-subcommand-does-not-exist') -What 'probar el seam' } |
            Should -Throw -ExpectedMessage '*probar el seam*'
    }

    It 'end-to-end: a real succeeding gh call returns its output' -Skip:(-not $hasGh) {
        (Invoke-Gh -GhArgs @('--version') -What 'leer la version') -join ' ' | Should -Match 'gh version'
    }
}

Describe 'Invoke-Gh -StdIn (the `gh api graphql --input -` sites)' {
    # Apply-FieldPreset.ps1 feeds graphql over stdin. The obvious conversion,
    # `$body | Invoke-Gh -GhArgs @('api','graphql','--input','-')`, does NOT work and does
    # NOT fail: a native command inside a function never sees the function's pipeline
    # input, so gh blocks on the console forever. Under a headless -Launch fleet session a
    # silent hang is worse than the 401 this whole file exists to stop - hence -StdIn.

    It 'the in-function pipe idiom Invoke-GhRaw relies on really reaches a native stdin' {
        # Pins the IDIOM (`$var | & <native>` built INSIDE the function), not Invoke-GhRaw's
        # own line - that one hardcodes gh, and `gh api graphql --input -` would need a token
        # and the network. git is in this repo's toolchain and reads stdin, so it stands in.
        # Mocking would prove nothing here: the hang IS the seam.
        #
        # Run in a job with a timeout so that a REGRESSION (gh blocking on the console) fails
        # this test instead of wedging the whole suite forever - which is what the bug does.
        $sha = ''
        $job = Start-Job { $body = 'hello'; $body | & git hash-object --stdin 2>$null }
        if (Wait-Job $job -Timeout 20) { $sha = (Receive-Job $job) -join '' }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        # Asserting a NON-empty sha, not a literal one: the exact hash depends on the line
        # ending PowerShell's pipe appends (CRLF here -> ef0493b..., not the "hello\n"
        # value every reference would tell you). What is under test is that the bytes
        # arrived at all; pinning the platform's newline would only make this brittle.
        $sha | Should -Match '^[0-9a-f]{40}$'
    }

    It 'passes -StdIn through Invoke-Gh to Invoke-GhRaw' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"ok":1}}'; ExitCode = 0; StdErr = '' } } -ParameterFilter { $StdIn -eq 'BODY' }
        (Invoke-Gh -GhArgs @('api', 'graphql', '--input', '-') -StdIn 'BODY' -Graphql).data.ok | Should -Be 1
        Should -Invoke Invoke-GhRaw -Times 1 -Exactly -ParameterFilter { $StdIn -eq 'BODY' }
    }

    It 'does not pass -StdIn when the caller did not ask for it' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = 'ok'; ExitCode = 0; StdErr = '' } }
        Invoke-Gh -GhArgs @('repo', 'view') | Out-Null
        Should -Invoke Invoke-GhRaw -Times 1 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('StdIn') }
    }
}

Describe 'Dot-sourcing Invoke-Gh.ps1 is side-effect free' {
    It 'defines the functions without invoking gh or writing output' {
        # Every consumer dot-sources it at load; a script that ran anything here would
        # fire on import, including inside the ABIOS_*_DOTSOURCE test guards.
        $out = . $script:Script
        $out | Should -BeNullOrEmpty
        (Get-Command Invoke-Gh -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-GhCached - the read cache (#571)' {
    BeforeAll {
        # Redirect the cache dir per-test-run by mocking; the cache itself keys on args.
        Clear-GhCache
    }
    AfterAll { Clear-GhCache }

    It 'a HIT within TTL does not touch gh again' {
        $script:calls = 0
        Mock Invoke-GhRaw {
            $script:calls++
            [pscustomobject]@{ Output = '{"fields":[{"name":"Status"}]}'; ExitCode = 0; StdErr = '' }
        }
        $a = Invoke-GhCached -GhArgs @('project','field-list','99','--format','json') -What 'x' -Json -TtlSec 300
        $b = Invoke-GhCached -GhArgs @('project','field-list','99','--format','json') -What 'x' -Json -TtlSec 300
        $script:calls | Should -Be 1
        $b.fields[0].name | Should -Be 'Status'
    }
    It 'different args are different cache keys' {
        $script:calls2 = 0
        Mock Invoke-GhRaw {
            $script:calls2++
            [pscustomobject]@{ Output = '{"n":1}'; ExitCode = 0; StdErr = '' }
        }
        $null = Invoke-GhCached -GhArgs @('project','view','1') -What 'x' -Json -TtlSec 300
        $null = Invoke-GhCached -GhArgs @('project','view','2') -What 'x' -Json -TtlSec 300
        $script:calls2 | Should -Be 2
    }
    It '-Force busts the cache' {
        $script:calls3 = 0
        Mock Invoke-GhRaw {
            $script:calls3++
            [pscustomobject]@{ Output = '{"n":1}'; ExitCode = 0; StdErr = '' }
        }
        $null = Invoke-GhCached -GhArgs @('project','view','7') -What 'x' -Json -TtlSec 300
        $null = Invoke-GhCached -GhArgs @('project','view','7') -What 'x' -Json -TtlSec 300 -Force
        $script:calls3 | Should -Be 2
    }
    It 'a FAILURE is never cached - the next call fails again instead of inheriting a ghost' {
        Clear-GhCache
        $script:mode = 'fail'
        Mock Invoke-GhRaw {
            if ($script:mode -eq 'fail') { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401' } }
            else { [pscustomobject]@{ Output = '{"ok":true}'; ExitCode = 0; StdErr = '' } }
        }
        { Invoke-GhCached -GhArgs @('project','view','8') -What 'x' -Json -TtlSec 300 } | Should -Throw
        $script:mode = 'ok'
        (Invoke-GhCached -GhArgs @('project','view','8') -What 'x' -Json -TtlSec 300).ok | Should -BeTrue
    }
    It 'TtlSec 0 always fetches fresh' {
        $script:calls5 = 0
        Mock Invoke-GhRaw {
            $script:calls5++
            [pscustomobject]@{ Output = '{"n":1}'; ExitCode = 0; StdErr = '' }
        }
        $null = Invoke-GhCached -GhArgs @('project','view','9') -What 'x' -Json -TtlSec 0
        $null = Invoke-GhCached -GhArgs @('project','view','9') -What 'x' -Json -TtlSec 0
        $script:calls5 | Should -Be 2
    }
}

Describe 'Invoke-GhCached -Graphql on a HIT (#571 round 2)' {
    It 'a cached errors[] payload is a MISS, not a success' {
        Clear-GhCache
        # Seed the cache with an errors body via a -Json call (same args, same key).
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"errors":[{"message":"boom"}]}'; ExitCode = 0; StdErr = '' } }
        $null = Invoke-GhCached -GhArgs @('api','graphql','-f','query=q1') -What 'x' -Json -TtlSec 300
        # The -Graphql read of the same key must NOT accept it; the fresh fetch then throws.
        { Invoke-GhCached -GhArgs @('api','graphql','-f','query=q1') -What 'x' -Graphql -TtlSec 300 } | Should -Throw
    }
}
