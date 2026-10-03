#Requires -Modules Pester
<#  Pester tests for Get-BoardVocabulary.ps1 - the canonical/legacy option map
    behind issue #278 (a board born from GitHub's default template used to be
    silently invisible to /board work, and /board field apply could not migrate it). #>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Get-BoardVocabulary.ps1' | Resolve-Path)
}

Describe 'Get-CanonicalOptionNames' {
    It 'returns the canonical Status options in preset order' {
        Get-CanonicalOptionNames 'Status' | Should -Be @('Backlog', 'In Progress', 'In Review', 'Blocked', 'Done')
    }
    It 'returns an empty array for a field with no canonical vocabulary' {
        @(Get-CanonicalOptionNames 'Type').Count  | Should -Be 0
        @(Get-CanonicalOptionNames 'Estado').Count | Should -Be 0
        @(Get-CanonicalOptionNames $null).Count   | Should -Be 0
    }
}

Describe 'Get-CanonicalOptionName (legacy -> canonical)' {
    It "maps GitHub's default-template 'Todo' to 'Backlog'" {
        Get-CanonicalOptionName 'Status' 'Todo'  | Should -Be 'Backlog'
        Get-CanonicalOptionName 'Status' 'To Do' | Should -Be 'Backlog'
    }
    It 'maps the verbose Priority names onto P0..P3' {
        Get-CanonicalOptionName 'Priority' 'P2 Medium'   | Should -Be 'P2'
        Get-CanonicalOptionName 'Priority' 'P0 Critical' | Should -Be 'P0'
        Get-CanonicalOptionName 'Priority' 'Low'         | Should -Be 'P3'
    }
    It 'returns a canonical name unchanged' {
        Get-CanonicalOptionName 'Status'   'Backlog' | Should -Be 'Backlog'
        Get-CanonicalOptionName 'Priority' 'P2'      | Should -Be 'P2'
    }
    It 'is case-insensitive' {
        Get-CanonicalOptionName 'Status' 'todo'    | Should -Be 'Backlog'
        Get-CanonicalOptionName 'Status' 'BACKLOG' | Should -Be 'Backlog'
    }
    It 'returns $null for an unrecognized name instead of guessing' {
        Get-CanonicalOptionName 'Status' 'Pendiente'  | Should -BeNullOrEmpty
        Get-CanonicalOptionName 'Status' 'Icebox'     | Should -BeNullOrEmpty
        Get-CanonicalOptionName 'Status' ''           | Should -BeNullOrEmpty
        Get-CanonicalOptionName 'Status' $null        | Should -BeNullOrEmpty
    }
    It 'returns $null for a field outside the vocabulary' {
        Get-CanonicalOptionName 'Type' 'Bug' | Should -BeNullOrEmpty
    }
}

Describe 'Test-CanonicalOptionName' {
    It 'accepts only exact canonical names' {
        Test-CanonicalOptionName 'Status' 'Backlog' | Should -BeTrue
        Test-CanonicalOptionName 'Status' 'Todo'    | Should -BeFalse
        Test-CanonicalOptionName 'Status' $null     | Should -BeFalse
    }
}

Describe 'Get-OptionAliases (lookup order)' {
    It 'puts the canonical name first, then its legacy aliases' {
        Get-OptionAliases 'Priority' 'P2' | Should -Be @('P2', 'P2 Medium', 'Medium')
    }
    It 'returns just the canonical name when it has no aliases' {
        Get-OptionAliases 'Status' 'Done' | Should -Be @('Done')
    }
    It 'returns just the name for a field outside the vocabulary' {
        Get-OptionAliases 'Type' 'Bug' | Should -Be @('Bug')
    }
}

Describe 'Get-LegacyOptionRenames (the -Migrate plan)' {
    It "plans Todo -> Backlog on a default-template board, by option ID" {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'In Progress' }
            [pscustomobject]@{ id = 'o3'; name = 'Done' }
        )
        $plan = @(Get-LegacyOptionRenames -Field 'Status' -Options $opts)
        $plan.Count      | Should -Be 1
        $plan[0].Id      | Should -Be 'o1'
        $plan[0].From    | Should -Be 'Todo'
        $plan[0].To      | Should -Be 'Backlog'
        $plan[0].Conflict | Should -BeFalse
    }
    It 'plans nothing for an already-canonical board (idempotent)' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Backlog' }
            [pscustomobject]@{ id = 'o2'; name = 'Done' }
        )
        @(Get-LegacyOptionRenames -Field 'Status' -Options $opts).Count | Should -Be 0
    }
    It 'leaves an unknown option name alone instead of guessing' {
        $opts = @([pscustomobject]@{ id = 'o1'; name = 'Icebox' })
        @(Get-LegacyOptionRenames -Field 'Status' -Options $opts).Count | Should -Be 0
    }
    It 'flags a rename whose canonical target already exists (GitHub rejects duplicates)' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'Backlog' }
        )
        $plan = @(Get-LegacyOptionRenames -Field 'Status' -Options $opts)
        $plan.Count       | Should -Be 1
        $plan[0].Conflict | Should -BeTrue
    }
    It 'plans every legacy Priority option at once' {
        $opts = @(
            [pscustomobject]@{ id = 'p0'; name = 'P0 Critical' }
            [pscustomobject]@{ id = 'p1'; name = 'P1 High' }
            [pscustomobject]@{ id = 'p2'; name = 'P2 Medium' }
        )
        $plan = @(Get-LegacyOptionRenames -Field 'Priority' -Options $opts)
        @($plan | ForEach-Object { $_.To }) | Should -Be @('P0', 'P1', 'P2')
        @($plan | Where-Object { $_.Conflict }).Count | Should -Be 0
    }
    It 'plans nothing for an empty option set' {
        @(Get-LegacyOptionRenames -Field 'Status' -Options @()).Count | Should -Be 0
    }
}

