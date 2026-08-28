#Requires -Modules Pester
<#  Pester tests for the grouped-PR suggestion helpers of Board-Work.ps1 (#662).

    These are pure functions over board items, so they run through the script's
    dot-source guard with no gh call and no filesystem access.

    The tests that matter most here are the NEGATIVE ones. A suggestion engine that
    groups too eagerly is worse than no engine: it puts unrelated issues into one PR,
    which is the failure the per-issue default was protecting against. So every
    "does not group" case below is load-bearing. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    # A board item shaped like the ones Get-BoardItems returns.
    function New-PendingItem {
        param(
            [int]     $Number,
            [string]  $Title  = 'a thing',
            [string]  $Body   = '',
            [string]  $Area   = $null,
            [string]  $Type   = 'Issue',
            [string]  $Repo   = 'owner/repo',
            [string[]]$Labels = @()
        )
        [pscustomobject]@{
            area    = $Area
            labels  = $Labels
            content = [pscustomobject]@{
                number = $Number; title = $Title; body = $Body; type = $Type; repository = $Repo
            }
        }
    }

    $script:Files = @(
        'plugins/agentic-board/scripts/Board-ReviewGate.ps1',
        'plugins/agentic-board/scripts/Apply-FieldPreset.ps1',
        'plugins/agentic-board/scripts/Board-Work.ps1',
        'README.md'
    )
}

Describe 'Get-RepoFileTokens' {
    It 'maps both the file name and its hyphenated stem back to the file' {
        $t = Get-RepoFileTokens -Paths @('scripts/Board-ReviewGate.ps1')
        $t['Board-ReviewGate.ps1'] | Should -BeExactly 'Board-ReviewGate.ps1'
        $t['Board-ReviewGate']     | Should -BeExactly 'Board-ReviewGate.ps1'
    }

    It 'ignores files whose stem is ordinary prose - the whole board would match "readme"' {
        $t = Get-RepoFileTokens -Paths @('README.md', 'index.js', 'config.json')
        $t.Count | Should -Be 0
    }

    It 'drops a non-distinctive file ENTIRELY, not just its bare stem' {
        # Deliberate, and worth pinning: an external reviewer read the gate as applying only to
        # the stem. It does not. "Two issues both mention board.md" is not a reason to put them
        # in one PR, so the full name with extension is dropped too.
        $t = Get-RepoFileTokens -Paths @('commands/board.md')
        $t.ContainsKey('board.md') | Should -BeFalse
        $t.ContainsKey('board')    | Should -BeFalse
    }

    It 'ignores a hyphenated stem that is too short to be evidence' {
        $t = Get-RepoFileTokens -Paths @('a-b.ps1')
        $t.Count | Should -Be 0
    }

    It 'tolerates empty and null entries' {
        { Get-RepoFileTokens -Paths @('', $null) } | Should -Not -Throw
    }
}

Describe 'Test-NamesToken' {
    It 'matches the token as a whole word' {
        Test-NamesToken -Text 'the Board-ReviewGate passes' -Token 'Board-ReviewGate' | Should -BeTrue
    }
    It 'matches case-insensitively' {
        Test-NamesToken -Text 'board-reviewgate.ps1 exits 2' -Token 'Board-ReviewGate.ps1' | Should -BeTrue
    }
    It 'does NOT match a longer name that merely starts with the token' {
        Test-NamesToken -Text 'Board-ReviewGateway is different' -Token 'Board-ReviewGate' | Should -BeFalse
    }
    It 'does NOT match a longer name that merely ends with the token' {
        Test-NamesToken -Text 'see Legacy-Board-Work here' -Token 'Board-Work' | Should -BeFalse
    }
    It 'matches at the very start and the very end of the text' {
        Test-NamesToken -Text 'Board-Work is the driver' -Token 'Board-Work' | Should -BeTrue
        Test-NamesToken -Text 'the driver is Board-Work' -Token 'Board-Work' | Should -BeTrue
    }
    It 'is false for empty text or an empty token' {
        Test-NamesToken -Text ''  -Token 'Board-Work' | Should -BeFalse
        Test-NamesToken -Text 'x' -Token ''           | Should -BeFalse
    }
}

