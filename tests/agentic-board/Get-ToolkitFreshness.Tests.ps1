#Requires -Modules Pester
<#  Pester tests for Get-ToolkitFreshness.ps1 — provenance scan + fresh/behind/unknown
    classification against an injected upstream-SHA map (no network). #>

BeforeAll {
    $script:Fresh = Join-Path $PSScriptRoot '..' 'scripts' 'Get-ToolkitFreshness.ps1' | Resolve-Path

    function New-Prov($dir, $name, $repo, $path, $sha) {
        $skill = Join-Path $dir $name
        New-Item -ItemType Directory -Path $skill -Force | Out-Null
        $p = [ordered]@{ name=$name; repo=$repo; path=$path; sha=$sha; owner='Someone'; license='MIT'; installedAt='2026-07-17T00:00:00Z' }
        $p | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $skill '.abios-provenance.json') -Encoding utf8
    }
}

Describe 'Get-ToolkitFreshness' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("freshtest-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
        New-Prov $script:tmp 'a' 'owner/a' 'a' 'AAAAAAApandinner'
        New-Prov $script:tmp 'b' 'owner/b' 'b' 'BBBBBBBpandinner'
        New-Prov $script:tmp 'c' 'owner/c' 'c' 'CCCCCCCpandinner'
        # a skill folder with NO provenance must be ignored
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'no-prov') -Force | Out-Null
        $script:map = @{ 'owner/a|a' = 'AAAAAAApandinner'; 'owner/b|b' = 'ZZZZZZZmoved'; 'owner/c|c' = $null }
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'classifies fresh / behind / unknown from the injected map' {
        $r = & $script:Fresh -SkillsDir $script:tmp -LatestShaMap $script:map
        $r.summary.total   | Should -Be 3
        $r.summary.fresh   | Should -Be 1
        $r.summary.behind  | Should -Be 1
        $r.summary.unknown | Should -Be 1
        ($r.tools | Where-Object name -eq 'a').status | Should -Be 'fresh'
        ($r.tools | Where-Object name -eq 'b').status | Should -Be 'behind'
        ($r.tools | Where-Object name -eq 'c').status | Should -Be 'unknown'
    }

    It 'shortens SHAs to 7 chars in the report' {
        $r = & $script:Fresh -SkillsDir $script:tmp -LatestShaMap $script:map
        ($r.tools | Where-Object name -eq 'a').installed | Should -Be 'AAAAAAA'
    }

    It 'treats a missing installed SHA as unknown' {
        New-Prov $script:tmp 'd' 'owner/d' 'd' $null
        $m = $script:map.Clone(); $m['owner/d|d'] = 'somethingfresh'
        $r = & $script:Fresh -SkillsDir $script:tmp -LatestShaMap $m
        ($r.tools | Where-Object name -eq 'd').status | Should -Be 'unknown'
    }

    It 'returns an empty report for a skills dir with no provenance' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("freshempty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        try {
            $r = & $script:Fresh -SkillsDir $empty -LatestShaMap @{}
            $r.summary.total | Should -Be 0
        } finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'produces valid JSON' {
        $json = & $script:Fresh -SkillsDir $script:tmp -LatestShaMap $script:map -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }
}