Describe 'Get-LegacyOptionRenames — alias-to-alias collisions (Codex review, PR #279)' {
    It 'lets only the FIRST of two aliases claim the canonical name; the rest are conflicts' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'To Do' }
        )
        $plan = @(Get-LegacyOptionRenames -Field 'Status' -Options $opts)
        $plan.Count       | Should -Be 2
        $plan[0].Conflict | Should -BeFalse   # 'Todo' takes 'Backlog'
        $plan[1].Conflict | Should -BeTrue    # 'To Do' cannot also be 'Backlog'
    }
    It 'flags BOTH aliases when the canonical name already exists on the field' {
        $opts = @(
            [pscustomobject]@{ id = 'o0'; name = 'Backlog' }
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'To Do' }
        )
        $plan = @(Get-LegacyOptionRenames -Field 'Status' -Options $opts)
        @($plan | Where-Object { -not $_.Conflict }).Count | Should -Be 0
    }
    It 'still plans distinct canonical targets independently' {
        $opts = @(
            [pscustomobject]@{ id = 'p0'; name = 'P0 Critical' }
            [pscustomobject]@{ id = 'p1'; name = 'P1 High' }
        )
        @(Get-LegacyOptionRenames -Field 'Priority' -Options $opts | Where-Object { $_.Conflict }).Count | Should -Be 0
    }
}

Describe 'Get-LegacyOptionMerges (resolving the conflicts, issue #300)' {
    It "collapses 'Todo' onto an existing 'Backlog' - the state a plain apply leaves behind" {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'Backlog' }
            [pscustomobject]@{ id = 'o3'; name = 'Done' }
        )
        $plan = @(Get-LegacyOptionMerges -Field 'Status' -Options $opts)
        $plan.Count       | Should -Be 1
        $plan[0].FromId   | Should -Be 'o1'
        $plan[0].FromName | Should -Be 'Todo'
        $plan[0].ToId     | Should -Be 'o2'
        $plan[0].ToName   | Should -Be 'Backlog'
    }
    It 'plans NO merge when the canonical name is free (a plain rename handles it)' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'Done' }
        )
        @(Get-LegacyOptionMerges -Field 'Status' -Options $opts).Count | Should -Be 0
    }
    It 'plans nothing for an already-canonical board (idempotent)' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Backlog' }
            [pscustomobject]@{ id = 'o2'; name = 'Done' }
        )
        @(Get-LegacyOptionMerges -Field 'Status' -Options $opts).Count | Should -Be 0
    }
    It 'leaves an unknown option name alone instead of guessing' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Icebox' }
            [pscustomobject]@{ id = 'o2'; name = 'Backlog' }
        )
        @(Get-LegacyOptionMerges -Field 'Status' -Options $opts).Count | Should -Be 0
    }
    It 'merges the SECOND alias onto the first one once it is renamed (Todo + To Do, no Backlog)' {
        # 'Todo' renames to 'Backlog'; 'To Do' cannot, so it must merge INTO the renamed
        # option - by its id (o1), which only exists after the rename.
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'To Do' }
        )
        $plan = @(Get-LegacyOptionMerges -Field 'Status' -Options $opts)
        $plan.Count       | Should -Be 1
        $plan[0].FromId   | Should -Be 'o2'
        $plan[0].FromName | Should -Be 'To Do'
        $plan[0].ToId     | Should -Be 'o1'
        $plan[0].ToName   | Should -Be 'Backlog'
    }
    It 'merges BOTH aliases when the canonical option already exists' {
        $opts = @(
            [pscustomobject]@{ id = 'o0'; name = 'Backlog' }
            [pscustomobject]@{ id = 'o1'; name = 'Todo' }
            [pscustomobject]@{ id = 'o2'; name = 'To Do' }
        )
        $plan = @(Get-LegacyOptionMerges -Field 'Status' -Options $opts)
        $plan.Count | Should -Be 2
        @($plan | ForEach-Object { $_.FromName }) | Should -Be @('Todo', 'To Do')
        @($plan | ForEach-Object { $_.ToId })     | Should -Be @('o0', 'o0')
    }
    It 'never merges an option into itself' {
        $opts = @([pscustomobject]@{ id = 'o1'; name = 'Backlog' })
        @(Get-LegacyOptionMerges -Field 'Status' -Options $opts | Where-Object { $_.FromId -eq $_.ToId }).Count | Should -Be 0
    }
    It 'collapses the verbose Priority aliases onto existing canonical options' {
        $opts = @(
            [pscustomobject]@{ id = 'p0'; name = 'P2' }
            [pscustomobject]@{ id = 'p1'; name = 'P2 Medium' }
            [pscustomobject]@{ id = 'p2'; name = 'Medium' }
        )
        $plan = @(Get-LegacyOptionMerges -Field 'Priority' -Options $opts)
        $plan.Count | Should -Be 2
        @($plan | ForEach-Object { $_.ToId }) | Should -Be @('p0', 'p0')
    }
    It 'plans nothing for a field outside the vocabulary' {
        $opts = @(
            [pscustomobject]@{ id = 'o1'; name = 'Bug' }
            [pscustomobject]@{ id = 'o2'; name = 'Feature' }
        )
        @(Get-LegacyOptionMerges -Field 'Type' -Options $opts).Count | Should -Be 0
    }
    It 'plans nothing for an empty option set' {
        @(Get-LegacyOptionMerges -Field 'Status' -Options @()).Count | Should -Be 0
    }
}
