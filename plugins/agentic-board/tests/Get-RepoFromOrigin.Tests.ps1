#Requires -Modules Pester
<#  Pester tests for Get-RepoFromOrigin.ps1 — the single owner/name + issue-number resolver (#281).

    Both helpers replace an inline one-liner that was copy-pasted across eleven scripts and got
    fixed in only three of them. The two bugs they encode are pinned here:

      * `github\.com[/:]([^/]+)/([^/.]+)` excluded '.' to strip the `.git` suffix, and so ate
        any dot belonging to the NAME: `midominio.com` -> `midominio` -> every gh call 404s.
      * `[int]($url -split '/')[-1]` yields 0 for empty input WITHOUT throwing, so a failed
        `gh issue create` printed "OK #0" and reported "fallos: 0" having created nothing.

    Pure -> no git, no gh, no token. #>

BeforeAll {
    $script:Helper = Join-Path $PSScriptRoot '..' 'scripts' 'Get-RepoFromOrigin.ps1' | Resolve-Path
    . $script:Helper
}

Describe 'Get-RepoFromOriginUrl (owner/name from an origin URL)' {
    It 'reads a plain https clone URL' {
        Get-RepoFromOriginUrl 'https://github.com/CSalcedoDataBI/agentic-board.git' | Should -Be 'CSalcedoDataBI/agentic-board'
    }
    It 'reads an https URL with no .git suffix' {
        Get-RepoFromOriginUrl 'https://github.com/CSalcedoDataBI/agentic-board' | Should -Be 'CSalcedoDataBI/agentic-board'
    }
    It 'reads an scp-style git@ URL' {
        Get-RepoFromOriginUrl 'git@github.com:owner/name.git' | Should -Be 'owner/name'
    }
    It 'reads an ssh:// URL' {
        Get-RepoFromOriginUrl 'ssh://git@github.com/owner/name.git' | Should -Be 'owner/name'
    }
    It 'reads a deprecated git:// URL' {
        # The old unanchored regex accepted this by accident; anchoring must not silently
        # regress anyone who still has such a remote (Codex review, PR #284).
        Get-RepoFromOriginUrl 'git://github.com/owner/name.git' | Should -Be 'owner/name'
    }
    It 'reads the ssh.github.com:443 alias used behind firewalls' {
        # Neither version handled this: the old one matched the "github.com" inside
        # "ssh.github.com" and derived "443/owner".
        Get-RepoFromOriginUrl 'ssh://git@ssh.github.com:443/owner/name.git' | Should -Be 'owner/name'
    }
    It 'reads an explicit port on https' {
        Get-RepoFromOriginUrl 'https://github.com:443/owner/name.git' | Should -Be 'owner/name'
    }
    It 'tolerates a trailing slash' {
        Get-RepoFromOriginUrl 'https://github.com/owner/name/' | Should -Be 'owner/name'
    }
    It 'tolerates a user/token prefix without leaking it into the result' {
        Get-RepoFromOriginUrl 'https://ghp_secret@github.com/owner/name.git' | Should -Be 'owner/name'
    }

    Context 'the #281 bug: a dot in the repo name' {
        # The whole point. Each of these returned a truncated name before.
        It 'keeps a .com in the repo name' {
            Get-RepoFromOriginUrl 'https://github.com/owner/midominio.com.git' | Should -Be 'owner/midominio.com'
        }
        It 'keeps several dots in the repo name' {
            Get-RepoFromOriginUrl 'https://github.com/owner/docs.example.org.git' | Should -Be 'owner/docs.example.org'
        }
        It 'keeps a dot when there is no .git suffix to strip' {
            Get-RepoFromOriginUrl 'https://github.com/owner/midominio.com' | Should -Be 'owner/midominio.com'
        }
        It 'keeps a dot over ssh too' {
            Get-RepoFromOriginUrl 'git@github.com:owner/midominio.com.git' | Should -Be 'owner/midominio.com'
        }
        It 'keeps a dot in the OWNER as well' {
            Get-RepoFromOriginUrl 'https://github.com/my.org/name.git' | Should -Be 'my.org/name'
        }
        It 'strips only the trailing .git, not a .git inside the name' {
            Get-RepoFromOriginUrl 'https://github.com/owner/not.github.io.git' | Should -Be 'owner/not.github.io'
        }
    }

    Context 'input it must refuse rather than guess' {
        It 'returns null for a non-github host' {
            Get-RepoFromOriginUrl 'https://gitlab.com/owner/name.git' | Should -BeNullOrEmpty
        }
        It 'returns null for empty input instead of throwing' {
            Get-RepoFromOriginUrl '' | Should -BeNullOrEmpty
        }
        It 'returns null for junk instead of throwing' {
            Get-RepoFromOriginUrl 'not a url at all' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-IssueNumberFromUrl (0 must mean failure, not success)' {
    It 'reads the number from an issue URL' {
        Get-IssueNumberFromUrl 'https://github.com/owner/name/issues/281' | Should -Be 281
    }
    It 'reads the number from a PR URL' {
        Get-IssueNumberFromUrl 'https://github.com/owner/name/pull/42' | Should -Be 42
    }
    It 'reads the number when the repo name contains a dot' {
        # The two bugs met here: derive midominio.com, then create an issue in it.
        Get-IssueNumberFromUrl 'https://github.com/owner/midominio.com/issues/7' | Should -Be 7
    }
    It 'tolerates a trailing newline from gh' {
        Get-IssueNumberFromUrl "https://github.com/owner/name/issues/9`n" | Should -Be 9
    }

    Context 'the #281 false OK: gh failed and printed nothing' {
        It 'returns 0 for empty output' {
            # `[int]('' )` was 0 too - but silently, which is how "OK #0" shipped.
            Get-IssueNumberFromUrl '' | Should -Be 0
        }
        It 'returns 0 for null output' {
            Get-IssueNumberFromUrl $null | Should -Be 0
        }
        It 'returns 0 for an error message rather than digging a number out of it' {
            Get-IssueNumberFromUrl 'GraphQL: Could not resolve to a Repository with the name 404' | Should -Be 0
        }
        It 'returns 0 for a URL that is not an issue or PR' {
            Get-IssueNumberFromUrl 'https://github.com/owner/name' | Should -Be 0
        }
    }
}

Describe 'the broken pattern is gone from every script (#281)' {
    It 'no script inlines the dot-eating regex any more' {
        # The bug was duplication: fixed in 3 of 11 copies, left broken in 8. If this fails,
        # someone pasted it back instead of dot-sourcing the resolver.
        $scripts = Get-ChildItem (Join-Path $PSScriptRoot '..' 'scripts') -Filter '*.ps1' -File |
                   Where-Object { $_.Name -ne 'Get-RepoFromOrigin.ps1' }   # it documents the bug in a comment
        $offenders = @($scripts | Where-Object { (Get-Content $_.FullName -Raw) -match '\[\^/\.\]\+' })
        $offenders.Name | Should -BeNullOrEmpty
    }
}

Describe 'every origin-deriving script uses the shared helper (#392)' {
    # Any script that calls `git remote get-url origin` for repo derivation MUST dot-source the
    # shared resolver. Having its own inline derivation — even a "correct" one — is a divergence
    # risk: the next URL format that Get-RepoFromOriginUrl learns (e.g. ssh.github.com:443) won't
    # reach that script, and the next bug in its ad-hoc regex won't be caught by the shared tests.
    #
    # Heuristic: if a script mentions `git remote get-url origin` but does NOT source the helper,
    # it has its own derivation. Board-Work.ps1 is the only allowed exception: it reads the remote
    # for VERIFICATION (does the URL contain the already-known owner/name?), not derivation — and
    # it already dot-sources the helper anyway, so the check still passes for it.
    It 'every script that reads git remote get-url origin dot-sources Get-RepoFromOrigin.ps1' {
        $helper = 'Get-RepoFromOrigin.ps1'
        $scripts = Get-ChildItem (Join-Path $PSScriptRoot '..' 'scripts') -Filter '*.ps1' -File |
                   Where-Object { $_.Name -ne $helper }
        $offenders = @($scripts | Where-Object {
            $content = Get-Content $_.FullName -Raw
            ($content -match 'git remote get-url origin') -and
            ($content -notmatch [regex]::Escape($helper))
        })
        $offenders.Name | Should -BeNullOrEmpty
    }
}
