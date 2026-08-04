#Requires -Modules Pester
<#  Tests for Expert-WorkClass.ps1 — classifying a change as CODE or VISUAL (#529, part of #526).

    The rule being encoded: code is judged by READING it, so an agent that reviewed it carefully can
    close it; a dashboard, a page or an image is judged by LOOKING at it, and only the owner can do
    that. Getting this wrong in the permissive direction ships something he wanted to see. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-WorkClass.ps1' | Resolve-Path
    $env:ABIOS_WORKCLASS_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_WORKCLASS_DOTSOURCE = ''
    $script:P = New-WorkClassPolicy
}

Describe 'Get-WorkClass — code is judged by reading it' {
    It 'classifies scripts as code' {
        (Get-WorkClass -ChangedPaths @('plugins/agentic-board/scripts/Board-Work.ps1') -Policy $script:P).class |
            Should -Be 'code'
    }
    It 'classifies tests as code' {
        (Get-WorkClass -ChangedPaths @('tests/Board-Work.Tests.ps1') -Policy $script:P).class | Should -Be 'code'
    }
    It 'classifies a workflow as code' {
        (Get-WorkClass -ChangedPaths @('.github/workflows/ci.yml') -Policy $script:P).class | Should -Be 'code'
    }
    It 'classifies plain docs as code — prose is READ, so routing it to the owner is the friction we are removing' {
        (Get-WorkClass -ChangedPaths @('CHANGELOG.md','docs/design.md') -Policy $script:P).class | Should -Be 'code'
    }
    It 'classifies several code files together as code' {
        (Get-WorkClass -ChangedPaths @('a.ps1','b.psm1','c.json') -Policy $script:P).class | Should -Be 'code'
    }
}

Describe 'Get-WorkClass — visual is judged by looking at it' {
    It 'classifies a Power BI report file as visual' {
        (Get-WorkClass -ChangedPaths @('reports/Ventas.pbix') -Policy $script:P).class | Should -Be 'visual'
    }
    It 'classifies a PBIP report page as visual' {
        (Get-WorkClass -ChangedPaths @('Ventas.Report/definition/pages/page1.json') -Policy $script:P).class |
            Should -Be 'visual'
    }
    It 'classifies a web page as visual' {
        (Get-WorkClass -ChangedPaths @('site/index.html') -Policy $script:P).class | Should -Be 'visual'
    }
    It 'classifies a stylesheet as visual' {
        (Get-WorkClass -ChangedPaths @('site/css/main.css') -Policy $script:P).class | Should -Be 'visual'
    }
    It 'classifies an image at any depth as visual' {
        (Get-WorkClass -ChangedPaths @('docs/img/deep/nested/banner.png') -Policy $script:P).class |
            Should -Be 'visual'
    }
    It 'classifies a theme file as visual' {
        (Get-WorkClass -ChangedPaths @('themes/corporate.theme.json') -Policy $script:P).class | Should -Be 'visual'
    }
}

Describe 'Get-WorkClass — one visual file makes the whole change visual' {
    # The asymmetry that decides the fail direction: the owner glancing at something routine costs
    # a minute; an agent shipping a dashboard he wanted to eyeball costs trust.
    It 'a single image among many code files still routes to the human' {
        $r = Get-WorkClass -ChangedPaths @('src/a.ps1','src/b.ps1','docs/screenshot.png','tests/c.Tests.ps1') -Policy $script:P
        $r.class | Should -Be 'visual'
        $r.visualPaths | Should -Contain 'docs/screenshot.png'
    }
    It 'names how many files drove the decision' {
        (Get-WorkClass -ChangedPaths @('a.ps1','x.png','y.html') -Policy $script:P).visualPaths.Count | Should -Be 2
    }
}

Describe 'Get-WorkClass — "I could not tell" is never "it was code"' {
    It 'returns unknown for an empty change list' {
        (Get-WorkClass -ChangedPaths @() -Policy $script:P).class | Should -Be 'unknown'
    }
    It 'returns unknown when every entry is blank' {
        (Get-WorkClass -ChangedPaths @('', '   ') -Policy $script:P).class | Should -Be 'unknown'
    }
}

