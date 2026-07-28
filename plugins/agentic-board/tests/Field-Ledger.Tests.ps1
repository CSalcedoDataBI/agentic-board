#Requires -Modules Pester
<#  Tests for Get-FieldLedger.ps1 — the incremental watermark behind /board field.

    The pure core loads behind $env:ABIOS_FIELDLEDGER_DOTSOURCE (same convention as the other
    Expert-*/Bpa-* scripts). These pin the property this whole feature rests on: a session is
    re-read only from where the last scan stopped, and a session that did not change is skipped
    entirely. Both directions are asserted — skipping too much and skipping too little are equally
    broken. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-FieldLedger.ps1' | Resolve-Path
    $env:ABIOS_FIELDLEDGER_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FIELDLEDGER_DOTSOURCE = ''

    function New-Row {
        param($Id, $Events, $Bytes, $Project = 'proj')
        [pscustomobject]@{
            sessionId = $Id; project = $Project; title = 't'
            events = $Events; bytes = $Bytes
            scannedAt = '2026-07-28T00:00:00Z'; usedTool = 'yes'; incidents = 0
        }
    }
    function New-Disk {
        param($Id, $Events, $Bytes, $Project = 'proj')
        [pscustomobject]@{ sessionId = $Id; project = $Project; events = $Events; bytes = $Bytes }
    }
}

Describe 'Select-SessionsToScan (the watermark)' {

    It 'selects a session that has never been scanned' {
        $r = Select-SessionsToScan -Disk @(New-Disk 's1' 100 5000) -Ledger @()
        @($r).Count | Should -Be 1
        $r[0].sessionId | Should -Be 's1'
        $r[0].fromEvent  | Should -Be 0
    }

    It 'skips a session whose event count and size are unchanged' {
        $r = Select-SessionsToScan -Disk @(New-Disk 's1' 100 5000) -Ledger @(New-Row 's1' 100 5000)
        @($r).Count | Should -Be 0
    }

    It 'reselects a grown session and resumes from the watermark, not from zero' {
        # This is the case a boolean `scanned` flag loses forever.
        $r = Select-SessionsToScan -Disk @(New-Disk 's1' 400 9000) -Ledger @(New-Row 's1' 100 5000)
        @($r).Count | Should -Be 1
        $r[0].fromEvent | Should -Be 100
    }

    It 'rereads from zero when the file shrank (rotated or rewritten - the watermark is void)' {
        $r = Select-SessionsToScan -Disk @(New-Disk 's1' 50 900) -Ledger @(New-Row 's1' 100 5000)
        @($r).Count | Should -Be 1
        $r[0].fromEvent | Should -Be 0
    }

    It 'reselects when the event count held but the byte size moved (edited in place)' {
        $r = Select-SessionsToScan -Disk @(New-Disk 's1' 100 7777) -Ledger @(New-Row 's1' 100 5000)
        @($r).Count | Should -Be 1
    }

    It 'keeps sessions apart across projects that reuse an id' {
        $disk   = @((New-Disk 's1' 100 5000 'projA'), (New-Disk 's1' 100 5000 'projB'))
        $ledger = @(New-Row 's1' 100 5000 'projA')
        $r = Select-SessionsToScan -Disk $disk -Ledger $ledger
        @($r).Count | Should -Be 1
        $r[0].project | Should -Be 'projB'
    }

    It 'is idempotent: a second pass over the updated ledger selects nothing' {
        $disk = @(New-Disk 's1' 400 9000)
        $first = Select-SessionsToScan -Disk $disk -Ledger @()
        @($first).Count | Should -Be 1
        $updated = @(New-Row 's1' 400 9000)
        @(Select-SessionsToScan -Disk $disk -Ledger $updated).Count | Should -Be 0
    }
}

Describe 'Update-LedgerRow (the watermark only advances on real work)' {

    It 'advances the watermark to the counts actually processed' {
        $row = Update-LedgerRow -Ledger @(New-Row 's1' 100 5000) -SessionId 's1' -Project 'proj' `
                                -Events 400 -Bytes 9000 -Incidents 2 -UsedTool 'yes' -ScannedAt '2026-07-28T10:00:00Z'
        $hit = @($row | Where-Object { $_.sessionId -eq 's1' })
        $hit.Count      | Should -Be 1
        $hit[0].events  | Should -Be 400
        $hit[0].bytes   | Should -Be 9000
        $hit[0].incidents | Should -Be 2
    }

    It 'appends a row for a session the ledger has never seen' {
        $row = Update-LedgerRow -Ledger @() -SessionId 'new' -Project 'proj' `
                                -Events 10 -Bytes 20 -Incidents 0 -UsedTool 'no' -ScannedAt '2026-07-28T10:00:00Z'
        @($row).Count | Should -Be 1
        $row[0].sessionId | Should -Be 'new'
    }

    It 'never drops rows belonging to other sessions' {
        $row = Update-LedgerRow -Ledger @((New-Row 'a' 1 1), (New-Row 'b' 2 2)) -SessionId 'a' -Project 'proj' `
                                -Events 9 -Bytes 9 -Incidents 0 -UsedTool 'yes' -ScannedAt '2026-07-28T10:00:00Z'
        @($row).Count | Should -Be 2
        @($row | Where-Object { $_.sessionId -eq 'b' })[0].events | Should -Be 2
    }
}

Describe 'Safety: the scanner is read-only over the transcript store' {

    It 'declares no write path into the transcript root' {
        # The evidence is the only copy; a bug that writes there is unrecoverable.
        $src = Get-Content -Raw $script:Script
        $writes = [regex]::Matches($src, '(?im)^\s*(Set-Content|Out-File|Remove-Item|New-Item|Move-Item|Add-Content)\b')
        foreach ($m in $writes) {
            $line = ($src.Substring(0, $m.Index) -split "`n").Count
            $ctx  = ($src -split "`n")[$line - 1]
            $ctx | Should -Not -Match 'ProjectsRoot|projects'
        }
    }
}
