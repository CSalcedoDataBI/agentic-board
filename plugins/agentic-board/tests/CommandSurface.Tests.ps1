#Requires -Modules Pester
<#  Pester tests for the Command Surface Contract (CONTRIBUTING.md § "Command surface").

    Enforces the invariant that let a menu tell users to type `/abios-feedback` (a command that
    does not exist): the typed surface and the internal skills must never be confused.
      - Every typed command (commands/*.md) has a non-empty description.
      - No command file presents an internal (user-invocable:false) skill as a typeable `/x`.
      - Every menu-style entry line that begins with `/x` resolves to a real command.

    Pester 5 scoping: `-ForEach` cases are built at SCRIPT (discovery) scope; everything the It
    BODIES read (RealCommands, CommandFiles) is (re)built in BeforeAll (run scope).
#>

# --- discovery scope: -ForEach cases ------------------------------------------
$CommandCases = @(
    Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'commands') -Filter '*.md' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
)
$ScriptCases = @(
    Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'scripts') -Filter '*.ps1' |
        Where-Object { $_.Name -ne 'Find-InternalVocabularyLeak.ps1' } |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
)
$SkillCases = @(
    Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'skills') -Directory | ForEach-Object {
        $md = Join-Path $_.FullName 'SKILL.md'
        if ((Test-Path $md) -and ((Get-Content -LiteralPath $md -Raw) -match '(?m)^\s*user-invocable:\s*false\s*$')) {
            @{ Skill = $_.Name }
        }
    }
)

BeforeAll {
    $script:CommandsDir  = Join-Path $PSScriptRoot '..' 'commands'
    $script:CommandFiles = @(Get-ChildItem -Path $script:CommandsDir -Filter '*.md')
    $script:RealCommands = @($script:CommandFiles.BaseName)
    $env:ABIOS_VOCABLEAK_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Find-InternalVocabularyLeak.ps1' | Resolve-Path)
    $env:ABIOS_VOCABLEAK_DOTSOURCE = ''
    $script:InternalSkills = @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'skills') -Directory | ForEach-Object {
            $md = Join-Path $_.FullName 'SKILL.md'
            if ((Test-Path $md) -and ((Get-Content -LiteralPath $md -Raw) -match '(?m)^\s*user-invocable:\s*false\s*$')) { $_.Name }
        }
    )
}

Describe 'Command surface — commands' {
    It 'discovers at least one real command' {
        $script:RealCommands.Count | Should -BeGreaterThan 0
    }

    It '<Name> has a non-empty description in its frontmatter' -ForEach $CommandCases {
        $desc = ''
        $lines = Get-Content -LiteralPath $Path
        if ($lines[0] -eq '---') {
            for ($i = 1; $i -lt $lines.Count -and $lines[$i] -ne '---'; $i++) {
                if ($lines[$i] -match '^\s*description:\s*(.*)$') { $desc = $matches[1]; break }
            }
        }
        [string]::IsNullOrWhiteSpace($desc) | Should -BeFalse -Because "$Name feeds the palette and the generated README catalog"
    }
}

Describe 'Command surface — internal skills are never dressed as /x' {
    It 'discovers internal (user-invocable:false) skills including abios-feedback' {
        $script:InternalSkills.Count | Should -BeGreaterThan 0
        $script:InternalSkills | Should -Contain 'abios-feedback'
    }

    It 'no command file presents internal skill /<Skill> as typeable' -ForEach $SkillCases {
        $needle = "/$Skill"
        foreach ($cmd in $script:CommandFiles) {
            (Get-Content -LiteralPath $cmd.FullName -Raw) | Should -Not -BeLike "*$needle*" -Because "$($cmd.Name) must not offer $needle — it is an internal skill, invoked by the model, not typed"
        }
    }
}

Describe 'Command surface — menu entries resolve to real commands' {
    It '<Name>: every line starting with /<token> is a real command' -ForEach $CommandCases {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*/([a-z][a-z0-9-]+)') {
                $script:RealCommands | Should -Contain $matches[1] -Because "a menu entry '/$($matches[1])' in $Name must map to commands/$($matches[1]).md"
            }
        }
    }
}

Describe 'Command surface — /tools referenced-tools catalog (#384)' {
    It 'exposes /tools as a real typed command' {
        $script:RealCommands | Should -Contain 'tools' -Because 'the unified referenced-tools catalog is invoked as /agentic-board:tools (commands/tools.md)'
    }

    It 'ships tools-catalog as an internal (user-invocable:false) skill' {
        $script:InternalSkills | Should -Contain 'tools-catalog' -Because 'the catalog logic is an internal skill the /tools command routes to — never typed directly'
    }

    It 'lists /tools in the /board discoverability menu' {
        $board = Get-Content -LiteralPath (Join-Path $script:CommandsDir 'board.md') -Raw
        $board | Should -Match '(?m)^\s*/tools\b' -Because 'the whole tool must be discoverable from the /board entry point, alongside /scan /skills /knowledge'
    }
}