Describe 'Test-HumanMustApprove' {
    It 'lets the agent close code'        { Test-HumanMustApprove -Class 'code'    -Policy $script:P | Should -BeFalse }
    It 'sends visual to the human'        { Test-HumanMustApprove -Class 'visual'  -Policy $script:P | Should -BeTrue }
    It 'sends UNKNOWN to the human too'   { Test-HumanMustApprove -Class 'unknown' -Policy $script:P | Should -BeTrue }
    It 'sends an empty class to the human'{ Test-HumanMustApprove -Class ''        -Policy $script:P | Should -BeTrue }
    It 'is case-insensitive'              { Test-HumanMustApprove -Class 'VISUAL'  -Policy $script:P | Should -BeTrue }
    It 'honours a policy that also reserves code for the human' {
        $strict = @{ visualPatterns = $script:P.visualPatterns; humanApproves = @('visual','code') }
        Test-HumanMustApprove -Class 'code' -Policy $strict | Should -BeTrue
    }
}

Describe 'Glob semantics — a single * must not cross a directory boundary' {
    # `-like` cannot express this: its '*' happily crosses '/', so 'src/*.ps1' would swallow
    # 'src/deep/nested/x.ps1' and the classification would widen with every subdirectory.
    It 'src/*.css matches a file directly in src' {
        Test-IsVisualPath -Path 'src/main.css' -VisualPatterns @('src/*.css') | Should -BeTrue
    }
    It 'src/*.css does NOT match a nested file' {
        Test-IsVisualPath -Path 'src/deep/main.css' -VisualPatterns @('src/*.css') | Should -BeFalse
    }
    It '**/ matches any depth including none' {
        Test-IsVisualPath -Path 'a.png'         -VisualPatterns @('**/*.png') | Should -BeTrue
        Test-IsVisualPath -Path 'x/y/z/a.png'   -VisualPatterns @('**/*.png') | Should -BeTrue
    }
    It 'a bare extension pattern applies at every depth' {
        Test-IsVisualPath -Path 'deep/nested/a.png' -VisualPatterns @('*.png') | Should -BeTrue
    }
    It 'handles Windows backslashes in the path' {
        Test-IsVisualPath -Path 'site\css\main.css' -VisualPatterns @('**/*.css') | Should -BeTrue
    }
    It 'does not match an unrelated extension' {
        Test-IsVisualPath -Path 'src/main.ps1' -VisualPatterns @('*.css','*.png') | Should -BeFalse
    }
    It 'ignores blank patterns' {
        Test-IsVisualPath -Path 'src/main.ps1' -VisualPatterns @('', '   ') | Should -BeFalse
    }
    It 'treats an empty path as not visual' {
        Test-IsVisualPath -Path '' -VisualPatterns @('*.png') | Should -BeFalse
    }

    Context 'leading dots survive normalization (external review, round 1)' {
        # `TrimStart('./')` takes a CHARACTER SET, not a prefix: it ate the leading dot of a hidden
        # directory, so '.reports/x.md' became 'reports/x.md' and a '.reports/**' pattern silently
        # stopped matching -- a visual change reclassified as code.
        It 'matches a hidden directory pattern' {
            Test-IsVisualPath -Path '.reports/summary.html' -VisualPatterns @('.reports/**') | Should -BeTrue
        }
        It 'does not confuse a hidden directory with its unhidden namesake' {
            Test-IsVisualPath -Path 'reports/summary.html' -VisualPatterns @('.reports/**') | Should -BeFalse
        }
        It 'still strips an explicit ./ prefix' {
            Test-IsVisualPath -Path './site/index.html' -VisualPatterns @('site/*.html') | Should -BeTrue
        }
        It 'strips a repeated ./ prefix' {
            Test-IsVisualPath -Path './././a.png' -VisualPatterns @('*.png') | Should -BeTrue
        }
    }
}

Describe 'Get-EffectiveWorkClassPolicy — the contract narrows, the defaults fill' {
    It 'falls back to defaults with no contract' {
        (Get-EffectiveWorkClassPolicy -Contract $null).visualPatterns.Count | Should -BeGreaterThan 0
    }
    It 'falls back to defaults when the contract leaves the lists empty' {
        $c = @{ workClass = @{ visualPatterns = @(); humanApproves = @('visual') } }
        (Get-EffectiveWorkClassPolicy -Contract $c).visualPatterns.Count | Should -BeGreaterThan 0
    }
    It 'a project can add what is visual FOR IT' {
        # e.g. a website where the posts themselves are the product.
        $c = @{ workClass = @{ visualPatterns = @('content/posts/**'); humanApproves = @('visual') } }
        $p = Get-EffectiveWorkClassPolicy -Contract $c
        Test-IsVisualPath -Path 'content/posts/hola.md' -VisualPatterns $p.visualPatterns | Should -BeTrue
        # ...and that replaces the defaults rather than silently merging with them.
        Test-IsVisualPath -Path 'a.png' -VisualPatterns $p.visualPatterns | Should -BeFalse
    }
}

