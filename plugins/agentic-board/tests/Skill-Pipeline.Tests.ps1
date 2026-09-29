#Requires -Modules Pester
<#  Pester tests for Skill-Pipeline.ps1 - /skills create and /skills improve (#739).

    The deterministic half of the pipeline: overlap with installed skills (create a near-duplicate
    or improve the existing one?), where the skill belongs and why, the stages with their exit
    criteria, and the audit gate that ends the improve loop. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Skill-Pipeline.ps1' | Resolve-Path
    $env:ABIOS_SKILLPIPE_DOTSOURCE = '1'
    try { . $script:Script } finally { $env:ABIOS_SKILLPIPE_DOTSOURCE = '' }
    function script:Sk([string]$Name, [string]$Desc, [string]$Scope = 'personal') {
        [pscustomobject]@{ name = $Name; description = $Desc; scope = $Scope; path = "C:/x/$Name/SKILL.md" }
    }
}

Describe 'Get-SkillOverlap - improve the existing skill instead of writing a near-duplicate' {
    BeforeAll {
        $script:Installed = @(
            (script:Sk 'humanizer' 'Remove signs of AI-generated writing from text, make it sound human-written'),
            (script:Sk 'dax-reference' 'DAX function reference for Power BI measures'),
            (script:Sk 'pdf' 'Read and create PDF files'))
    }
    It 'flags a skill whose wording overlaps' {
        $r = @(Get-SkillOverlap -Name 'ai-text-cleaner' -Description 'Remove AI writing signs from text so it sounds human' -Installed $script:Installed)
        $r[0].name | Should -Be 'humanizer'
        $r[0].reason | Should -Be 'shared wording'
    }
    It 'a long installed description does not hide a duplicate (why this is not Jaccard)' {
        $long = script:Sk 'humanizer' ('Remove signs of AI-generated writing from text. Use when editing or reviewing text to make it sound more natural and human-written. ' +
            'Based on a comprehensive guide. Detects and fixes patterns including inflated symbolism, promotional language, superficial analyses, vague attributions, dash overuse, filler phrases.')
        (@(Get-SkillOverlap -Name 'ai-text-cleaner' -Description 'Remove signs of AI writing from text so it reads as human-written' -Installed @($long)))[0].name | Should -Be 'humanizer'
    }
    It 'flags the same name as a full overlap' {
        (@(Get-SkillOverlap -Name 'pdf' -Description 'anything' -Installed $script:Installed))[0].score | Should -Be 1.0
    }
    It 'says nothing for an unrelated skill' {
        @(Get-SkillOverlap -Name 'kafka-topics' -Description 'Create and tune Kafka topics' -Installed $script:Installed).Count | Should -Be 0
    }
    It 'ignores filler words, so two unrelated skills that both say "use when the user asks" do not match' {
        Get-WordOverlap (Get-SkillWords 'Use when the user asks for charts') (Get-SkillWords 'Use when the user asks for invoices') | Should -BeLessThan 0.5
    }
}

Describe 'Get-SkillScopeAdvice - where the skill belongs, with the reason' {
    It 'outside a repo: personal' {
        (Get-SkillScopeAdvice -Requested 'auto' -Name 'x' -Description 'y' -RepoName '').scope | Should -Be 'personal'
    }
    It 'names this repo: project' {
        $a = Get-SkillScopeAdvice -Requested 'auto' -Name 'fabric-apps-deploy' -Description 'Deploy fabric-apps' -RepoName 'fabric-apps'
        $a.scope | Should -Be 'project'
        $a.reason | Should -Match 'fabric-apps'
    }
    It 'names a folder of this repo: project' {
        (Get-SkillScopeAdvice -Requested 'auto' -Name 'x' -Description 'Regenerate the files under dashboards/ from the model' -RepoName 'r' -RepoPaths @('dashboards', 'src')).scope | Should -Be 'project'
    }
    It 'a short folder name inside another word is not a match' {
        (Get-SkillScopeAdvice -Requested 'auto' -Name 'x' -Description 'Build a sourcemap' -RepoName 'r' -RepoPaths @('src')).scope | Should -Be 'personal'
    }
    It 'general wording: personal, and the user can always choose' {
        (Get-SkillScopeAdvice -Requested 'auto' -Name 'humanize' -Description 'Clean AI text' -RepoName 'r' -RepoPaths @('src')).scope | Should -Be 'personal'
        $a = Get-SkillScopeAdvice -Requested 'project' -Name 'humanize' -Description 'Clean AI text' -RepoName 'r'
        $a.scope | Should -Be 'project'
        $a.reason | Should -Be 'chosen by the user'
    }
    It 'the target folder follows the scope' {
        Get-SkillTargetDir -Scope 'project' -Name 'x' -RepoRoot 'D:/r' -ClaudeHome 'C:/h' | Should -Be (Join-Path 'D:/r' '.claude' 'skills' 'x')
        Get-SkillTargetDir -Scope 'personal' -Name 'x' -RepoRoot 'D:/r' -ClaudeHome 'C:/h' | Should -Be (Join-Path 'C:/h' 'skills' 'x')
    }
}

