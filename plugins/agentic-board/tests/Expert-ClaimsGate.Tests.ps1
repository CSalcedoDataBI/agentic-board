#Requires -Modules Pester
<#  Tests for Expert-ClaimsGate.ps1 — the claims verification gate for deliverables (#479).

    Five tests from the issue:
    1. A deliverable asserting a package name that does not resolve is flagged
    2. A deliverable whose claims all resolve passes without added friction
    3. A run making no external claims is unaffected (not-applicable)
    4. The evidence block distinguishes verified / unverified / not-applicable
    5. Regression fixture from the five fabrications in the incident: each one is caught

    Pure core behind ABIOS_EXPERTCLAIMSGATE_DOTSOURCE. No network calls needed.
    Design: each guard is verified by its exact success and failure conditions. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-ClaimsGate.ps1' | Resolve-Path
    $env:ABIOS_EXPERTCLAIMSGATE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTCLAIMSGATE_DOTSOURCE = ''
}

Describe 'Test-ClaimsGate — verified claim that does not resolve is flagged (#479 test 1)' {
    It 'flags an npm package that 404s (status=verified, correct=false)' {
        $claims = @(@{ claim = '@ahonn/mcp-server-gsc'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view @ahonn/mcp-server-gsc'; correct = $false })
        $r = Test-ClaimsGate -Claims $claims
        $r.pass | Should -BeFalse
        $r.flagged | Should -Contain '@ahonn/mcp-server-gsc'
    }

    It 'flags a CLI flag verified as non-existent in the tool README (status=verified, correct=false)' {
        $claims = @(@{ claim = '--auth'; kind = 'cli-flag'; status = 'verified'; howChecked = 'read README'; correct = $false })
        $r = Test-ClaimsGate -Claims $claims
        $r.pass | Should -BeFalse
        $r.flagged | Should -Contain '--auth'
    }

    It 'gateStatus is claims-failed when a verified claim is wrong' {
        $claims = @(@{ claim = 'bad-pkg'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $false })
        (Test-ClaimsGate -Claims $claims).gateStatus | Should -Be 'claims-failed'
    }
}

Describe 'Test-ClaimsGate — all claims resolve passes without added friction (#479 test 2)' {
    It 'passes when all verified claims are correct' {
        $claims = @(
            @{ claim = 'mcp-server-gsc'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view mcp-server-gsc'; correct = $true },
            @{ claim = 'search_analytics'; kind = 'api-tool'; status = 'verified'; howChecked = 'read README'; correct = $true }
        )
        $r = Test-ClaimsGate -Claims $claims
        $r.pass | Should -BeTrue
        @($r.flagged).Count | Should -Be 0
    }

    It 'gateStatus is verified when all claims pass' {
        $claims = @(@{ claim = 'mcp-server-gsc'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $true })
        (Test-ClaimsGate -Claims $claims).gateStatus | Should -Be 'verified'
    }
}

Describe 'Test-ClaimsGate — no external claims is not-applicable, no friction (#479 test 3)' {
    It 'returns not-applicable and pass for an empty claims list' {
        $r = Test-ClaimsGate -Claims @()
        $r.pass | Should -BeTrue
        $r.gateStatus | Should -Be 'not-applicable'
    }

    It 'produces zero flagged claims when there are no claims' {
        @((Test-ClaimsGate -Claims @()).flagged).Count | Should -Be 0
    }

    It 'a null entry in an otherwise empty list is still not-applicable' {
        $r = Test-ClaimsGate -Claims @($null)
        $r.pass | Should -BeTrue
        $r.gateStatus | Should -Be 'not-applicable'
    }
}

Describe 'Format-ClaimsSection — distinguishes verified / unverified / not-applicable (#479 test 4)' {
    It 'renders verified and unverified as distinct labels' {
        # A verified+correct claim renders PASS; an unverified claim renders UNVERIFIED.
        # These are three distinct status values that never collapse.
        $claims = @(
            @{ claim = 'mcp-server-gsc'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $true },
            @{ claim = '@ahonn/mcp-server-gsc'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null }
        )
        $s = Format-ClaimsSection -Claims $claims
        $s | Should -Match '\| PASS \|'
        $s | Should -Match '\| UNVERIFIED \|'
    }

    It 'renders not-applicable when claims list is empty' {
        Format-ClaimsSection -Claims @() | Should -Match '(?i)not.applicable'
    }

    It 'a correct verified claim is rendered PASS' {
        $claims = @(@{ claim = 'good-pkg'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $true })
        Format-ClaimsSection -Claims $claims | Should -Match '\| PASS \|'
    }

    It 'a wrong verified claim is rendered FAIL' {
        $claims = @(@{ claim = 'bad-pkg'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $false })
        Format-ClaimsSection -Claims $claims | Should -Match '\| FAIL \|'
    }

    It 'an unverified claim is rendered UNVERIFIED' {
        $claims = @(@{ claim = 'maybe-pkg'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null })
        Format-ClaimsSection -Claims $claims | Should -Match '\| UNVERIFIED \|'
    }

    It 'never collapses all three into the same label when mixed' {
        $claims = @(
            @{ claim = 'good'; kind = 'npm-package'; status = 'verified'; howChecked = 'x'; correct = $true },
            @{ claim = 'bad'; kind = 'npm-package'; status = 'verified'; howChecked = 'x'; correct = $false },
            @{ claim = 'maybe'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null }
        )
        $s = Format-ClaimsSection -Claims $claims
        $s | Should -Match '\| PASS \|'
        $s | Should -Match '\| FAIL \|'
        $s | Should -Match '\| UNVERIFIED \|'
    }
}

Describe 'Regression fixture — five fabrications from the incident are each caught (#479 test 5)' {
    BeforeAll {
        # The five fabricated claims from PR #262 on csalcedodatabi.com — each was stated
        # as a verified fact; in reality each was wrong. Registered here as verified+correct=false,
        # which is the state they would have been in had the run actually looked them up.
        $script:FiveFabrications = @(
            @{ claim = '@ahonn/mcp-server-gsc'; kind = 'npm-package'; status = 'verified'
               howChecked = '(would have been: npm view @ahonn/mcp-server-gsc)'; correct = $false },
            @{ claim = 'OAuth 2.0 via ~/.mcp/gsc-credentials.json'; kind = 'auth-mechanism'; status = 'verified'
               howChecked = '(would have been: read README auth section)'; correct = $false },
            @{ claim = '--auth flag on npx invocation'; kind = 'cli-flag'; status = 'verified'
               howChecked = '(would have been: npx mcp-server-gsc --help)'; correct = $false },
            @{ claim = 'list_sitemaps tool'; kind = 'api-tool'; status = 'verified'
               howChecked = '(would have been: read README tool list)'; correct = $false },
            @{ claim = 'get_sitemap tool'; kind = 'api-tool'; status = 'verified'
               howChecked = '(would have been: read README tool list)'; correct = $false }
        )
    }

    It 'the gate fails when the five fabrications are registered as verified+wrong' {
        $r = Test-ClaimsGate -Claims $script:FiveFabrications
        $r.pass | Should -BeFalse
    }

    It 'all five fabrications appear in the flagged list' {
        $r = Test-ClaimsGate -Claims $script:FiveFabrications
        @($r.flagged).Count | Should -Be 5
    }

    It 'each fabrication is flagged by its claim text' {
        $r = Test-ClaimsGate -Claims $script:FiveFabrications
        $r.flagged | Should -Contain '@ahonn/mcp-server-gsc'
        $r.flagged | Should -Contain 'OAuth 2.0 via ~/.mcp/gsc-credentials.json'
        $r.flagged | Should -Contain '--auth flag on npx invocation'
        $r.flagged | Should -Contain 'list_sitemaps tool'
        $r.flagged | Should -Contain 'get_sitemap tool'
    }

    It 'the rendered claims section shows all five as FAIL' {
        $s = Format-ClaimsSection -Claims $script:FiveFabrications
        ($s -split "`n" | Where-Object { $_ -match '\| FAIL \|' }).Count | Should -Be 5
    }

    It 'each fabrication claim text appears in the rendered section' {
        $s = Format-ClaimsSection -Claims $script:FiveFabrications
        # @ and / are not regex metacharacters in .NET; literal match is safe
        $s | Should -Match '@ahonn/mcp-server-gsc'
        $s | Should -Match 'list_sitemaps'
        $s | Should -Match 'get_sitemap'
    }
}

Describe 'Test-ClaimsGate — unverified claims are visible but not blocking' {
    It 'a run with only unverified claims still passes (gap is visible, not blocking)' {
        $claims = @(@{ claim = 'maybe-pkg'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null })
        $r = Test-ClaimsGate -Claims $claims
        $r.pass | Should -BeTrue
    }

    It 'gateStatus is has-unverified when some claims are not checked' {
        $claims = @(@{ claim = 'maybe'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null })
        (Test-ClaimsGate -Claims $claims).gateStatus | Should -Be 'has-unverified'
    }

    It 'verified+wrong takes precedence over unverified (both present → gate fails)' {
        $claims = @(
            @{ claim = 'bad-pkg'; kind = 'npm-package'; status = 'verified'; howChecked = 'npm view'; correct = $false },
            @{ claim = 'maybe'; kind = 'npm-package'; status = 'unverified'; howChecked = ''; correct = $null }
        )
        $r = Test-ClaimsGate -Claims $claims
        $r.pass | Should -BeFalse
        $r.gateStatus | Should -Be 'claims-failed'
    }
}
