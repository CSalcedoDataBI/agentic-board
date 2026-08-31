#Requires -Modules Pester
<#  Encoding ratchet: every PowerShell file we ship must declare its own interpreter.

    Field report (2026-08-31): a session on a Spanish Windows could not run Board-Fill.ps1 at all —
    it died at parse time with "Unexpected token '}' in expression or statement" on lines 370 and
    508. The script was fine. The reader was not.

    Every .ps1 in this repo was UTF-8 WITHOUT a BOM, and the files are full of box-drawing rules
    (U+2500) and em dashes (U+2014). Both encode to a byte sequence containing 0x94. Windows
    PowerShell 5.1 reads a BOM-less file as the machine's ANSI codepage, and on cp1252 the byte
    0x94 decodes to RIGHT DOUBLE QUOTATION MARK — which the PowerShell tokenizer accepts as a
    STRING DELIMITER. An odd number of them opens a string that swallows real code, and the next
    closing brace lands inside a string literal. Hence the phantom '}'.

    28 of the 185 shipped files failed to parse outright this way; the rest silently printed
    mojibake. Scripts.Parse.Tests.ps1 already parses every script and stayed green throughout,
    because it calls ParseFile from pwsh 7 — which assumes UTF-8 for a BOM-less file. Same parse,
    different host, and the host is the whole bug. Only Windows PowerShell 5.1 sees it, and the
    repo's own docs told contributors to launch scripts with `powershell -File` (now `pwsh -File`).

    A BOM makes the file self-describing: 5.1 and 7.x both read it as UTF-8, on any codepage. That
    is the fix; this is the ratchet that keeps it. Pure filesystem assertion, no network. #>

