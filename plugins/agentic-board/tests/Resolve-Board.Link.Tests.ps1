#Requires -Modules Pester
<#  Tests for the two Resolve-Board fixes of this file's PR:

      #498  the board must be found through the repository -> Projects v2 LINK GitHub records
            (repository.projectsV2, what Board-Work -ListBoards reads), not by guessing at the
            board's TITLE - a board named after the product was invisible, and the not-found path
            then advised creating a DUPLICATE;
      #666  -Title is a SELECTOR: the board it names is reused or created, and a board with a
            different title is never handed back as if it were the one asked for.

    The seam is the `gh` executable, mocked (the real Resolve-Board and the real Invoke-Gh run).
    The mock answers by what was asked: the `graphql` call is the LINK lookup, `project list` is the
    title fallback, `project create` / `project link` are the writes. The counts on the last two are
    the assertions that matter - "did it create a board" is the whole difference between reusing the
    board and manufacturing its duplicate. #>

BeforeAll {
    $script:Script = (Join-Path $PSScriptRoot '..' 'scripts' 'Resolve-Board.ps1' | Resolve-Path).Path

    # Run the real script, keep its return value apart from what it printed.
    function Invoke-Resolve {
        param([hashtable]$Params)
        $all  = & $script:Script @Params 6>&1
        $text = (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $ret  = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        [pscustomobject]@{ Value = $(if ($ret.Count) { $ret[-1] } else { $null }); Text = $text }
    }
}

Describe '#498 - the board is found through the repository link, not its title' {

    Context 'a repo whose linked board is named after the PRODUCT' {
        BeforeEach {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[{"number":5,"title":"Vega Studio PBI - Roadmap","closed":false,"owner":{"login":"X"}}]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[]}' }
                elseif ($joined -match 'project\s+create'){ '{"number":99}' }
                else                                       { '' }
            }
        }
        It 'finds it (the title does not contain the repo name) and creates nothing' {
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/visual-studio-pbi'; CreateIfMissing = $false }
            $r.Value | Should -Be 5
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
        It 'does not even need the owner-wide title list when the link answers' {
            $null = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/visual-studio-pbi'; CreateIfMissing = $false }
            Should -Invoke gh -ParameterFilter { ($args -join ' ') -match 'project\s+list' } -Times 0 -Exactly
        }
        It 'the default (CreateIfMissing) path reuses it instead of creating a duplicate' {
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/visual-studio-pbi' }
            $r.Value | Should -Be 5
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
    }

    Context 'which linked boards count' {
        It 'ignores closed, backup and foreign-owner boards, and falls back to titles only when none is left' {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[' +
                             '{"number":1,"title":"old","closed":true,"owner":{"login":"X"}},' +
                             '{"number":2,"title":"widget Backup","closed":false,"owner":{"login":"X"}},' +
                             '{"number":3,"title":"someone elses","closed":false,"owner":{"login":"Other"}}]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[{"number":8,"title":"widget - Roadmap"}]}' }
                else                                       { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }).Value | Should -Be 8
            Should -Invoke gh -ParameterFilter { ($args -join ' ') -match 'project\s+list' } -Times 1 -Exactly
        }
        It 'prefers the canonical Roadmap board when several are linked, and says so' {
            Mock gh {
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[' +
                    '{"number":3,"title":"Ideas","closed":false,"owner":{"login":"X"}},' +
                    '{"number":9,"title":"widget — Roadmap","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }
            $r.Value | Should -Be 9
            $r.Text  | Should -Match '2 boards vinculados'
        }
        It 'the canonical title uses an EM-DASH (U+2014): a hyphenated "<repo> - Roadmap" is NOT canonical (review of #689)' {
            Mock gh {
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[' +
                    '{"number":4,"title":"Ideas","closed":false,"owner":{"login":"X"}},' +
                    '{"number":9,"title":"widget - Roadmap","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            # With a hyphen counted as canonical this would pick #9; under the real rule it falls to the lowest number.
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }).Value | Should -Be 4
        }
        It 'with several linked and no canonical one, takes the lowest number' {
            Mock gh {
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[' +
                    '{"number":12,"title":"B","closed":false,"owner":{"login":"X"}},' +
                    '{"number":4,"title":"A","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }).Value | Should -Be 4
        }
    }

    Context 'edge cases of the link lookup' {
        It 'a bare repo name is read as a repo of -Owner and still goes through the link (not title guessing)' {
            Mock gh {
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[{"number":5,"title":"Product Board","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'widget'; CreateIfMissing = $false }).Value | Should -Be 5
            Should -Invoke gh -ParameterFilter { ($args -join ' ') -match 'o=X' -and ($args -join ' ') -match 'r=widget' } -Times 1 -Exactly
        }
        It 'refuses to create when the link list was cut short and nothing matched (absence is not proven)' {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[]}' }
                elseif ($joined -match 'project\s+create'){ '{"number":42}' }
                else                                       { '' }
            }
            { Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' } } | Should -Throw '*mas de 100 boards*'
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
        It 'an explicit -Title is checked against the owner-wide list, so a cut-short LINK list does not block creating it' {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[{"number":1,"title":"other"}]}' }
                elseif ($joined -match 'project\s+create'){ '{"number":42}' }
                else                                       { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Brand New'; SkipPreset = $true }).Value | Should -Be 42
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 1 -Exactly
        }
        It 'a board reused through the title HEURISTICS is not linked behind the caller''s back, but the gap is announced' {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[{"number":8,"title":"widget scratchpad"}]}' }
                else                                       { '' }
            }
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }
            $r.Value | Should -Be 8
            $r.Text  | Should -Match 'gh project link 8'
            Should -Invoke gh -ParameterFilter { $args -contains 'link' } -Times 0 -Exactly
        }
        It 'a cut-short list still resolves when the board IS on the page that was read' {
            Mock gh {
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"pageInfo":{"hasNextPage":true},"nodes":[{"number":5,"title":"P","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' }).Value | Should -Be 5
        }
        It '-Confirm does not make the READS prompt: $ConfirmPreference stays out of the lookup' {
            $global:SeenConfirm = @()
            Mock gh {
                $global:SeenConfirm += "$ConfirmPreference"
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[{"number":5,"title":"P","closed":false,"owner":{"login":"X"}}]}}}}' } else { '' }
            }
            (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Confirm = $true }).Value | Should -Be 5
            @($global:SeenConfirm).Count | Should -BeGreaterThan 0
            @($global:SeenConfirm | Where-Object { $_ -eq 'Low' }).Count | Should -Be 0
        }
        Context 'an exact -Title found only among UNLINKED boards' {
            BeforeEach {
                Mock gh {
                    $global:LASTEXITCODE = 0
                    $joined = $args -join ' '
                    if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                    elseif ($joined -match 'project\s+list')  { '{"projects":[{"number":31,"title":"Sales"}]}' }
                    else                                       { '' }
                }
            }
            It 'is reused AND linked to the repo, so the next lookup without -Title finds it instead of duplicating' {
                $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Sales'; CreateIfMissing = $false }
                $r.Value | Should -Be 31
                Should -Invoke gh -ParameterFilter { ($args -contains 'link') -and ($args -contains '31') -and ($args -contains 'X/widget') } -Times 1 -Exactly
                Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
            }
            It '-WhatIf reuses it but does not link' {
                (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Sales'; WhatIf = $true }).Value | Should -Be 31
                Should -Invoke gh -ParameterFilter { $args -contains 'link' } -Times 0 -Exactly
            }
            It 'a failing link is a WARN, not a failure: the board is still the one that was asked for' {
                Mock gh {
                    $joined = $args -join ' '
                    if     ($joined -match 'graphql')         { $global:LASTEXITCODE = 0; '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                    elseif ($joined -match 'project\s+list')  { $global:LASTEXITCODE = 0; '{"projects":[{"number":31,"title":"Sales"}]}' }
                    elseif ($args -contains 'link')           { $global:LASTEXITCODE = 1 }
                    else                                       { $global:LASTEXITCODE = 0; '' }
                }
                $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Sales'; CreateIfMissing = $false }
                $r.Value | Should -Be 31
                $r.Text  | Should -Match 'no pude vincular'
            }
        }
        It 'asks gh for a wide board list, and refuses to create when even that was cut short' {
            $script:cut = '{"projects":[' + ((1..200 | ForEach-Object { "{`"number`":$_,`"title`":`"b$_`"}" }) -join ',') + ']}'
            $global:CutJson = $script:cut
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                elseif ($joined -match 'project\s+list')  { $global:CutJson }
                else                                       { '' }
            }
            { Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' } } | Should -Throw '*la lista se corto*'
            Should -Invoke gh -ParameterFilter { ($args -contains 'list') -and ($args -contains '--limit') } -Times 1 -Exactly
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
    }

    Context 'nothing found' {
        BeforeEach {
            Mock gh {
                $global:LASTEXITCODE = 0
                $joined = $args -join ' '
                if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                elseif ($joined -match 'project\s+list')  { '{"projects":[]}' }
                elseif ($joined -match 'project\s+create'){ '{"number":42}' }
                else                                       { '' }
            }
        }
        It 'returns $null without creating, and its message warns about duplicates instead of just advising a create' {
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; CreateIfMissing = $false }
            $r.Value | Should -BeNullOrEmpty
            $r.Text  | Should -Match 'linked to the repository'
            $r.Text  | Should -Match 'duplicate'
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
        It 'a failed LINK read throws instead of reading as "no linked board" (fail closed)' {
            Mock gh { $global:LASTEXITCODE = 1 }
            { Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' } } | Should -Throw
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
        It 'a graphql errors[] body on the link read throws too (exit 0 is not success)' {
            Mock gh { $global:LASTEXITCODE = 0; '{"errors":[{"message":"Could not resolve to a Repository"}],"data":{"repository":null}}' }
            { Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' } } | Should -Throw '*Repository*'
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
        }
        It '-WhatIf reports and creates nothing, but the READS still run un-rehearsed' {
            # $WhatIfPreference is inherited by every cmdlet Invoke-Gh's runner uses (temp-file
            # redirect, Remove-Item); if it leaked into the reads, the rehearsal would also break
            # the lookups that decide whether a board exists. The mock records what it saw.
            $global:SeenWhatIf = @()
            Mock gh {
                $global:SeenWhatIf += [bool]$WhatIfPreference
                $global:LASTEXITCODE = 0
                if (($args -join ' ') -match 'graphql') { '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' }
                elseif (($args -join ' ') -match 'project\s+list') { '{"projects":[]}' } else { '{"number":42}' }
            }
            $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; WhatIf = $true }
            $r.Value | Should -BeNullOrEmpty
            Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
            Should -Invoke gh -ParameterFilter { ($args -join ' ') -match 'graphql' } -Times 1 -Exactly
            @($global:SeenWhatIf).Count | Should -BeGreaterThan 0
            @($global:SeenWhatIf | Where-Object { $_ }).Count | Should -Be 0
        }
    }
}

Describe '#666 - -Title selects; it is never silently ignored' {
    BeforeEach {
        Mock gh {
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if     ($joined -match 'graphql')         { '{"data":{"repository":{"projectsV2":{"nodes":[{"number":5,"title":"Engineering","closed":false,"owner":{"login":"X"}}]}}}}' }
            elseif ($joined -match 'project\s+list')  { '{"projects":[{"number":5,"title":"Engineering"},{"number":6,"title":"widget scratch"}]}' }
            elseif ($joined -match 'project\s+create'){ '{"number":77}' }
            else                                       { '' }
        }
    }
    It 'a different -Title on a repo that already has a board CREATES a second board and returns ITS number' {
        $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Sales'; SkipPreset = $true }
        $r.Value | Should -Be 77
        Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 1 -Exactly
        Should -Invoke gh -ParameterFilter { $args -contains 'link' }   -Times 1 -Exactly
        $r.Text | Should -Match "board aparte 'Sales'"
    }
    It 'never hands back a board whose title merely resembles the request (no "*repo*" heuristic with -Title)' {
        # 'widget scratch' contains the repo name; under the old title heuristic it answered for 'Sales'.
        $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Sales'; SkipPreset = $true }
        $r.Value | Should -Not -Be 6
    }
    It 'reuses the linked board whose title is EXACTLY the one asked for' {
        $r = Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'Engineering' }
        $r.Value | Should -Be 5
        Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
    }
    It 'the exact-title match is case-insensitive like every other name compare in the suite' {
        (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget'; Title = 'engineering' }).Value | Should -Be 5
    }
    It 'without -Title it still means "the board for this repo"' {
        (Invoke-Resolve @{ Owner = 'X'; Repo = 'X/widget' }).Value | Should -Be 5
        Should -Invoke gh -ParameterFilter { $args -contains 'create' } -Times 0 -Exactly
    }
}
