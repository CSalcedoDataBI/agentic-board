#Requires -Modules Pester
<#  Integration coverage for the /tools catalog (#389).

    Exercises the resolver + view + installer together against the REAL shipped sources
    (knowledge/registry.json + presets/toolkits/*.json), so the wiring is guarded against
    regressions even though each unit is tested in isolation elsewhere. Installed-state is pinned
    to empty so the assertions do not depend on the machine's installed inventory.
#>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts'
    $script:Resolver = Join-Path $script:ScriptsDir 'Get-ToolsCatalog.ps1'
    $script:Show     = Join-Path $script:ScriptsDir 'Show-ToolsCatalog.ps1'
    $script:Install  = Join-Path $script:ScriptsDir 'Install-ToolFromCatalog.ps1'
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path   # holds knowledge/registry.json
    $script:PresetsDir = Join-Path $PSScriptRoot '..' 'presets' 'toolkits'

    $script:Pin = @{ Root = $script:RepoRoot; InstalledNames = @(); InstalledPlugins = @() }
    $script:Cat = & $script:Resolver @script:Pin

    # every install-method name declared across the shipped presets
    $script:PresetNames = @(
        Get-ChildItem -LiteralPath $script:PresetsDir -Filter '*.json' | ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).name
        }
    )
}

Describe 'ToolsCatalog integration — resolver over real data' {
    It 'resolves a non-empty catalog with unique ids' {
        @($script:Cat.items).Count | Should -BeGreaterThan 0
        $ids = @($script:Cat.items.id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count -Because 'no two catalog rows may share an id'
    }

    It 'exposes every preset as an installable item' {
        foreach ($n in $script:PresetNames) {
            ($script:Cat.items | Where-Object { $_.id -eq $n -and $_.installable }) |
                Should -Not -BeNullOrEmpty -Because "preset '$n' must appear as an installable catalog item"
        }
    }

    It 'merges skills-for-fabric (in registry AND the bi preset) into one installable both-source item' {
        $f = $script:Cat.items | Where-Object { $_.id -eq 'skills-for-fabric' }
        @($f).Count      | Should -Be 1
        $f.installable   | Should -BeTrue
        $f.source        | Should -Be 'both'
        $f.kind          | Should -Be 'plugin'
    }

    It 'keeps a Power BI Learn reference as a non-installable PowerBI item' {
        $r = $script:Cat.items | Where-Object { $_.id -eq 'kn_011' }
        $r.installable | Should -BeFalse
        $r.domain      | Should -Be 'PowerBI'
    }
}

Describe 'ToolsCatalog integration — view + installer over real data' {
    It 'browse renders domain groups and URLs' {
        $out = (& $script:Show @script:Pin) -join "`n"
        $out | Should -Match '## PowerBI'
        $out | Should -Match ([regex]::Escape('learn.microsoft.com'))
    }

    It 'install -Id -DryRun previews a real skill-clone without installing' {
        $realSkill = ($script:Cat.items | Where-Object { $_.kind -eq 'skill-clone' } | Select-Object -First 1).id
        $realSkill | Should -Not -BeNullOrEmpty
        $out = (& $script:Install -Id $realSkill @script:Pin -DryRun) -join "`n"
        $out | Should -Match 'WOULD'
    }

    It 'install --all -DryRun lists plugins separately and installs nothing' {
        $out = (& $script:Install -All @script:Pin -DryRun) -join "`n"
        $out | Should -Match 'plugin\(s\) to surface'
        $out | Should -Match 'preview'
    }
}