BeforeDiscovery {
    # Discovery-time on purpose: `-Skip:` on an It is evaluated while Pester DISCOVERS the file,
    # long before any BeforeAll runs. Resolving this in BeforeAll made the check skip on every
    # host, forever — a green suite that proved nothing.
    $script:WinPs = @(
        Join-Path $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        (Get-Command 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1).Source
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

Describe 'PowerShell source encoding' {

    BeforeAll {
        #   tests/ -> agentic-board/ -> plugins/ -> repo root
        $script:RepoRoot = (Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path).Path
        # git-tracked only: the point is what we SHIP. Untracked/ignored session artifacts (the
        # .agentic-board/launch-*.ps1 scratch files) are none of this ratchet's business.
        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1') } finally { Pop-Location }
        $script:PsFiles = @(
            $tracked | ForEach-Object {
                Get-Item -LiteralPath (Join-Path $script:RepoRoot $_) -ErrorAction SilentlyContinue
            }
        )
    }

    It 'finds PowerShell files to check (fails closed on a broken glob)' {
        # Without this, a discovery bug would make every assertion below vacuously green.
        $script:PsFiles.Count | Should -BeGreaterThan 50
    }

    It 'declares an interpreter on every PowerShell file: a BOM, or a shebang, never both' {
        # BOM xor shebang. Both mechanisms answer "which interpreter reads this file", and they
        # compete for the same first bytes: a BOM in front of `#!` hides the shebang from the Unix
        # loader, so a file carries one or the other. Everything we ship takes the BOM, because the
        # failure being guarded is a Windows PowerShell 5.1 one; the two VHS demo assets under
        # .github/assets declare `#!/usr/bin/env pwsh` and keep that instead.
        $offenders = foreach ($f in $script:PsFiles) {
            $head = [byte[]]::new(5)
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try { $read = $fs.Read($head, 0, 5) } finally { $fs.Dispose() }
            $rel = $f.FullName.Replace($script:RepoRoot, '') -replace '^[\\/]+', ''

            $hasBom      = ($read -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
            $bomHidesIt  = ($hasBom -and $read -ge 5 -and $head[3] -eq 0x23 -and $head[4] -eq 0x21)
            $shebangOnly = ($read -ge 2 -and $head[0] -eq 0x23 -and $head[1] -eq 0x21)

            if ($bomHidesIt) { "$rel (BOM sits in front of the shebang and hides it)" }
            elseif (-not $hasBom -and -not $shebangOnly) { "$rel (no BOM)" }
        }

        $offenders = @($offenders)
        if ($offenders.Count) {
            throw ("$($offenders.Count) PowerShell file(s) declare no interpreter; Windows PowerShell 5.1 " +
                   "reads a BOM-less file as ANSI and can mis-tokenize it:`n  " + ($offenders -join "`n  "))
        }
    }

    # Windows PowerShell 5.1 — the host that actually mis-read a BOM-less file. Absent on
    # Linux/macOS dev boxes; present on the windows-latest runner that runs this suite in CI.
    # -ForEach because the It body runs in a scope where the discovery variable is not visible.
    It 'is readable by Windows PowerShell 5.1, except the files declared otherwise' -Skip:(-not $script:WinPs) -ForEach @{
        WinPs = $script:WinPs
    } {
        # The end-to-end proof, run in the host that broke in the field: 5.1 reads each file off
        # disk with its own encoding rules and we assert the tokenizer stays clean. -EncodedCommand
        # (UTF-16LE base64) so no quoting or codepage of ours can distort the child command.
        #
        # The list below is NOT a way to wave failures through. Every entry carries its reason, and
        # declaring them by name is what keeps this assertion sharp: anything else 5.1 cannot read
        # is new, and the first suspect is encoding. Shrink this list, never grow it without a
        # reason in the PR.
        $notForWinPs = @(
            # `??` null-coalescing and `? :` ternary are PowerShell 7 operators. 5.1 rejects them
            # BOM or no BOM: a deliberate version dependency, not an encoding fault.
            'plugins/agentic-board/scripts/Expert-RoleSynthesis.ps1'
            'plugins/agentic-board/scripts/Expert-Roles.ps1'
            'plugins/agentic-board/scripts/KnowledgeRegistryIo.ps1'
            'plugins/agentic-board/scripts/Resolve-SkillOwner.ps1'

            # Different reason, same conclusion: these two keep a `#!/usr/bin/env pwsh` shebang
            # instead of a BOM (see the rule above), so 5.1 still reads them as ANSI. They are VHS
            # demo assets that render the README GIFs, driven by pwsh from a .tape file and never
            # by 5.1, so the shebang is the more useful of the two declarations.
            '.github/assets/board-demo.ps1'
            '.github/assets/board-loop.ps1'
        )

        $child = @'
Set-Location -LiteralPath "__ROOT__"
& git ls-files -- *.ps1 *.psm1 *.psd1 | ForEach-Object {
        $full = Join-Path "__ROOT__" $_
        $errors = $null; $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { "{0}|{1}|{2}" -f $_, $errors[0].Extent.StartLineNumber, $errors[0].Message }
    }
'@ -replace '__ROOT__', $script:RepoRoot.Replace('"', '""')

        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
        $reported = @(& $WinPs -NoProfile -NonInteractive -EncodedCommand $encoded)
        $names    = @($reported | ForEach-Object { ($_ -split '\|', 3)[0] })

        $unexpected = @($reported | Where-Object { ($_ -split '\|', 3)[0] -notin $notForWinPs })
        if ($unexpected.Count) {
            $shown = $unexpected | ForEach-Object { $p, $l, $m = $_ -split '\|', 3; "$p (line ${l}: $m)" }
            throw ("Windows PowerShell 5.1 cannot read $($unexpected.Count) shipped file(s) that are " +
                   "not declared otherwise — suspect encoding first:`n  " + ($shown -join "`n  "))
        }

        # Fail closed the other way too: if a declared file gets fixed or deleted, this test must
        # say so rather than keep carrying a stale exemption.
        $stale = @($notForWinPs | Where-Object { $_ -notin $names })
        if ($stale.Count) {
            throw ("These files no longer need their Windows PowerShell 5.1 exemption; remove them " +
                   "from the list in this test:`n  " + ($stale -join "`n  "))
        }
    }
}
