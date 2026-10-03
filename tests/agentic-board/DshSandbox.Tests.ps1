#Requires -Modules Pester
<#  The dsh adapter pilot (#773): DeepSeek Harness as a sandboxed, low-cost fleet backend.

    dsh runs ONLY inside the agentic-board/dsh image (containers/dsh). These tests pin the
    security terms of the pilot as CODE, with no Docker, no network and no CLI run:
      * the registry entry: docker is the command, no host install argv, never default/reviewer;
      * the launch line: docker run --rm, the worktree as the one bind mount, read-only root,
        tmpfs /tmp, limits, non-root, no host home, no docker socket, ONLY DEEPSEEK_API_KEY;
      * routing: docs/chore only, and only when the issue repo is known to be PUBLIC (fail closed);
        an override cannot widen its routes, make it a reviewer or clear the low-trust flag;
      * probe rules classify dsh's REAL outputs (captured from the pilot) into the closed code set;
      * the pin: base image by tag+digest, @deepseek-ai/dsh exact in package.json, every package in
        the lockfile with a version and integrity, no @latest / curl | sh;
      * the upload switches in the image (patch rows disabled, telemetry env, entrypoint refusals).  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:RepoRoot  = Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path
    $script:Box       = Join-Path $script:RepoRoot 'containers' 'dsh'
    $env:ABIOS_ADAPTERS_USER_FILE = Join-Path $TestDrive 'no-user-adapters.json'
    $env:ABIOS_ADAPTERS_REPO_FILE = Join-Path $TestDrive 'no-repo-adapters.json'
    $env:ABIOS_FLEETPLAN_DOTSOURCE = '1'
    . (Join-Path $script:ScriptDir 'Fleet-Plan.ps1')
    $env:ABIOS_FLEETPLAN_DOTSOURCE = ''
    . (Join-Path $script:ScriptDir 'Get-ReviewerRoster.ps1')

    $script:None = Join-Path $TestDrive 'absent.json'
    $script:A    = @(Get-CliAdapters -UserPath $script:None -RepoPath $script:None)
    $script:Dsh  = $script:A | Where-Object Name -eq 'dsh'
    $script:N = 0
    function script:New-Override([object[]]$Adapters) {
        $script:N++
        $p = Join-Path $TestDrive "dsh-override-$($script:N).json"
        Set-Content -LiteralPath $p -Value (@{ version = 1; adapters = @($Adapters) } | ConvertTo-Json -Depth 10) -Encoding utf8
        $p
    }
    # The launch line for a worktree, with and without the bypass opt-in.
    $script:Ctx  = @{ BriefingFile = "C:\Users\O'Brien\brief-12.txt"; WorkPath = 'D:\wt\agentic-board\issue-12'; AllowBypass = $false }
    $script:Line = & $script:Dsh.BuildLaunch $script:Ctx
}
AfterAll {
    $env:ABIOS_ADAPTERS_USER_FILE = $null
    $env:ABIOS_ADAPTERS_REPO_FILE = $null
}

Describe 'dsh registry entry (#773)' {
    It 'loads from the preset with valid fields' {
        $script:Dsh | Should -Not -BeNullOrEmpty
        $script:Dsh.Source | Should -Be 'preset'
        $script:Dsh.Kind | Should -Be 'repl'
        $script:Dsh.LowTrust | Should -BeTrue
    }
    It 'runs through docker, never as a host dsh binary, and has no host install argv' {
        $script:Dsh.Command | Should -BeExactly 'docker'
        $script:Dsh.InstallArgs | Should -BeNullOrEmpty
        $script:Dsh.InstallUrl | Should -Match '^https://github\.com/CSalcedoDataBI/agentic-board/tree/main/containers/dsh$'
        $script:Dsh.ProbeArgs[0] | Should -BeExactly 'docker'
        $script:Dsh.ProbeArgs[1] | Should -BeExactly 'run'
    }
    It 'is never the default nor a reviewer, and is not in the reviewer roster' {
        $script:Dsh.IsDefault | Should -BeFalse
        $script:Dsh.Reviewer | Should -BeFalse
        @($script:A | Where-Object Reviewer).Name | Should -Not -Contain 'dsh'
    }
    It 'needs no permission bypass headless, and offers none (#761)' {
        $script:Dsh.RequiresBypass | Should -BeFalse
        $script:Dsh.BypassArgs | Should -BeExactly ''
        $opted = $script:Ctx.Clone(); $opted.AllowBypass = $true
        (& $script:Dsh.BuildLaunch $opted) | Should -BeExactly $script:Line
    }
    It 'keeps only the DeepSeek credential through the secret scrub (#769)' {
        @($script:Dsh.KeepEnv) | Should -Be @('DEEPSEEK_API_KEY')
    }
}

