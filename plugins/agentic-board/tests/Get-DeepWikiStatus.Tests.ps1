#Requires -Modules Pester
<#  Tests for Get-DeepWikiStatus.ps1 (#416).

    Pure helpers (Get-DeepWikiUrl, Resolve-DeepWikiIndex) are dot-sourced and tested
    without any network or gh calls. Live path tests use the -Override* parameters to
    inject privacy flags and HTTP responses.
#>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-DeepWikiStatus.ps1'

    # Dot-source to load only the pure helpers (the dot-source guard blocks live path)
    $env:ABIOS_DOTSOURCE_GUARD = '1'
    . $script:Script
    $env:ABIOS_DOTSOURCE_GUARD = $null
}

Describe 'Get-DeepWikiStatus — Get-DeepWikiUrl (pure)' {
    It 'builds the correct DeepWiki URL for a repo' {
        Get-DeepWikiUrl -Repo 'owner/name' | Should -Be 'https://deepwiki.com/owner/name'
    }

    It 'preserves owner and name exactly (case-sensitive)' {
        Get-DeepWikiUrl -Repo 'CSalcedoDataBI/agentic-board' |
            Should -Be 'https://deepwiki.com/CSalcedoDataBI/agentic-board'
    }
}

Describe 'Get-DeepWikiStatus — Resolve-DeepWikiIndex (pure)' {
    It 'returns unknown when HttpStatus is 0 (no response)' {
        Resolve-DeepWikiIndex -HttpStatus 0 -HttpBody '' | Should -Be 'unknown'
    }

    It 'returns unknown for non-200 status codes' {
        Resolve-DeepWikiIndex -HttpStatus 404 -HttpBody '' | Should -Be 'unknown'
        Resolve-DeepWikiIndex -HttpStatus 500 -HttpBody '' | Should -Be 'unknown'
    }

    It 'returns indexed for a 200 response with no not-indexed markers' {
        $body = '<html><body><h1>Wiki for owner/repo</h1><p>Overview</p></body></html>'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'indexed'
    }

    It 'returns not-indexed when body contains start-index marker' {
        $body = '<html><body><button>Start indexing this repository</button></body></html>'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'returns not-indexed when body contains index-this-repo marker' {
        $body = '<p>Index this repository to generate the wiki.</p>'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'returns not-indexed when body contains not-indexed marker' {
        $body = 'This repository is not indexed yet.'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'returns not-indexed when body contains generate-wiki marker' {
        $body = 'Generate wiki for this project.'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'returns not-indexed when body contains add-to-wiki marker' {
        $body = 'Add this repo to wiki now.'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'is case-insensitive for not-indexed markers' {
        $body = 'START INDEXING THIS REPOSITORY'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'not-indexed'
    }

    It 'returns indexed for a 200 response that happens to mention index but in wiki context' {
        # A wiki page describing how an "index" data structure works should NOT be flagged
        $body = '<html><h2>Index structures in the codebase</h2><p>The B-tree index is used for fast lookups.</p></html>'
        Resolve-DeepWikiIndex -HttpStatus 200 -HttpBody $body | Should -Be 'indexed'
    }
}

Describe 'Get-DeepWikiStatus — live path with injected overrides' {
    It 'reports private status when OverrideIsPrivate is true' {
        $result = & $script:Script -Repo 'owner/private-repo' -OverrideIsPrivate $true -Json |
            ConvertFrom-Json
        $result.status    | Should -Be 'private'
        $result.isPrivate | Should -Be $true
        $result.url       | Should -Be 'https://deepwiki.com/owner/private-repo'
    }

    It 'private status message mentions public repos and Devin' {
        $result = & $script:Script -Repo 'owner/private-repo' -OverrideIsPrivate $true -Json |
            ConvertFrom-Json
        $result.message | Should -Match '(?i)(public|devin)'
    }

    It 'reports indexed when HTTP 200 and body has no not-indexed markers' {
        $body = '<html><h1>Architecture</h1><p>The project uses a plugin-based design.</p></html>'
        $result = & $script:Script -Repo 'owner/public-repo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 200 -OverrideHttpBody $body -Json | ConvertFrom-Json
        $result.status    | Should -Be 'indexed'
        $result.isPrivate | Should -Be $false
        $result.url       | Should -Be 'https://deepwiki.com/owner/public-repo'
    }

    It 'reports not-indexed when HTTP 200 and body has not-indexed markers' {
        $body = '<button>Start indexing this repository</button>'
        $result = & $script:Script -Repo 'owner/public-repo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 200 -OverrideHttpBody $body -Json | ConvertFrom-Json
        $result.status | Should -Be 'not-indexed'
    }

    It 'reports unknown when HTTP probe returns non-200' {
        $result = & $script:Script -Repo 'owner/public-repo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 404 -OverrideHttpBody '' -Json | ConvertFrom-Json
        $result.status | Should -Be 'unknown'
    }

    It 'reports unknown when HTTP probe returns 0 (no response)' {
        $result = & $script:Script -Repo 'owner/public-repo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 0 -OverrideHttpBody '' -Json | ConvertFrom-Json
        $result.status | Should -Be 'unknown'
    }

    It 'always includes PUBLIC REPOS ONLY notice in text output for public repos' {
        $body = '<html><h1>wiki content</h1></html>'
        $out = & $script:Script -Repo 'owner/public-repo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 200 -OverrideHttpBody $body | Out-String
        $out | Should -Match '(?i)public.repos.only'
    }

    It 'returns repo and url fields in JSON output' {
        $body = '<html><h1>wiki</h1></html>'
        $result = & $script:Script -Repo 'MyOrg/MyRepo' -OverrideIsPrivate $false `
            -OverrideHttpStatus 200 -OverrideHttpBody $body -Json | ConvertFrom-Json
        $result.repo | Should -Be 'MyOrg/MyRepo'
        $result.url  | Should -Be 'https://deepwiki.com/MyOrg/MyRepo'
    }
}