Describe 'Test-Groupable' {
    It 'accepts a plain pending issue' {
        Test-Groupable (New-PendingItem -Number 1) | Should -BeTrue
    }
    It 'refuses a draft note - there is no issue for a PR to close' {
        Test-Groupable (New-PendingItem -Number 0 -Type 'DraftIssue') | Should -BeFalse
    }
    It 'refuses a blocked issue - StartGroup would drop it anyway' {
        Test-Groupable (New-PendingItem -Number 2 -Labels @('blocked')) | Should -BeFalse
    }
}

Describe 'Get-GroupingSuggestions - file evidence' {
    It 'groups two issues that name the same script' {
        $pending = @(
            (New-PendingItem -Number 656 -Title 'Review gate: cooldown armed wrongly' -Body 'in Board-ReviewGate.ps1'),
            (New-PendingItem -Number 657 -Title 'Review gate counts missing checks'   -Body 'Board-ReviewGate.ps1 again'),
            (New-PendingItem -Number 999 -Title 'something unrelated'                 -Body 'no file here')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo')
        $s.Count            | Should -Be 1
        $s[0].reason        | Should -BeExactly 'file'
        $s[0].evidence      | Should -BeExactly 'Board-ReviewGate.ps1'
        $s[0].issues        | Should -Be @(656, 657)
    }

    It 'does NOT group a single issue that names a file on its own' {
        $pending = @(
            (New-PendingItem -Number 1 -Title 'only one' -Body 'Board-ReviewGate.ps1'),
            (New-PendingItem -Number 2 -Title 'unrelated' -Body '')
        )
        @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo').Count | Should -Be 0
    }

    It 'finds the file name in the TITLE, not only the body' {
        $pending = @(
            (New-PendingItem -Number 649 -Title 'Apply-FieldPreset reports created on failure'),
            (New-PendingItem -Number 654 -Title 'Apply-FieldPreset: reserved name Type')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo')
        $s.Count       | Should -Be 1
        $s[0].evidence | Should -BeExactly 'Apply-FieldPreset.ps1'
    }

    It 'puts each issue in at most one suggestion, file evidence winning over area' {
        $pending = @(
            (New-PendingItem -Number 10 -Title 'a' -Body 'Board-ReviewGate.ps1' -Area 'Work'),
            (New-PendingItem -Number 11 -Title 'b' -Body 'Board-ReviewGate.ps1' -Area 'Work'),
            (New-PendingItem -Number 12 -Title 'c' -Body 'no file'              -Area 'Work'),
            (New-PendingItem -Number 13 -Title 'd' -Body 'no file'              -Area 'Work')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo')
        $s.Count | Should -Be 2
        ($s | Where-Object { $_.reason -eq 'file' }).issues | Should -Be @(10, 11)
        ($s | Where-Object { $_.reason -eq 'area' }).issues | Should -Be @(12, 13)
        # No issue appears twice across the whole set.
        $all = @($s | ForEach-Object { $_.issues })
        ($all | Sort-Object -Unique).Count | Should -Be $all.Count
    }
}

Describe 'Get-GroupingSuggestions - area evidence' {
    It 'groups issues sharing a non-empty Area' {
        $pending = @(
            (New-PendingItem -Number 471 -Area 'Work'),
            (New-PendingItem -Number 480 -Area 'Work'),
            (New-PendingItem -Number 511 -Area 'Triage')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles @())
        $s.Count       | Should -Be 1
        $s[0].reason   | Should -BeExactly 'area'
        $s[0].evidence | Should -BeExactly 'Work'
        $s[0].issues   | Should -Be @(471, 480)
    }

    It 'does NOT group issues that merely share an EMPTY area' {
        $pending = @(
            (New-PendingItem -Number 1 -Area $null),
            (New-PendingItem -Number 2 -Area ''),
            (New-PendingItem -Number 3 -Area '   ')
        )
        @(Get-GroupingSuggestions -Pending $pending -RepoFiles @()).Count | Should -Be 0
    }

    It 'excludes drafts and blocked issues from a group' {
        $pending = @(
            (New-PendingItem -Number 1 -Area 'Work'),
            (New-PendingItem -Number 2 -Area 'Work' -Labels @('blocked')),
            (New-PendingItem -Number 0 -Area 'Work' -Type 'DraftIssue')
        )
        @(Get-GroupingSuggestions -Pending $pending -RepoFiles @()).Count | Should -Be 0
    }
}

Describe 'Get-GroupingSuggestions - a board can hold more than one repo' {
    # A single PR lives in ONE repo. `Closes #n` only closes an issue of that same repo, and
    # -StartGroup puts the whole batch on one branch in one checkout. So a group spanning two
    # repos is a batch that cannot be finished -- it starts the issues and then strands them.
    It 'never groups issues from different repos, even when the area matches' {
        $pending = @(
            (New-PendingItem -Number 1 -Area 'Work' -Repo 'owner/alpha'),
            (New-PendingItem -Number 2 -Area 'Work' -Repo 'owner/beta')
        )
        @(Get-GroupingSuggestions -Pending $pending -RepoFiles @()).Count | Should -Be 0
    }

    It 'groups within each repo separately when both have enough issues' {
        $pending = @(
            (New-PendingItem -Number 1 -Area 'Work' -Repo 'owner/alpha'),
            (New-PendingItem -Number 2 -Area 'Work' -Repo 'owner/alpha'),
            (New-PendingItem -Number 3 -Area 'Work' -Repo 'owner/beta'),
            (New-PendingItem -Number 4 -Area 'Work' -Repo 'owner/beta')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles @())
        $s.Count | Should -Be 2
        foreach ($g in $s) { @($g.repo).Count | Should -Be 1 }
        ($s | Where-Object { $_.repo -eq 'owner/alpha' }).issues | Should -Be @(1, 2)
        ($s | Where-Object { $_.repo -eq 'owner/beta'  }).issues | Should -Be @(3, 4)
    }

    It 'does not let an issue number claimed in one repo block the same number in another' {
        # Issue numbers are unique PER REPO, not across a board. Keying the "already in a group"
        # set on the bare number makes owner/alpha#10 lock out owner/beta#10 -- silently, and
        # only on the multi-repo boards this partitioning exists to serve.
        $pending = @(
            (New-PendingItem -Number 10 -Area 'Work' -Repo 'owner/alpha'),
            (New-PendingItem -Number 11 -Area 'Work' -Repo 'owner/alpha'),
            (New-PendingItem -Number 10 -Area 'Work' -Repo 'owner/beta'),
            (New-PendingItem -Number 11 -Area 'Work' -Repo 'owner/beta')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles @())
        $s.Count | Should -Be 2
        ($s | Where-Object { $_.repo -eq 'owner/alpha' }).issues | Should -Be @(10, 11)
        ($s | Where-Object { $_.repo -eq 'owner/beta'  }).issues | Should -Be @(10, 11)
    }

    It 'applies file evidence ONLY to issues of the current checkout' {
        # The file list comes from THIS checkout's git ls-files. A foreign-repo issue naming
        # the same filename is naming a different file.
        $pending = @(
            (New-PendingItem -Number 1 -Body 'Board-ReviewGate.ps1' -Repo 'owner/alpha'),
            (New-PendingItem -Number 2 -Body 'Board-ReviewGate.ps1' -Repo 'owner/beta')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/alpha')
        $s.Count | Should -Be 0
    }

    It 'still groups by file within the current repo' {
        $pending = @(
            (New-PendingItem -Number 1 -Body 'Board-ReviewGate.ps1' -Repo 'owner/alpha'),
            (New-PendingItem -Number 2 -Body 'Board-ReviewGate.ps1' -Repo 'owner/alpha'),
            (New-PendingItem -Number 3 -Body 'Board-ReviewGate.ps1' -Repo 'owner/beta')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/alpha')
        $s.Count       | Should -Be 1
        $s[0].reason   | Should -BeExactly 'file'
        $s[0].issues   | Should -Be @(1, 2)
    }
}

Describe 'Get-ItemRepoName - the two item shapes this script carries' {
    It 'reads the plain string that the board listing returns' {
        Get-ItemRepoName ([pscustomobject]@{ content = [pscustomobject]@{ repository = 'owner/repo' } }) |
            Should -BeExactly 'owner/repo'
    }
    It 'reads nameWithOwner from the GraphQL shape instead of stringifying the object' {
        # Stringifying would give every repo the same bucket name, merging the board back into
        # one group - the partitioning failing while looking like it works.
        $item = [pscustomobject]@{ content = [pscustomobject]@{
            repository = [pscustomobject]@{ nameWithOwner = 'owner/repo' } } }
        Get-ItemRepoName $item | Should -BeExactly 'owner/repo'
    }
    It 'is empty when there is no repository at all' {
        Get-ItemRepoName ([pscustomobject]@{ content = [pscustomobject]@{} }) | Should -BeExactly ''
    }
}

Describe 'Get-GroupingSuggestions - shape and ordering' {
    It 'returns an empty set for an empty board' {
        @(Get-GroupingSuggestions -Pending @() -RepoFiles $script:Files -CurrentRepo 'owner/repo').Count | Should -Be 0
    }

    It 'returns an empty set when a single issue is pending' {
        @(Get-GroupingSuggestions -Pending @((New-PendingItem -Number 1 -Area 'Work')) -RepoFiles @()).Count | Should -Be 0
    }

    It 'orders the biggest saving first' {
        $pending = @(
            (New-PendingItem -Number 1 -Area 'Small'),
            (New-PendingItem -Number 2 -Area 'Small'),
            (New-PendingItem -Number 3 -Area 'Big'),
            (New-PendingItem -Number 4 -Area 'Big'),
            (New-PendingItem -Number 5 -Area 'Big')
        )
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles @())
        $s[0].evidence | Should -BeExactly 'Big'
        $s[1].evidence | Should -BeExactly 'Small'
    }
}

Describe 'Get-GroupingSuggestions - the group-size cap' {
    It 'caps the group and returns the overflow instead of dropping it silently' {
        $pending = 1..7 | ForEach-Object { New-PendingItem -Number $_ -Body 'Board-ReviewGate.ps1' }
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo' -MaxGroup 4)
        $s.Count       | Should -Be 1
        $s[0].issues   | Should -Be @(1, 2, 3, 4)
        $s[0].dropped  | Should -Be @(5, 6, 7)
    }

    It 'leaves dropped empty when the group fits' {
        $pending = 1..3 | ForEach-Object { New-PendingItem -Number $_ -Body 'Board-ReviewGate.ps1' }
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo' -MaxGroup 4)
        @($s[0].dropped).Count | Should -Be 0
    }

    It 'does NOT re-offer a capped-out issue under a weaker signal' {
        # Five issues name the same file AND share an area. With MaxGroup 4 the fifth is held
        # back for size - it must not resurface as an "area" group, which would read to the
        # user as a second, independent reason to batch it.
        $pending = 1..5 | ForEach-Object { New-PendingItem -Number $_ -Body 'Board-ReviewGate.ps1' -Area 'Work' }
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo' -MaxGroup 4)
        $s.Count     | Should -Be 1
        $s[0].reason | Should -BeExactly 'file'
        $s[0].issues | Should -Not -Contain 5
    }

    It 'counts only the PRs actually saved by the capped group' {
        $pending = 1..7 | ForEach-Object { New-PendingItem -Number $_ -Body 'Board-ReviewGate.ps1' }
        $s = @(Get-GroupingSuggestions -Pending $pending -RepoFiles $script:Files -CurrentRepo 'owner/repo' -MaxGroup 4)
        Get-GroupingSavings -Suggestions $s | Should -Be 3
    }
}

Describe 'Show-GroupingOffer - what each posture actually says' {
    BeforeAll {
        # Pester 5 only exposes helpers defined inside BeforeAll to the It blocks.
        # Write-Host goes to the information stream in PowerShell 7, so 6>&1 captures it.
        function Get-OfferText {
            param($Suggestions, [string]$Posture)
            (Show-GroupingOffer -Suggestions $Suggestions -Posture $Posture 6>&1 | Out-String)
        }

        $script:OneGroup = @([pscustomobject]@{ reason = 'file'; evidence = 'Board-Work.ps1'; issues = @(1, 2); dropped = @() })
    }

    It 'says nothing at all under auto when there is nothing to group' {
        (Get-OfferText -Suggestions @() -Posture 'auto').Trim() | Should -BeExactly ''
    }

    It 'under always, SAYS that nothing overlaps instead of going silent like auto' {
        # The repo asked for grouping. Silence here is indistinguishable from "auto had nothing
        # to say", so the standing preference would look like it was ignored.
        $text = Get-OfferText -Suggestions @() -Posture 'always'
        $text | Should -Match 'no hay dos pendientes que se solapen'
    }

    It 'under never, suppresses the offer even when groups exist' {
        $text = Get-OfferText -Suggestions $script:OneGroup -Posture 'never'
        $text | Should -Match 'un PR por issue'
        $text | Should -Not -Match 'Se pueden juntar'
    }

    It 'under auto, presents the group with its evidence' {
        $text = Get-OfferText -Suggestions $script:OneGroup -Posture 'auto'
        $text | Should -Match 'Se pueden juntar'
        $text | Should -Match 'Board-Work\.ps1'
        $text | Should -Match '#1, #2'
    }

    It 'names the issues it held back for size instead of dropping them silently' {
        $capped = @([pscustomobject]@{ reason = 'file'; evidence = 'Board-Work.ps1'; issues = @(1, 2, 3, 4); dropped = @(5, 6) })
        $text = Get-OfferText -Suggestions $capped -Posture 'auto'
        $text | Should -Match '#5, #6'
        $text | Should -Match 'revisable'
    }

    It 'counts the groups it did not print rather than truncating in silence' {
        $many = 1..8 | ForEach-Object {
            [pscustomobject]@{ reason = 'area'; evidence = "A$_"; issues = @($_, $_ + 100); dropped = @() }
        }
        $text = Get-OfferText -Suggestions $many -Posture 'auto'
        $text | Should -Match 'y 3 grupo\(s\) mas'
    }
}

Describe 'Select-StartableGroup - the batch the next-step line may actually offer' {
    BeforeAll {
        $script:Mine    = [pscustomobject]@{ repo = 'owner/here';    issues = @(1, 2);       evidence = 'a' }
        $script:Foreign = [pscustomobject]@{ repo = 'owner/elsewhere'; issues = @(3, 4, 5, 6); evidence = 'b' }
    }

    It 'picks the biggest group OF THIS REPO, not the biggest group overall' {
        # -StartGroup creates the branch in the current checkout. Offering a foreign batch would
        # start those issues here and then open a PR that cannot close them.
        $g = Select-StartableGroup -Suggestions @($script:Foreign, $script:Mine) -CurrentRepo 'owner/here'
        $g.repo | Should -BeExactly 'owner/here'
    }

    It 'returns nothing when every group belongs to another repo' {
        Select-StartableGroup -Suggestions @($script:Foreign) -CurrentRepo 'owner/here' | Should -BeNullOrEmpty
    }

    It 'returns nothing when there are no groups at all' {
        Select-StartableGroup -Suggestions @() -CurrentRepo 'owner/here' | Should -BeNullOrEmpty
    }

    It 'falls back to the ordering when there is no current repo to compare against' {
        $g = Select-StartableGroup -Suggestions @($script:Foreign, $script:Mine) -CurrentRepo ''
        $g.repo | Should -BeExactly 'owner/elsewhere'
    }
}

Describe 'Get-GroupingSavings' {
    It 'counts the PR cycles removed, not the issues' {
        $s = @(
            [pscustomobject]@{ issues = @(1, 2, 3) },   # 3 PRs -> 1  = 2 saved
            [pscustomobject]@{ issues = @(4, 5) }       # 2 PRs -> 1  = 1 saved
        )
        Get-GroupingSavings -Suggestions $s | Should -Be 3
    }
    It 'is zero for no suggestions' {
        Get-GroupingSavings -Suggestions @() | Should -Be 0
    }
}