Describe 'Command surface — every command ends with the closing summary (#493)' {
    <#  The epic's Definition of Done is "asserted, not eyeballed": a command that forgets the
        four-block contract must FAIL here, not be noticed later by a user reading a run that
        stops mid-thought. The expected headings are read from the renderer itself, so this test
        can never drift into being a second, stale copy of the contract. #>
    BeforeAll {
        $summaryScript = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Summary.ps1' | Resolve-Path
        $prev = $env:ABIOS_BOARDSUMMARY_DOTSOURCE
        $env:ABIOS_BOARDSUMMARY_DOTSOURCE = '1'
        try { . $summaryScript } finally { $env:ABIOS_BOARDSUMMARY_DOTSOURCE = $prev }
        $script:Blocks = @(Get-ClosingSummaryBlocks)
    }

    It 'the renderer exposes the four contract blocks as data' {
        $script:Blocks.Count | Should -Be 4 -Because 'the contract is found / did / pending / need-from-you'
        @($script:Blocks.Key) | Should -Be @('Found', 'Did', 'Pending', 'NeedFromYou') -Because 'order is meaning: the reader scans a fixed shape'
    }

    It '<Name> carries the generated closing-summary region' -ForEach $CommandCases {
        $raw = Get-Content -LiteralPath $Path -Raw
        $raw | Should -Match '<!--\s*BEGIN:closing-summary\b' -Because "$Name is a user-facing command surface; without the region it ships with no closing contract"
        $raw | Should -Match '<!--\s*END:closing-summary\s*-->' -Because "$Name needs a closed region for the generator to fill"
    }

    It '<Name> states every one of the four headings' -ForEach $CommandCases {
        $raw = Get-Content -LiteralPath $Path -Raw
        foreach ($b in $script:Blocks) {
            $raw | Should -BeLike "*$($b.Label)*" -Because "$Name must ask for the '$($b.Label)' block by name - a paraphrase is what drifts"
        }
    }

    It '<Name> states the when-empty sentence for every block' -ForEach $CommandCases {
        # An empty block that renders as silence is the failure mode #492 fixed in the renderer;
        # the prompt half has to carry the same instruction or the agent just omits the block.
        $raw = Get-Content -LiteralPath $Path -Raw
        foreach ($b in $script:Blocks) {
            $raw | Should -BeLike "*$($b.Empty)*" -Because "$Name must tell the agent what to write when '$($b.Label)' is empty"
        }
    }
}

Describe 'Command surface — /docs routing contract (#417)' {
    It 'commands/docs.md does not reference Docs-Command-* pages (dropped in #418)' {
        $docsFile = Join-Path $script:CommandsDir 'docs.md'
        Get-Content -LiteralPath $docsFile -Raw |
            Should -Not -Match 'Docs-Command-' `
            -Because 'commands/*.md are agent prompts not documentation; Docs-Command-* pages were dropped in #418 — the /docs prompt must not promise them'
    }

    It 'commands/docs.md documents both /docs wiki (generates) and /docs deepwiki (routes)' {
        $docsFile = Join-Path $script:CommandsDir 'docs.md'
        $raw = Get-Content -LiteralPath $docsFile -Raw
        $raw | Should -Match '(?i)/docs wiki'     -Because '/docs wiki is the generation subcommand'
        $raw | Should -Match '(?i)/docs deepwiki' -Because '/docs deepwiki is the routing subcommand'
    }

    It 'commands/docs.md declares the public-repos-only limit for deepwiki' {
        $docsFile = Join-Path $script:CommandsDir 'docs.md'
        Get-Content -LiteralPath $docsFile -Raw |
            Should -Match '(?i)public.repos.only' `
            -Because 'the docs prompt must warn about the DeepWiki public-repos-only limit at the point of use'
    }
}

Describe 'Command surface — no internal vocabulary leaks into Write-Host output (#494)' {
    <#  Reported first-hand by the product owner, a BI professional and not a programmer:
        "me choca ver como esto Expert-Auto.ps1; PS1 no se para que". A script's own console
        output is the one user-facing surface a Pester test CAN read exactly as printed — every
        `Write-Host` argument, AST-extracted so a `-ForegroundColor` value is never mistaken for
        message text (Get-WriteHostArgumentText, scripts/Find-InternalVocabularyLeak.ps1). #>
    It '<Name> prints no script filename, bare extension, or version-pinned cache path' -ForEach $ScriptCases {
        $args = @(Get-WriteHostArgumentText -Path $Path)
        $violations = foreach ($a in $args) {
            foreach ($hit in (Find-InternalVocabularyLeak -Text $a.Text)) {
                "line $($a.Line): [$($hit.Kind)] $($hit.Match)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because "$Name must speak to a BI professional, not name its own implementation (#491/#494): $($violations -join '; ')"
    }
}
