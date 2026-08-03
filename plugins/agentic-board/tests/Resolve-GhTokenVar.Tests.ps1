#Requires -Modules Pester
<#  Tests for Resolve-GhTokenVar.ps1 — which GitHub identity applies (#550, part of #541).

    The decision that matters is the FAILURE one. An armed run with no agent token must STOP, not
    fall back to the owner's PAT: that PAT is admin, the `main` ruleset exempts admins, and GitHub
    would let it push. A silent fallback hands the run exactly the capability the brake exists to
    remove, while every message still says "brake armed" — the same shape of defect already found
    in the brake (#440), the review gate (#510) and the evidence blocks (#479).  #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Resolve-GhTokenVar.ps1' | Resolve-Path
    $env:ABIOS_TOKENVAR_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_TOKENVAR_DOTSOURCE = $null
}

Describe 'Resolve-GhTokenVar — an ordinary session is untouched' {
    It 'uses the owner identity when no brake is armed' {
        $r = Resolve-GhTokenVar -IsArmed $false -AgentTokenPresent $true
        $r.var  | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.fail | Should -BeFalse
    }
    It 'does so even when the agent token does not exist' {
        # A machine account is not a prerequisite for ordinary work.
        (Resolve-GhTokenVar -IsArmed $false -AgentTokenPresent $false).var |
            Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'honours the business owner mapping' {
        (Resolve-GhTokenVar -IsArmed $false -AgentTokenPresent $true -Owner 'PAL-Devs').var |
            Should -Be 'GITHUB_TOKEN_BUSINESS'
    }
    It 'falls back to the personal variable for an unmapped owner' {
        (Resolve-GhTokenVar -IsArmed $false -Owner 'someone-else').var |
            Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
}

Describe 'Resolve-GhTokenVar — a braked run gets the agent identity' {
    It 'returns the agent variable' {
        $r = Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $true
        $r.var  | Should -Be 'GITHUB_TOKEN_AGENT'
        $r.fail | Should -BeFalse
    }
    It 'says WHY, in terms of what GitHub does' {
        (Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $true).reason |
            Should -Match 'rechaza el push a main'
    }
    It 'never hands a braked run the BUSINESS identity' {
        # The widest of the three: 20 repos, admin on 17, client work included. Reaching for it to
        # "sandbox" an agent is the opposite of sandboxing.
        foreach ($o in @('CSalcedoDataBI','PAL-Devs','someone-else')) {
            (Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $true -Owner $o).var |
                Should -Not -Be 'GITHUB_TOKEN_BUSINESS'
        }
    }
    It 'ignores the owner entirely once armed — the agent identity is not per-account' {
        (Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $true -Owner 'PAL-Devs').var |
            Should -Be 'GITHUB_TOKEN_AGENT'
    }
}

Describe 'Resolve-GhTokenVar — a missing agent token FAILS, it does not fall back' {
    It 'reports failure rather than a variable' {
        $r = Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $false
        $r.fail | Should -BeTrue
        $r.var  | Should -BeNullOrEmpty
    }
    It 'never names the owner token on that path' {
        # THE regression guard. If this ever returns GITHUB_TOKEN_PERSONAL, the braked run silently
        # regains an identity that can push to main.
        $r = Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $false
        $r.var | Should -Not -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'explains the refusal in terms of consequence, not of policy' {
        (Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $false).reason |
            Should -Match 'admin'
    }
    It 'fails the same way whatever the owner' {
        foreach ($o in @('CSalcedoDataBI','PAL-Devs','someone-else')) {
            (Resolve-GhTokenVar -IsArmed $true -AgentTokenPresent $false -Owner $o).fail |
                Should -BeTrue
        }
    }
}

Describe 'Resolve-GhTokenVar — defaults refuse to be permissive' {
    It 'treats an unspecified armed state as NOT armed, and an unspecified token as absent' {
        # Absent parameters must not invent an armed run; but if a caller DOES say armed and says
        # nothing about the token, that is a failure and not a fallback.
        (Resolve-GhTokenVar).var | Should -Be 'GITHUB_TOKEN_PERSONAL'
        (Resolve-GhTokenVar -IsArmed $true).fail | Should -BeTrue
    }
}