Describe 'dsh launch line: the container is the sandbox (#773)' {
    It 'is one docker run --rm of the pinned local image, never pulled' {
        $script:Line | Should -Match '^docker run --rm --pull=never '
        $script:Line | Should -Match ' agentic-board/dsh:0\.2\.0-rc\.2 --profile headless --json '
    }
    It 'mounts the worktree as the ONLY bind mount, at /work, and works there' {
        $script:Line | Should -Match ([regex]::Escape("'--mount=type=bind,src=D:\wt\agentic-board\issue-12,dst=/work'"))
        ([regex]::Matches($script:Line, '--mount|--volume|(^| )-v ')).Count | Should -Be 1
        $script:Line | Should -Match ' --workdir=/work '
    }
    It 'has a read-only root, a tmpfs /tmp and CPU / memory / pid limits' {
        $script:Line | Should -Match ' --read-only '
        $script:Line | Should -Match " --tmpfs '/tmp:rw,exec,nosuid,nodev,size=512m' "
        $script:Line | Should -Match ' --cpus=2 '
        $script:Line | Should -Match ' --memory=2g '
        $script:Line | Should -Match ' --pids-limit=512 '
    }
    It 'drops privileges: non-root user, no capabilities, no-new-privileges' {
        $script:Line | Should -Match ' --user=node '
        $script:Line | Should -Match ' --cap-drop=ALL '
        $script:Line | Should -Match ' --security-opt=no-new-privileges '
        $script:Line | Should -Not -Match '--privileged'
    }
    It 'mounts no host home and no docker socket' {
        $script:Line | Should -Not -Match 'docker\.sock'
        $script:Line | Should -Not -Match '(?i)\\Users\\[^\\]+\\?(,|$| )|/home/|\$HOME|USERPROFILE|~'
    }
    It 'passes exactly one host variable, DEEPSEEK_API_KEY, by NAME (no value in the script)' {
        $envArgs = @([regex]::Matches($script:Line, '(?:--env[= ]|(?:^| )-e )(\S+)') | ForEach-Object { $_.Groups[1].Value })
        $envArgs | Should -Be @('DEEPSEEK_API_KEY')
        $script:Line | Should -Not -Match '--env-file|GH_TOKEN|GITHUB_TOKEN'
    }
    It 'points the telemetry collectors at 127.0.0.1 (the endpoint is blocked as well as switched off)' {
        $script:Line | Should -Match ' --add-host=dsh-otel-collector\.deepseeksvc\.com:127\.0\.0\.1 '
        $script:Line | Should -Match ' --add-host=harness-telemetry\.deepseeksvc\.com:127\.0\.0\.1 '
    }
    It 'passes the briefing as the task, read at run time' {
        $script:Line | Should -Match ([regex]::Escape("--json (Get-Content -Raw -LiteralPath 'C:\Users\O''Brien\brief-12.txt')") + '$')
    }
    It 'fails closed on a worktree path that would inject a mount option' {
        { & $script:Dsh.BuildLaunch @{ BriefingFile = 'C:\b.txt'; WorkPath = 'D:\wt\x,dst=/etc'; AllowBypass = $false } } | Should -Throw '*container mount*'
        { & $script:Dsh.BuildLaunch @{ BriefingFile = 'C:\b.txt'; WorkPath = ''; AllowBypass = $false } } | Should -Throw '*container mount*'
    }
    It 'the probe runs with the same isolation, no worktree mount, and no bypass' {
        $p = $script:Dsh.ProbeArgs -join ' '
        foreach ($flag in '--rm', '--pull=never', '--read-only', '--cap-drop=ALL', '--user=node', '--env=DEEPSEEK_API_KEY', '--memory=2g') { $p | Should -Match ([regex]::Escape($flag)) }
        $p | Should -Not -Match '--mount|--volume'
        $p | Should -Match 'agentic-board/dsh:0\.2\.0-rc\.2 --profile headless --json reply OK$'
    }
}

