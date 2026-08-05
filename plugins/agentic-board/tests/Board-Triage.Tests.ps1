#Requires -Modules Pester
<#  Tests for Board-Triage.ps1's pure triage logic (#306).

    Board-Triage.ps1 is side-effecting (reads/writes the board over gh), so it exposes a dot-source
    guard: with $env:ABIOS_TRIAGE_DOTSOURCE set it returns after defining the pure helpers. These
    tests pin the two rules the issue is about: the EVIDENCE fields (Type/Area/Estimate) are the ones
    flagged as gaps, and a Priority write is REFUSED without a rationale (the proposal must show its
    reasoning — never a silent P-value). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Triage.ps1' | Resolve-Path
    $env:ABIOS_TRIAGE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_TRIAGE_DOTSOURCE = ''
}

Describe 'Get-TriageGaps (evidence fields only)' {
    It 'flags every blank evidence field' {
        $g = Get-TriageGaps @{ Type = ''; Area = ''; Estimate = ''; Priority = '' }
        $g | Should -Contain 'Type'; $g | Should -Contain 'Area'; $g | Should -Contain 'Estimate'
    }
    It 'never flags Priority as a plain gap (it is filled only via the confirmed proposal)' {
        $g = Get-TriageGaps @{ Type = 'Bug'; Area = 'scripts'; Estimate = '3'; Priority = '' }
        $g | Should -BeNullOrEmpty
    }
    It 'reports only the still-blank evidence fields' {
        (Get-TriageGaps @{ Type = 'Bug'; Area = ''; Estimate = '2' }) | Should -Be @('Area')
    }
    It 'treats whitespace-only as blank' {
        (Get-TriageGaps @{ Type = '   '; Area = 'x'; Estimate = '1' }) | Should -Be @('Type')
    }
}

Describe 'Test-PriorityRequest (proposal must carry a rationale)' {
    It 'accepts no-Priority requests (nothing to validate)' {
        Test-PriorityRequest -Priority '' -Rationale '' | Should -BeNullOrEmpty
    }
    It 'refuses a Priority with no rationale (a silent P-value is exactly what #306 forbids)' {
        Test-PriorityRequest -Priority 'P1' -Rationale '' | Should -Match 'razonamiento'
    }
    It 'accepts a Priority that carries a rationale' {
        Test-PriorityRequest -Priority 'P1' -Rationale 'blocks the release' | Should -BeNullOrEmpty
    }
}

Describe 'Format-PriorityProposal (visible, correctable)' {
    It 'shows the issue, the P-value, and the reasoning on one line' {
        $line = Format-PriorityProposal -IssueNum 42 -Priority 'P1' -Rationale 'blocks the release'
        $line | Should -Match '#42'
        $line | Should -Match 'P1'
        $line | Should -Match 'blocks the release'
    }
}

Describe 'Get-TriageBoardPlan — never default to the tool board from a foreign repo (#382)' {
    It 'honors an explicit -Number as-is (no origin resolution)' {
        $p = Get-TriageBoardPlan -ExplicitNumber $true -ExplicitOwner $true -DefaultNumber 13 -DefaultOwner 'CSalcedoDataBI' -OriginRepo 'someone/other'
        $p.ResolveFromOrigin | Should -BeFalse
        $p.Number            | Should -Be 13
    }
    It 'resolves from origin when -Number is absent (the footgun fix)' {
        $p = Get-TriageBoardPlan -ExplicitNumber $false -ExplicitOwner $false -DefaultNumber 13 -DefaultOwner 'CSalcedoDataBI' -OriginRepo 'acme/reports'
        $p.ResolveFromOrigin | Should -BeTrue
        $p.Owner             | Should -Be 'acme'
        $p.Number            | Should -Be 0
    }
    It 'keeps an explicit -Owner even when resolving the board from origin' {
        $p = Get-TriageBoardPlan -ExplicitNumber $false -ExplicitOwner $true -DefaultNumber 13 -DefaultOwner 'MyOrg' -OriginRepo 'acme/reports'
        $p.ResolveFromOrigin | Should -BeTrue
        $p.Owner             | Should -Be 'MyOrg'
    }
    It 'refuses (no-origin) with neither an explicit -Number nor a usable origin — never falls back to #13' {
        $p = Get-TriageBoardPlan -ExplicitNumber $false -ExplicitOwner $false -DefaultNumber 13 -DefaultOwner 'CSalcedoDataBI' -OriginRepo ''
        $p.ResolveFromOrigin | Should -BeFalse
        $p.Reason            | Should -Be 'no-origin'
    }
}

