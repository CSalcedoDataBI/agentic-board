#Requires -Modules Pester
<#  Pester tests for Get-AbiosStateDir.ps1 — the single internal state-dir resolver.

    Covers the rename hardening (#244): the new name going forward, the one-time
    silent migration of an existing pre-rebrand `.agentic-bi-ops/`, and the fallback
    that never loses state. Uses -Root (a temp dir) so no git repo is needed. #>

BeforeAll {
    $script:Helper = Join-Path $PSScriptRoot '..' 'scripts' 'Get-AbiosStateDir.ps1' | Resolve-Path
    . $script:Helper

    function New-TempRoot {
        $r = Join-Path ([System.IO.Path]::GetTempPath()) ("statedir-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $r -Force | Out-Null
        $r
    }
}

Describe 'Get-AbiosStateDir' {
    It 'creates and returns the NEW name when nothing exists yet' {
        $root = New-TempRoot
        try {
            $dir = Get-AbiosStateDir -Root $root
            $dir | Should -Be (Join-Path $root '.agentic-board')
            Test-Path $dir | Should -BeTrue
        } finally { Remove-Item $root -Recurse -Force }
    }

    It 'migrates an existing .agentic-bi-ops/ to .agentic-board/ preserving its contents' {
        $root = New-TempRoot
        try {
            $old = Join-Path $root '.agentic-bi-ops'
            New-Item -ItemType Directory -Path $old -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $old 'sessions.json') -Value '[{"pid":1}]' -Encoding utf8

            $dir = Get-AbiosStateDir -Root $root

            $dir | Should -Be (Join-Path $root '.agentic-board')
            Test-Path $old | Should -BeFalse                       # old dir is gone (renamed)
            $migrated = Join-Path $dir 'sessions.json'
            Test-Path $migrated | Should -BeTrue                   # state carried over
            Get-Content $migrated -Raw | Should -Match 'pid'
        } finally { Remove-Item $root -Recurse -Force }
    }

    It 'prefers the new name and leaves the old one untouched when BOTH exist' {
        $root = New-TempRoot
        try {
            $old = Join-Path $root '.agentic-bi-ops'
            $new = Join-Path $root '.agentic-board'
            New-Item -ItemType Directory -Path $old -Force | Out-Null
            New-Item -ItemType Directory -Path $new -Force | Out-Null

            $dir = Get-AbiosStateDir -Root $root

            $dir | Should -Be $new
            Test-Path $old | Should -BeTrue                        # not migrated over an existing new dir
        } finally { Remove-Item $root -Recurse -Force }
    }

    It 'does not create a fresh dir under -NoCreate when neither name exists' {
        $root = New-TempRoot
        try {
            $dir = Get-AbiosStateDir -Root $root -NoCreate
            $dir | Should -Be (Join-Path $root '.agentic-board')
            Test-Path $dir | Should -BeFalse                       # path returned, but nothing created
        } finally { Remove-Item $root -Recurse -Force }
    }

    It 'still migrates an existing old dir even under -NoCreate' {
        $root = New-TempRoot
        try {
            $old = Join-Path $root '.agentic-bi-ops'
            New-Item -ItemType Directory -Path $old -Force | Out-Null

            $dir = Get-AbiosStateDir -Root $root -NoCreate

            $dir | Should -Be (Join-Path $root '.agentic-board')
            Test-Path $old | Should -BeFalse
            Test-Path $dir | Should -BeTrue                        # moving real state is always safe
        } finally { Remove-Item $root -Recurse -Force }
    }

    It 'returns the NEW dir (not the vanished old one) when a concurrent session won the migration' {
        # Race: two sessions see only .agentic-bi-ops; the other one renames it to
        # .agentic-board first, so OUR Rename-Item throws. We must return the new dir,
        # never the old path (which no longer exists) — else write callers resurrect a
        # split brain. Simulate by making Rename-Item create the new dir and throw.
        $root = New-TempRoot
        try {
            $old = Join-Path $root '.agentic-bi-ops'
            $new = Join-Path $root '.agentic-board'
            New-Item -ItemType Directory -Path $old -Force | Out-Null

            Mock Rename-Item -MockWith {
                New-Item -ItemType Directory -Path $new -Force | Out-Null  # the winner's rename
                Remove-Item $old -Recurse -Force                          # old moved out from under us
                throw 'target already exists'
            }

            $dir = Get-AbiosStateDir -Root $root
            $dir | Should -Be $new
            Test-Path $new | Should -BeTrue
        } finally { Remove-Item $root -Recurse -Force }
    }
}
