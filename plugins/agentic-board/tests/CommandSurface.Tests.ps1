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