Describe 'dsh routing: docs/chore on PUBLIC repos only (#773)' {
    It 'ranks only the docs and chore routes' {
        @($script:Dsh.Routing.Keys | Sort-Object) | Should -Be @('chore', 'docs')
    }
    It 'is offered for docs/chore when the repo is PUBLIC, after antigravity/copilot and before claude' {
        Get-CliRoutePreference -Route 'docs'  -Adapters $script:A -Visibility 'PUBLIC' | Should -Be @('antigravity', 'copilot', 'dsh', 'claude')
        Get-CliRoutePreference -Route 'chore' -Adapters $script:A -Visibility 'public' | Should -Be @('copilot', 'antigravity', 'dsh', 'claude')
    }
    It 'is never offered for private, internal or unknown visibility (fails closed)' {
        foreach ($v in 'PRIVATE', 'INTERNAL', '', 'unknown', $null) {
            Get-CliRoutePreference -Route 'docs' -Adapters $script:A -Visibility $v | Should -Not -Contain 'dsh'
        }
        Get-CliRoutePreference -Route 'docs' -Adapters $script:A | Should -Not -Contain 'dsh'
    }
    It 'is never offered for the heavy, refactor or default routes' {
        foreach ($r in 'heavy', 'refactor', 'default') { Get-CliRoutePreference -Route $r -Adapters $script:A -Visibility 'PUBLIC' | Should -Not -Contain 'dsh' }
    }
    It 'Fleet-Plan picks dsh for a Docs or Chore issue of a PUBLIC repo when it is the available CLI' {
        Select-CliForIssue ([pscustomobject]@{ labels = @('docs'); type = $null; size = $null; visibility = 'PUBLIC' }) @('claude', 'dsh') | Should -Be 'dsh'
        Select-CliForIssue ([pscustomobject]@{ labels = @(); type = 'Chore'; size = 'M'; visibility = 'PUBLIC' }) @('dsh', 'claude') | Should -Be 'dsh'
    }
    It 'Fleet-Plan never picks dsh for a private or unknown-visibility repo, nor outside docs/chore' {
        Select-CliForIssue ([pscustomobject]@{ labels = @('docs'); visibility = 'PRIVATE' }) @('claude', 'dsh') | Should -Be 'claude'
        Select-CliForIssue ([pscustomobject]@{ labels = @('docs') }) @('claude', 'dsh') | Should -Be 'claude'
        Select-CliForIssue ([pscustomobject]@{ labels = @('security'); visibility = 'PUBLIC' }) @('claude', 'dsh') | Should -Be 'claude'
        Select-CliForIssue ([pscustomobject]@{ labels = @(); type = 'Feature'; visibility = 'PUBLIC' }) @('claude', 'dsh') | Should -Be 'claude'
    }
    It 'the launch re-check degrades dsh to claude unless the repo is PUBLIC' {
        $docs = @{ labels = @('docs') }
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts ([pscustomobject]($docs + @{ visibility = 'PUBLIC' }))).Cli  | Should -Be 'dsh'
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts ([pscustomobject]($docs + @{ visibility = 'PRIVATE' }))).Cli | Should -Be 'claude'
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts ([pscustomobject]($docs + @{ visibility = '' }))).Cli        | Should -Be 'claude'
        (Resolve-CliLowTrustLaunch -Chosen 'codex' -Adapters $script:A -Facts $null).Cli | Should -Be 'codex'
    }
    It 'the repo visibility lookup refuses a malformed repo name without calling gh' {
        Mock gh { throw 'gh must not run' }
        Get-CliRepoVisibility 'not a repo; rm -rf /' | Should -BeNullOrEmpty
        Should -Invoke gh -Times 0
    }
}

