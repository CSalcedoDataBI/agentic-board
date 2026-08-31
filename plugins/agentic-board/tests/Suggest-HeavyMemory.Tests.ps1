#Requires -Modules Pester
<#  Pester tests for Suggest-HeavyMemory.ps1 - the security-gated heavy-memory escalation.

    The script hits PyPI and can install, so it exposes a dot-source guard: with
    $env:ABIOS_HEAVYMEM_DOTSOURCE set it returns after defining the pure helpers, without
    any network call or install. These tests exercise only those helpers. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Suggest-HeavyMemory.ps1' | Resolve-Path
    $env:ABIOS_HEAVYMEM_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HEAVYMEM_DOTSOURCE = ''
}

Describe 'Test-BasicMemoryProvenance' {
    It 'accepts the canonical package and detects AGPL from the license field' {
        $p = Test-BasicMemoryProvenance ([pscustomobject]@{ name='basic-memory'; version='0.13.2'; license='AGPL-3.0'; classifiers=@() })
        $p.nameOk  | Should -BeTrue
        $p.isAgpl  | Should -BeTrue
        $p.version | Should -Be '0.13.2'
    }
    It 'detects AGPL from classifiers when the license field is empty' {
        $p = Test-BasicMemoryProvenance ([pscustomobject]@{ name='basic-memory'; version='1.0.0'; license=''; classifiers=@('License :: OSI Approved :: GNU Affero General Public License v3 or later (AGPLv3+)') })
        $p.isAgpl | Should -BeTrue
    }
    It 'flags a typosquat name (nameOk = false)' {
        $p = Test-BasicMemoryProvenance ([pscustomobject]@{ name='basicmemory'; version='9.9.9'; license='MIT'; classifiers=@() })
        $p.nameOk | Should -BeFalse
        $p.isAgpl | Should -BeFalse
    }
    It 'never throws on a null info object' {
        { Test-BasicMemoryProvenance $null } | Should -Not -Throw
    }
}

Describe 'Get-HeavyMemoryInstallInvocation (explicit args, no quotes-as-literals)' {
    It 'uv: exe + args with the pinned spec unquoted (so the tool gets a clean package name)' {
        $inv = Get-HeavyMemoryInstallInvocation '0.13.2'
        $inv.exe | Should -Be 'uv'
        $inv.args | Should -Be @('tool', 'install', 'basic-memory==0.13.2')
        ($inv.args -join '') | Should -Not -Match '"'
    }
    It 'pipx: exe + args' {
        $inv = Get-HeavyMemoryInstallInvocation '0.13.2' 'pipx'
        $inv.exe | Should -Be 'pipx'
        $inv.args | Should -Be @('install', 'basic-memory==0.13.2')
    }
    It 'returns null when no version is given (refuse to build a floating install)' {
        Get-HeavyMemoryInstallInvocation '' | Should -Be $null
    }
}

Describe 'Get-HeavyMemoryInstallCommand (display, pinned)' {
    It 'quotes the spec for display only' {
        Get-HeavyMemoryInstallCommand '0.13.2' | Should -BeExactly 'uv tool install "basic-memory==0.13.2"'
    }
}

Describe 'New-BasicMemoryMcpEntry (matches the manager)' {
    It 'uv default: runs the PINNED version via uvx' {
        $e = New-BasicMemoryMcpEntry '0.13.2'
        $e.command | Should -Be 'uvx'
        ($e.args -join ' ') | Should -Match 'basic-memory==0.13.2'
        $e.args | Should -Contain 'mcp'
    }
    It 'pipx: runs via "pipx run --spec" so the entry matches a pipx install' {
        $e = New-BasicMemoryMcpEntry '0.13.2' 'pipx'
        $e.command | Should -Be 'pipx'
        $e.args | Should -Contain 'run'
        $e.args | Should -Contain '--spec'
        ($e.args -join ' ') | Should -Match 'basic-memory==0.13.2'
    }
}

Describe 'Add-McpServerEntry (idempotent upsert)' {
    It 'adds the server to an empty body' {
        $json = Add-McpServerEntry '' 'basic-memory' (New-BasicMemoryMcpEntry '1.0.0')
        $obj = $json | ConvertFrom-Json
        $obj.mcpServers.'basic-memory'.command | Should -Be 'uvx'
    }
    It 'preserves an existing unrelated server and replaces the same key without duplicating' {
        $start = '{"mcpServers":{"other":{"command":"foo"}}}'
        $json1 = Add-McpServerEntry $start 'basic-memory' (New-BasicMemoryMcpEntry '1.0.0')
        $json2 = Add-McpServerEntry $json1 'basic-memory' (New-BasicMemoryMcpEntry '2.0.0')
        $obj = $json2 | ConvertFrom-Json
        $obj.mcpServers.other.command | Should -Be 'foo'
        ($obj.mcpServers.'basic-memory'.args -join ' ') | Should -Match '2.0.0'
        ($obj.mcpServers.'basic-memory'.args -join ' ') | Should -Not -Match '1.0.0'
    }
}