Describe 'Resolve-IssueRef — parse -Issue argument into repo+number (#506)' {
    It 'bare number returns unqualified ref with empty repo' {
        $r = Resolve-IssueRef -IssueArg '42' -ExplicitRepo ''
        $r.Number    | Should -Be 42
        $r.Repo      | Should -Be ''
        $r.Qualified | Should -BeFalse
    }
    It 'qualified form owner/repo#n returns exact repo+number' {
        $r = Resolve-IssueRef -IssueArg 'owner/repoA#42' -ExplicitRepo ''
        $r.Number    | Should -Be 42
        $r.Repo      | Should -Be 'owner/repoA'
        $r.Qualified | Should -BeTrue
    }
    It 'bare number with -ExplicitRepo returns qualified ref' {
        $r = Resolve-IssueRef -IssueArg '42' -ExplicitRepo 'owner/repoA'
        $r.Number    | Should -Be 42
        $r.Repo      | Should -Be 'owner/repoA'
        $r.Qualified | Should -BeTrue
    }
    It 'qualified form matching -ExplicitRepo is accepted (same repo)' {
        $r = Resolve-IssueRef -IssueArg 'owner/repoA#42' -ExplicitRepo 'owner/repoA'
        $r.Repo | Should -Be 'owner/repoA'
    }
    It 'qualified form conflicting with -ExplicitRepo throws' {
        { Resolve-IssueRef -IssueArg 'owner/repoA#42' -ExplicitRepo 'owner/repoB' } | Should -Throw
    }
    It 'invalid input throws' {
        { Resolve-IssueRef -IssueArg 'not-valid' -ExplicitRepo '' } | Should -Throw
    }
}

Describe 'Find-TriageItems — locate board items by issue ref (#506)' {
    BeforeAll {
        $script:ItemA5  = [pscustomobject]@{ id = 'PVTI_aa'; content = [pscustomobject]@{ number = 5; repository = 'owner/repoA'; title = 'Bug in A' }; status = 'Backlog' }
        $script:ItemB5  = [pscustomobject]@{ id = 'PVTI_bb'; content = [pscustomobject]@{ number = 5; repository = 'owner/repoB'; title = 'Bug in B' }; status = 'Backlog' }
        $script:ItemA10 = [pscustomobject]@{ id = 'PVTI_cc'; content = [pscustomobject]@{ number = 10; repository = 'owner/repoA'; title = 'Feature in A' }; status = 'In Progress' }
        $script:Items   = @($script:ItemA5, $script:ItemB5, $script:ItemA10)
    }
    It 'qualified ref returns only the matching repo item' {
        $ref  = [pscustomobject]@{ Repo = 'owner/repoA'; Number = 5; Qualified = $true }
        $hits = Find-TriageItems -Ref $ref -Items $script:Items
        $hits.Count        | Should -Be 1
        $hits[0].id        | Should -Be 'PVTI_aa'
    }
    It 'qualified ref for the other repo returns that repo item only' {
        $ref  = [pscustomobject]@{ Repo = 'owner/repoB'; Number = 5; Qualified = $true }
        $hits = Find-TriageItems -Ref $ref -Items $script:Items
        $hits.Count        | Should -Be 1
        $hits[0].id        | Should -Be 'PVTI_bb'
    }
    It 'bare ref matching one item returns that single item' {
        $ref  = [pscustomobject]@{ Repo = ''; Number = 10; Qualified = $false }
        $hits = Find-TriageItems -Ref $ref -Items $script:Items
        $hits.Count        | Should -Be 1
        $hits[0].id        | Should -Be 'PVTI_cc'
    }
    It 'bare ref with number collision returns both candidates (caller must refuse)' {
        $ref  = [pscustomobject]@{ Repo = ''; Number = 5; Qualified = $false }
        $hits = Find-TriageItems -Ref $ref -Items $script:Items
        $hits.Count | Should -Be 2
    }
    It 'returns empty array when no item matches' {
        $ref  = [pscustomobject]@{ Repo = 'owner/repoA'; Number = 99; Qualified = $true }
        $hits = Find-TriageItems -Ref $ref -Items $script:Items
        $hits.Count | Should -Be 0
    }
}

Describe 'Format-ItemRef — display canonical owner/repo#number (#506)' {
    It 'includes repo when content.repository is present' {
        $item = [pscustomobject]@{ content = [pscustomobject]@{ repository = 'owner/repoA'; number = 42 } }
        Format-ItemRef -Item $item | Should -Be 'owner/repoA#42'
    }
    It 'falls back to bare #number when content.repository is empty' {
        $item = [pscustomobject]@{ content = [pscustomobject]@{ repository = ''; number = 7 } }
        Format-ItemRef -Item $item | Should -Be '#7'
    }
}