Describe 'dsh low-trust cannot be loosened by an override (#773)' {
    It 'rejects a user override that ranks dsh on another route' {
        $u = New-Override @(@{ name = 'dsh'; routing = @{ docs = 1; default = 1 } })
        $w = $null
        $d = Get-CliAdapters -UserPath $u -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue | Where-Object Name -eq 'dsh'
        @($d.Routing.Keys | Sort-Object) | Should -Be @('chore', 'docs')
        $d.Source | Should -Be 'preset'
        (@($w) -join "`n") | Should -Match 'lowTrust adapter may only rank'
    }
    It 'rejects a project override that makes dsh a reviewer' {
        $r = New-Override @(@{ name = 'dsh'; reviewer = $true })
        $w = $null
        $d = Get-CliAdapters -UserPath $script:None -RepoPath $r -WarningVariable w -WarningAction SilentlyContinue | Where-Object Name -eq 'dsh'
        $d.Reviewer | Should -BeFalse
        (@($w) -join "`n") | Should -Match 'cannot be a reviewer'
    }
    It 'rejects a user override that clears lowTrust (sticky)' {
        $u = New-Override @(@{ name = 'dsh'; lowTrust = $false; routing = @{ heavy = 1 } })
        $w = $null
        $d = Get-CliAdapters -UserPath $u -RepoPath $script:None -WarningVariable w -WarningAction SilentlyContinue | Where-Object Name -eq 'dsh'
        $d.LowTrust | Should -BeTrue
        (@($w) -join "`n") | Should -Match 'clears lowTrust'
    }
    It 'a project override may still re-rank dsh within docs/chore' {
        $r = New-Override @(@{ name = 'dsh'; routing = @{ docs = 10 } })
        $d = Get-CliAdapters -UserPath $script:None -RepoPath $r | Where-Object Name -eq 'dsh'
        $d.Routing['docs'] | Should -Be 10
        $d.Source | Should -Be 'repo'
    }
}

