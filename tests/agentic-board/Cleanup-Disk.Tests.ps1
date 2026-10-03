#Requires -Modules Pester
<#  Pester tests for Cleanup-Disk.ps1 - `/cleanup disk` (#737).

    One plan-first report of what fills the disk, and one --force that cleans only what is provably
    safe. The rule under test that matters most: an old compaction snapshot (a copy of a transcript)
    is deleted only when the ORIGINAL transcript still exists and still holds it - otherwise the
    snapshot may be the last copy and is kept. #>

BeforeAll {
    $env:ABIOS_DISK_DOTSOURCE = '1'
    try { . (Join-Path $PSScriptRoot '..' 'scripts' 'Cleanup-Disk.ps1' | Resolve-Path) }
    finally { $env:ABIOS_DISK_DOTSOURCE = '' }
    function script:Snap([string]$Sid = 's1', [long]$Bytes = 100, [string]$Head = 'AAA') {
        [pscustomobject]@{ SessionId = $Sid; Bytes = $Bytes; Head = $Head }
    }
    function script:Orig([bool]$Exists = $true, [long]$Bytes = 500, [string]$Head = 'AAA') {
        [pscustomobject]@{ Exists = $Exists; Bytes = $Bytes; Head = $Head }
    }
}

Describe 'Get-SnapshotVerdict - a snapshot is deleted only when the original still holds it' {
    It 'deletes a snapshot whose original transcript exists, starts the same and is at least as long' {
        $v = Get-SnapshotVerdict -Snapshot (script:Snap) -Original (script:Orig)
        $v.Delete | Should -BeTrue
        $v.Reason | Should -Match 'duplicate'
    }
    It 'keeps a snapshot whose original is gone - it may be the last copy' {
        $v = Get-SnapshotVerdict -Snapshot (script:Snap) -Original (script:Orig -Exists $false)
        $v.Delete | Should -BeFalse
        $v.Reason | Should -Match 'only copy|last copy'
    }
    It 'keeps a snapshot longer than the original - the original does not hold all of it' {
        (Get-SnapshotVerdict -Snapshot (script:Snap -Bytes 900) -Original (script:Orig -Bytes 500)).Delete | Should -BeFalse
    }
    It 'keeps a snapshot that does not start like the original - it is not a copy of it' {
        (Get-SnapshotVerdict -Snapshot (script:Snap -Head 'AAA') -Original (script:Orig -Head 'BBB')).Delete | Should -BeFalse
    }
    It 'keeps a snapshot whose session it could not read' {
        (Get-SnapshotVerdict -Snapshot (script:Snap -Sid '') -Original (script:Orig)).Delete | Should -BeFalse
    }
    It 'deletes a snapshot whose original was compressed into the transcript archive (and covers it)' {
        $v = Get-SnapshotVerdict -Snapshot (script:Snap -Bytes 100) -Original (script:Orig -Exists $false) -ArchivedBytes 500
        $v.Delete | Should -BeTrue
        $v.Reason | Should -Match 'archive'
    }
}

Describe 'Get-UnmanagedBigDirs - what is big but is not this tool''s to clean' {
    It 'lists big folders no component covers, and never the ones it manages' {
        $dirs = @(
            [pscustomobject]@{ Name = 'projects'; Bytes = 3GB }
            [pscustomobject]@{ Name = 'markitdown-venv'; Bytes = 400MB }
            [pscustomobject]@{ Name = 'plugins'; Bytes = 700MB }
            [pscustomobject]@{ Name = 'skills'; Bytes = 12MB }
        )
        $u = @(Get-UnmanagedBigDirs -Dirs $dirs -Managed @('projects', 'plugins', 'compact-snapshots') -MinBytes 100MB)
        $u.Name | Should -Be @('markitdown-venv')
    }
}