Describe 'codeExceptions - declared plumbing is judged by reading (#567)' {
    # In a web app every change touches css/html/assets, so without exceptions the whole project
    # routes to the owner and the classification stops carrying information. Exceptions are
    # SUBTRACTIVE and DECLARED (contract), never guessed: the default list is empty.
    It 'the default policy has no exceptions - fail direction unchanged out of the box' {
        @((New-WorkClassPolicy).codeExceptions).Count | Should -Be 0
        (Get-WorkClass -ChangedPaths @('src/components/button.css') -Policy (New-WorkClassPolicy)).class | Should -Be 'visual'
    }
    It 'a declared exception reclassifies matching web-tech paths as code' {
        $p = New-WorkClassPolicy
        $p.codeExceptions = @('src/components/**/*.css')
        (Get-WorkClass -ChangedPaths @('src/components/deep/button.css') -Policy $p).class | Should -Be 'code'
    }
    It 'an exception is surgical: the rest of the visual surface still routes to the owner' {
        $p = New-WorkClassPolicy
        $p.codeExceptions = @('src/components/**/*.css')
        $r = Get-WorkClass -ChangedPaths @('src/components/x.css', 'pages/dashboard.html') -Policy $p
        $r.class | Should -Be 'visual'
        $r.visualPaths | Should -Be @('pages/dashboard.html')
    }
    It 'the contract can declare exceptions through Get-EffectiveWorkClassPolicy' {
        $c = @{ workClass = @{ codeExceptions = @('site/css/**') } }
        $p = Get-EffectiveWorkClassPolicy -Contract $c
        (Get-WorkClass -ChangedPaths @('site/css/main.css') -Policy $p).class | Should -Be 'code'
    }
}

Describe 'visualGroups - the owner approves SECTIONS, not file rows (#567)' {
    It 'groups visual paths by top-level directory' {
        $r = Get-WorkClass -ChangedPaths @('pages/a.html','pages/b.html','themes/x.theme.json','logo.png') -Policy (New-WorkClassPolicy)
        $r.visualGroups | Should -Be @('(raiz)','pages','themes')
    }
    It 'the reason names the sections so the approval is a batch decision' {
        $r = Get-WorkClass -ChangedPaths @('pages/a.html','pages/b.html') -Policy (New-WorkClassPolicy)
        $r.reason | Should -Match 'pages'
        $r.reason | Should -Match '1 seccion'
    }
}

Describe 'Get-ApplicableDodGates - the DoD scales to the diff (#569)' {
    BeforeAll {
        $script:AllDod = @{ ci = $true; build = $true; lint = $true; tests = $true; bpa = $true; tmdlBreaking = $true }
    }

    It 'a docs-only diff owes only ci' {
        $g = Get-ApplicableDodGates -Dod $script:AllDod -ChangedPaths @('README.md', 'docs/design.md')
        ($g | Sort-Object) | Should -Be @('ci')
    }
    It 'a code diff owes build/lint/tests/ci but not the model gates' {
        $g = Get-ApplicableDodGates -Dod $script:AllDod -ChangedPaths @('scripts/App.ps1')
        ($g | Sort-Object) | Should -Be @('build','ci','lint','tests')
    }
    It 'a model diff owes everything' {
        $g = Get-ApplicableDodGates -Dod $script:AllDod -ChangedPaths @('model/Ventas.tmdl', 'scripts/x.ps1')
        ($g | Sort-Object) | Should -Be @('bpa','build','ci','lint','tests','tmdlBreaking')
    }
    It 'an EMPTY diff owes every enabled gate - not knowing never waives a check (fail closed)' {
        $g = Get-ApplicableDodGates -Dod $script:AllDod -ChangedPaths @()
        @($g).Count | Should -Be 6
    }
    It 'it only ever DISABLES: a gate the contract turned off never comes back' {
        $dod = @{ ci = $true; build = $true; lint = $false; tests = $true; bpa = $false; tmdlBreaking = $true }
        $g = Get-ApplicableDodGates -Dod $dod -ChangedPaths @('model/Ventas.tmdl')
        $g | Should -Not -Contain 'lint'
        $g | Should -Not -Contain 'bpa'
        $g | Should -Contain 'tmdlBreaking'
    }
    It 'an unknown custom gate is always owed - unrecognized never means excused' {
        $dod = @{ ci = $true; sonar = $true }
        (Get-ApplicableDodGates -Dod $dod -ChangedPaths @('README.md')) | Should -Contain 'sonar'
    }
}