Describe 'dsh probe rules map the real outputs to the closed code set (#773, #770)' {
    # Captured from the pilot run of the probe in the container (request ids / session ids kept as
    # captured; the auth sample used a FAKE key, never a real one).
    It 'a --json run that answers OK on exit 0 is OK' {
        $out = @(
            '{"type":"session","sessionId":"session-214cef83-3f79-4e11-ad15-03fa3765a6c7","cwd":"/tmp"}'
            '{"type":"status","phase":"turn_start","turn":1}'
            '{"type":"text","text":"OK"}'
            '{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"completed"}}'
            '{"type":"final","text":"OK"}'
        ) -join "`n"
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 0 -Output $out | Should -BeExactly 'OK'
    }
    It 'the same text on a non-zero exit is not OK' {
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output '{"type":"final","text":"OK"}' | Should -BeExactly 'ERROR'
    }
    It 'a rejected key is AUTH' {
        $out = @(
            '{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"error","error":{"message":"Authentication Fails, Your api key: ****0000 is invalid (request_id: 13dfcb55-d61d-4364-90df-a3783c603d77)","code":"AUTH","status":401}}}'
            '{"type":"final","text":""}'
            'dsh: AUTH: Authentication Fails, Your api key: ****0000 is invalid (request_id: 13dfcb55-d61d-4364-90df-a3783c603d77)'
        ) -join "`n"
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output $out | Should -BeExactly 'AUTH'
    }
    It 'a missing key is AUTH' {
        $out = 'dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY through the credentials service (the web Models page writes it), or export DEEPSEEK_API_KEY in the launching environment'
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output $out | Should -BeExactly 'AUTH'
    }
    It 'the documented quota, rate-limit and context codes map to their probe codes' {
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output 'dsh: QUOTA: Insufficient Balance' | Should -BeExactly 'QUOTA'
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output '{"type":"status","phase":"turn_end","reason":{"kind":"error","error":{"code":"RATE_LIMIT","status":429}}}' | Should -BeExactly 'RATE_LIMIT'
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output 'dsh: CONTEXT_WINDOW_EXCEEDED: too long' | Should -BeExactly 'CONTEXT_WINDOW'
    }
    It 'an image that was never built is ERROR (never pulled from a registry)' {
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 125 -Output "docker: Error response from daemon: No such image: agentic-board/dsh:0.2.0-rc.2`n`nRun 'docker run --help' for more information" | Should -BeExactly 'ERROR'
        (Resolve-CliProbeOutcome -Cli 'dsh' -ExitCode 125 -Output 'No such image: agentic-board/dsh:0.2.0-rc.2').Reason | Should -Match 'docker build'
    }
    It 'Docker not running and an entrypoint refusal are ERROR' {
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 1 -Output 'error during connect: Head "http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/_ping": open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.' | Should -BeExactly 'ERROR'
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 78 -Output 'abios-dsh: refusing to run: the workspace has a .env file, which dsh would load into its environment.' | Should -BeExactly 'ERROR'
    }
    It 'an answer that is not OK, on exit 0, fails closed to ERROR' {
        ConvertTo-CliProbeCode -Cli 'dsh' -ExitCode 0 -Output '{"type":"final","text":"I cannot help with that"}' | Should -BeExactly 'ERROR'
    }
}

