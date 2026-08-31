#Requires -Modules Pester
<#  Pester tests for Welcome-SessionStartHook.ps1 - the auto-registered first-run banner.

    The hook reads stdin and writes a marker file, so it exposes a dot-source guard: with
    $env:ABIOS_WELCOME_HOOK_DOTSOURCE set it returns after defining the pure helpers
    (Get-WelcomeBanner, Get-WelcomeContext, Test-ShouldWelcome) without touching stdin or
    the filesystem. These tests exercise only those helpers. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Welcome-SessionStartHook.ps1' | Resolve-Path
    $env:ABIOS_WELCOME_HOOK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_WELCOME_HOOK_DOTSOURCE = ''
}

Describe 'Test-ShouldWelcome' {
    It 'welcomes on a fresh startup with no marker' {
        Test-ShouldWelcome 'startup' $false | Should -BeTrue
    }
    It 'stays silent when the marker already exists' {
        Test-ShouldWelcome 'startup' $true | Should -BeFalse
    }
    It 'stays silent on resume / clear / compact (not a first install)' {
        Test-ShouldWelcome 'resume'  $false | Should -BeFalse
        Test-ShouldWelcome 'clear'   $false | Should -BeFalse
        Test-ShouldWelcome 'compact' $false | Should -BeFalse
    }
    It 'stays silent on an empty/unknown source' {
        Test-ShouldWelcome '' $false | Should -BeFalse
    }
}

Describe 'Get-WelcomeBanner' {
    It 'contains the AGENTIC BOARD block-glyph banner' {
        Get-WelcomeBanner | Should -Match '█▄▄ █▀█'   # the "BOARD" block row
    }
    It 'names the three entry-point commands' {
        $b = Get-WelcomeBanner
        $b | Should -Match '/board'
        $b | Should -Match '/scan'
        $b | Should -Match '/skills'
    }
}

Describe 'Get-WelcomeContext' {
    It 'embeds the banner' {
        Get-WelcomeContext | Should -Match 'Run coding agents off your real GitHub Projects board'
    }
    It 'instructs the assistant to print it verbatim as the first output' {
        $c = Get-WelcomeContext
        $c | Should -Match 'VERBATIM'
        $c | Should -Match 'first'
    }
}