Describe 'Get-SkillPipelineStages - every stage names its tool and when it is done' {
    It 'create: overlap and prior art before writing, a pressure test, the audit gate, the trigger eval' {
        $s = @(Get-SkillPipelineStages -Mode 'create' -Name 'x' -Target 'C:/h/skills/x')
        $s.Stage | Should -Be @('toolkit', 'overlap', 'prior-art', 'scope', 'author', 'pressure-test', 'improve-loop', 'trigger-eval')
        ($s | Where-Object Stage -eq 'author').Tool | Should -Be 'skill-creator'
        ($s | Where-Object Stage -eq 'pressure-test').Done | Should -Match 'WITHOUT the skill failed'
        ($s | Where-Object Stage -eq 'improve-loop').Tool | Should -Match 'Skill-Pipeline.ps1 -Verify -Name x'
    }
    It 'improve: audit first, then the loop, then re-test' {
        (@(Get-SkillPipelineStages -Mode 'improve' -Name 'x' -Target 't')).Stage | Should -Be @('toolkit', 'audit', 'improve-loop', 'pressure-test', 'trigger-eval')
    }
    It 'every stage has a tool and an exit criterion' {
        foreach ($m in 'create', 'improve') {
            foreach ($st in (Get-SkillPipelineStages -Mode $m -Name 'x' -Target 't')) {
                $st.Tool | Should -Not -BeNullOrEmpty
                $st.Done | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Test-SkillAuditGate - the loop ends only when no high or medium finding remains' {
    It 'passes with only low findings, which stay visible as advisory' {
        $g = Test-SkillAuditGate @([pscustomobject]@{ severity = 'low'; type = 'no-when-not' })
        $g.Pass | Should -BeTrue
        @($g.Advisory).Count | Should -Be 1
    }
    It 'blocks on a high or medium finding' {
        (Test-SkillAuditGate @([pscustomobject]@{ severity = 'med'; type = 'no-triggers' })).Pass | Should -BeFalse
        (Test-SkillAuditGate @([pscustomobject]@{ severity = 'high'; type = 'empty-desc' })).Pass | Should -BeFalse
    }
    It 'passes with no findings' { (Test-SkillAuditGate @()).Pass | Should -BeTrue }
}

Describe '/skills menu offers create and improve and routes them' {
    BeforeAll { $script:Cmd = Get-Content (Join-Path $PSScriptRoot '..' 'commands' 'skills.md') -Raw }
    It 'lists both verbs in the menu' {
        $script:Cmd | Should -Match '(?m)^\d+\.\s+create\s'
        $script:Cmd | Should -Match '(?m)^\d+\.\s+improve\s'
    }
    It 'routes them to the skills-create skill and the pipeline script' {
        $script:Cmd | Should -Match 'skills-create'
        $script:Cmd | Should -Match 'Skill-Pipeline\.ps1'
        Test-Path (Join-Path $PSScriptRoot '..' 'skills' 'skills-create' 'SKILL.md') | Should -BeTrue
    }
}