Describe 'dsh install pin and image recipe (#773, #765)' {
    BeforeAll {
        $script:Dockerfile = Get-Content -Raw -LiteralPath (Join-Path $script:Box 'Dockerfile')
        $script:Pkg  = Get-Content -Raw -LiteralPath (Join-Path $script:Box 'package.json') | ConvertFrom-Json -AsHashtable
        $script:Lock = Get-Content -Raw -LiteralPath (Join-Path $script:Box 'package-lock.json') | ConvertFrom-Json -AsHashtable
        $script:Entry = Get-Content -Raw -LiteralPath (Join-Path $script:Box 'entrypoint.sh')
        $script:Patch = Get-Content -Raw -LiteralPath (Join-Path $script:Box 'no-upload.patch.yml')
    }
    It 'pins every base image by tag AND sha256 digest' {
        $froms = @([regex]::Matches($script:Dockerfile, '(?m)^FROM\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
        $froms.Count | Should -BeGreaterThan 0
        foreach ($f in $froms) { $f | Should -Match '^node:\d+\.\d+\.\d+-[a-z-]+@sha256:[0-9a-f]{64}$' }
    }
    It 'installs only from the lockfile, and fetches nothing unpinned' {
        $script:Dockerfile | Should -Match '(?m)^RUN npm ci '
        $script:Dockerfile | Should -Not -Match '(?m)^RUN .*npm (i|install)\b'
        $steps = ($script:Dockerfile -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $steps | Should -Not -Match '@latest|curl|wget|apt-get|apk add|\| *sh\b'
    }
    It 'names the exact scoped package and version, with no range' {
        @($script:Pkg.dependencies.Keys) | Should -Be @('@deepseek-ai/dsh')
        $script:Pkg.dependencies['@deepseek-ai/dsh'] | Should -Match '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
        $script:Pkg.dependencies['@deepseek-ai/dsh'] | Should -BeExactly '0.2.0-rc.2'
    }
    It 'the lockfile agrees with package.json and pins every package by version and integrity' {
        $script:Lock.packages[''].dependencies['@deepseek-ai/dsh'] | Should -BeExactly '0.2.0-rc.2'
        $script:Lock.packages['node_modules/@deepseek-ai/dsh'].version | Should -BeExactly '0.2.0-rc.2'
        $loose = @($script:Lock.packages.Keys | Where-Object { $_ -and $_ -like 'node_modules/*' -and -not $script:Lock.packages[$_].link -and
            (-not $script:Lock.packages[$_].version -or $script:Lock.packages[$_].integrity -notmatch '^sha\d+-') })
        $loose | Should -BeNullOrEmpty
    }
    It 'the image tag in the registry is the pinned version' {
        ($script:Dsh.ProbeArgs -join ' ') | Should -Match ([regex]::Escape("agentic-board/dsh:$($script:Pkg.dependencies['@deepseek-ai/dsh'])"))
        $script:Dockerfile | Should -Match ([regex]::Escape("docker build -t agentic-board/dsh:$($script:Pkg.dependencies['@deepseek-ai/dsh'])"))
    }
    It 'disables the session-log upload, the telemetry and the package inventory rows' {
        foreach ($row in 'session-log-deepseek', 'session-telemetry-otel', 'plugin-package-inventory-deepseek') {
            $script:Patch | Should -Match ("(?m)^- id: {0}\r?\n  disabled: true" -f [regex]::Escape($row))
        }
    }
    It 'sets the telemetry opt-out and pins the endpoint and permission mode as image ENV' {
        $script:Dockerfile | Should -Match 'DSH_TELEMETRY_DISABLED=1'
        $script:Dockerfile | Should -Match 'DSH_TELEMETRY_MODE=DISABLED'
        $script:Dockerfile | Should -Match 'DEEPSEEK_BASE_URL=https://api\.deepseek\.com/anthropic'
        $script:Dockerfile | Should -Match 'DSH_PERMISSION_MODE=workspace-write'
        $script:Dockerfile | Should -Match 'DSH_HOME=/tmp/'
    }
    It 'fails the build if the composed config still mounts an uploader, and runs as non-root' {
        $script:Dockerfile | Should -Match '--dump-config > /tmp/composed\.yml'
        $script:Dockerfile | Should -Match 'check-upload-off\.js < /tmp/composed\.yml'
        $script:Dockerfile | Should -Match '(?m)^USER node\s*$'
    }
    It 'the entrypoint always applies the patch and refuses a workspace .env, weakened switches and stray credentials' {
        $script:Entry | Should -Match 'exec dsh --patch /opt/abios-dsh/no-upload\.patch\.yml "\$@"'
        $script:Entry | Should -Match '\[ -e \./\.env \] && refuse'
        $script:Entry | Should -Match 'DSH_TELEMETRY_DISABLED'
        $script:Entry | Should -Match 'DSH_PERMISSION_MODE:-}" = "workspace-write"'
        $script:Entry | Should -Match '\*TOKEN\*\|\*KEY\*\|\*SECRET\*\|\*PASSWORD\*'
        $script:Entry | Should -Not -Match "`r" -Because 'sh reads a CR as part of the command (.gitattributes eol=lf)'
    }
}

Describe 'dsh at LAUNCH: route docs/chore AND repo PUBLIC, whatever picked it (#773)' {
    BeforeAll {
        function script:Facts([string[]]$Labels = @(), [string]$Type = $null, [string]$Size = $null, [string]$Vis = 'PUBLIC') {
            [pscustomobject]@{ labels = $Labels; type = $Type; size = $Size; visibility = $Vis; title = 'T'; body = 'B' }
        }
    }
    It 'a public Docs issue launches dsh, with no warning' {
        $r = Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts (Facts -Labels 'docs') -IssueNum 7
        $r.Cli | Should -Be 'dsh'
        $r.Warning | Should -BeNullOrEmpty
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts (Facts -Type 'Chore')).Cli | Should -Be 'dsh'
    }
    It 'falls back to claude, with one warning line, for a <name> issue even on a public repo' -ForEach @(
        @{ name = 'heavy (security label)'; labels = @('security'); type = $null;      size = $null; route = 'heavy' }
        @{ name = 'heavy (docs, but size L)'; labels = @('docs');   type = $null;      size = 'L';   route = 'heavy' }
        @{ name = 'refactor';                labels = @('refactor'); type = $null;     size = $null; route = 'refactor' }
        @{ name = 'default (a Feature)';     labels = @();          type = 'Feature';  size = 'M';   route = 'default' }
    ) {
        $r = Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts (Facts -Labels $labels -Type $type -Size $size) -IssueNum 7
        $r.Cli | Should -Be 'claude'
        $r.Warning | Should -Match "^#7: not launching dsh - the issue takes the '$route' route"
        $r.Warning | Should -Match 'Launching claude instead'
        @($r.Warning -split "`n").Count | Should -Be 1
    }
    It 'falls back for a private repo or when the facts are unknown' {
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts (Facts -Labels 'docs' -Vis 'PRIVATE')).Warning | Should -Match 'visibility is PRIVATE'
        (Resolve-CliLowTrustLaunch -Chosen 'dsh' -Adapters $script:A -Facts $null).Warning | Should -Match 'unknown'
    }
    It 'the picker choosing dsh for a heavy issue still launches claude (Start-WorktreeSession gate)' {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:ScriptDir 'Board-Work.ps1')
        $env:ABIOS_BOARDWORK_DOTSOURCE = ''
        Mock Get-CliRepoVisibility { throw 'no gh in tests' }
        # The picker's own core happily maps the issue to an available dsh ...
        $map = Resolve-IssueCliMap -Issues @(7) -Choices @{ 7 = 'dsh' } -Availability @{ dsh = 'OK'; claude = 'OK' }
        $map[7] | Should -Be 'dsh'
        $work = Join-Path $TestDrive 'wt-7'; New-Item -ItemType Directory -Force $work | Out-Null
        Push-Location $TestDrive
        try {
            # ... and the launch refuses it: heavy route -> claude.
            $heavy = Start-WorktreeSession -IssueNum 7 -Repo 'o/r' -Branch 'issue-7-x' -WorkPath $work -Cli $map[7] -IssueFacts (Facts -Labels 'architecture') -Preview 6>$null
            $heavy.cli | Should -Be 'claude'
            $heavy.launchScript | Should -Not -Match 'agentic-board/dsh'
            # A relaunch carries no facts: refused as well.
            (Start-WorktreeSession -IssueNum 7 -Repo 'o/r' -Branch 'issue-7-x' -WorkPath $work -Cli 'dsh' -Preview 6>$null).cli | Should -Be 'claude'
            # Public + docs: dsh, in its container.
            $docs = Start-WorktreeSession -IssueNum 7 -Repo 'o/r' -Branch 'issue-7-x' -WorkPath $work -Cli 'dsh' -IssueFacts (Facts -Labels 'docs') -Preview 6>$null
            $docs.cli | Should -Be 'dsh'
            $docs.launchScript | Should -Match 'docker run --rm .* agentic-board/dsh:0\.2\.0-rc\.2 '
        } finally { Pop-Location }
    }
}

Describe 'dsh briefing and the human next step (#773)' {
    BeforeAll {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:ScriptDir 'Board-Work.ps1')
        $env:ABIOS_BOARDWORK_DOTSOURCE = ''
        $script:Brief = Get-ContainerEditBriefing -IssueNum 42 -Repo 'CSalcedoDataBI/demo' -Title 'Add a Contributing note' -Body 'README needs a short Contributing section.'
    }
    It 'carries the issue itself, since dsh cannot fetch it' {
        $script:Brief | Should -Match '^Issue #42 in CSalcedoDataBI/demo - Add a Contributing note'
        $script:Brief | Should -Match 'README needs a short Contributing section\.'
    }
    It 'gives one job - edit the files in /work - and forbids git, PRs and the network' {
        $script:Brief | Should -Match 'edit the files in the current directory \(/work'
        $script:Brief | Should -Match 'Do NOT run git'
        $script:Brief | Should -Match 'do NOT try to open a pull request'
        $script:Brief | Should -Match 'do NOT use the network'
    }
    It 'never tells it to use gh, pwsh, the plugin scripts, commit or open a PR' {
        $script:Brief | Should -Not -Match '\bgh\b|pwsh|Fleet-|New-BoardPR|Board-ReviewGate|git commit|gh pr|gh issue'
        $script:Brief | Should -Not -Match '(?im)^(?!.*\bnot\b).*\b(commit|push|pull request)\b' -Because 'commit / push / PR only ever appear in a prohibition'
    }
    It 'caps a huge issue body and names an empty one' {
        $big = Get-ContainerEditBriefing -IssueNum 1 -Repo 'o/r' -Title 't' -Body ('x' * 20000)
        $big.Length | Should -BeLessThan 9500
        $big | Should -Match 'issue text truncated'
        Get-ContainerEditBriefing -IssueNum 1 -Repo 'o/r' -Title 't' -Body '' | Should -Match 'has no description'
    }
    It 'Start-WorktreeSession writes the dsh briefing, not the fleet one, for a dsh launch' {
        $work = Join-Path $TestDrive 'wt-42'; New-Item -ItemType Directory -Force $work | Out-Null
        Mock Get-AbiosDir { $null }
        Mock Write-RunLedgerCheckpoint { }
        . (Join-Path $script:ScriptDir 'Brake-Guard.ps1')
        Mock Set-BrakeArmedState { 'unchanged' }
        Mock Start-Process { $null }
        $facts = [pscustomobject]@{ labels = @('docs'); type = $null; size = $null; visibility = 'PUBLIC'; title = 'Add a Contributing note'; body = 'Please add it.' }
        $p = Start-WorktreeSession -IssueNum 42 -Repo 'o/r' -Branch 'issue-42-x' -WorkPath $work -Cli 'dsh' -IssueFacts $facts 6>$null
        $p.cli | Should -Be 'dsh'
        $written = Get-Content -Raw -LiteralPath (Join-Path $work 'briefing-42.txt')
        $written | Should -Match 'Please add it\.'
        $written | Should -Not -Match 'gh issue view|Fleet-Findings|New-BoardPR'
        Should -Invoke Start-Process -Times 1
    }
    It 'prints the human next step when the container exits, and never commits or pushes' {
        $l = Build-WorktreeLaunch -issueNum 42 -workPath "D:\wt\O'Brien\issue-42" -briefingFile 'D:\b\briefing-42.txt' -Cli 'dsh'
        $last = ($l.launchScript -split "`r?`n")[-1]
        $last | Should -BeExactly ('Write-Host (''dsh finished (exit {0}). It does not commit, push or open a PR. Next step for you: review `git diff` in {1}, then commit and open the PR.'' -f $LASTEXITCODE, ''D:\wt\O''''Brien\issue-42'') -ForegroundColor Yellow')
        $l.launchScript | Should -Not -Match '(?m)^\s*git |gh pr create|New-BoardPR'
        $c = Build-WorktreeLaunch -issueNum 42 -workPath 'D:\wt\issue-42' -briefingFile 'D:\b\briefing-42.txt' -Cli 'claude'
        $c.launchScript | Should -Not -Match 'Next step for you'
    }
}