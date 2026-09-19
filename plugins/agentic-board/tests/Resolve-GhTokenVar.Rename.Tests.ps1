#Requires -Modules Pester
<#  Tests for the rename-proof owner -> token resolution (#665).

    The failure this pins: a GitHub account was renamed, the owner login stopped matching the map,
    and the lookup fell back to the personal token WITHOUT SAYING SO. The user then saw "NO tiene
    permiso de push" - true and misleading at once, because the token and the account were fine and
    what was stale was a hardcoded login. It took three diagnoses to find.

    Two properties, both checked here:
      1. a renamed account is still matched (old logins as aliases; the numeric account ID for the
         NEXT rename), and
      2. an owner nobody can place is reported as an unmapped OWNER, naming it - never as a
         permissions problem - and never resolved to the wider BUSINESS token.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_TOKENVAR_DOTSOURCE = '1'
    . (Join-Path $script:ScriptDir 'Resolve-GhTokenVar.ps1')
    . (Join-Path $script:ScriptDir 'Invoke-Gh.ps1')
    $env:ABIOS_TOKENVAR_DOTSOURCE = $null
}

Describe 'the business account under every name it has had (#665)' {
    It 'maps the CURRENT login, PesanteAnalytics, to the business token' {
        (Resolve-GhTokenVar -IsArmed $false -Owner 'PesanteAnalytics').var | Should -Be 'GITHUB_TOKEN_BUSINESS'
    }
    It 'still maps the two previous logins - old clones keep the old owner in their remote' {
        (Resolve-GhTokenVar -IsArmed $false -Owner 'PAL-Devs').var      | Should -Be 'GITHUB_TOKEN_BUSINESS'
        (Resolve-GhTokenVar -IsArmed $false -Owner 'Support1-PAL').var  | Should -Be 'GITHUB_TOKEN_BUSINESS'
    }
    It 'treats logins case-insensitively, as GitHub does' {
        (Resolve-GhTokenVar -IsArmed $false -Owner 'pesanteanalytics').var | Should -Be 'GITHUB_TOKEN_BUSINESS'
        (Resolve-GhTokenVar -IsArmed $false -Owner 'csalcedodatabi').var   | Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'reports a login it knows as mapped by login' {
        $r = Resolve-OwnerTokenVar -Owner 'PesanteAnalytics'
        $r.mapped | Should -BeTrue
        $r.how    | Should -Be 'login'
    }
    It 'Get-OwnerTokenVar answers for the renamed account without any warning or lookup' {
        $out = @(Get-OwnerTokenVar -Owner 'PesanteAnalytics' -IdLookup { param($o) '' } 3>&1)
        $out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | Should -BeNullOrEmpty
        $out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] } | Should -Be 'GITHUB_TOKEN_BUSINESS'
    }
}

Describe 'an unmapped owner is reported as a MAP problem, not a permissions problem (#665)' {
    BeforeAll { $script:r = Resolve-GhTokenVar -IsArmed $false -Owner 'BrandNewName' }

    It 'flags it as not mapped' {
        $script:r.mapped | Should -BeFalse
        $script:r.fail   | Should -BeFalse
    }
    It 'names the owner, so the reader can see WHICH login the map missed' {
        $script:r.reason | Should -Match "'BrandNewName'"
    }
    It 'lists the logins the map does know' {
        $script:r.reason | Should -Match 'PesanteAnalytics'
        $script:r.reason | Should -Match 'CSalcedoDataBI'
    }
    It 'says it is falling back, and to WHICH token - never silently' {
        $script:r.reason | Should -Match 'GITHUB_TOKEN_PERSONAL'
        $script:r.reason | Should -Match 'por defecto'
    }
    It 'points at the map, and does not read as an access-rights problem' {
        $script:r.reason | Should -Match 'MAPA'
        $script:r.reason | Should -Match '-TokenVar'
        $script:r.reason | Should -Not -Match 'NO tiene permiso'
        $script:r.reason | Should -Not -Match 'fork'
    }
    It 'falls back to the PERSONAL token, never to the wider business one' {
        $script:r.var | Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'never resolves an unknown owner to BUSINESS, whatever it is called' {
        foreach ($o in @('x','PAL-Devs2','Support1','PesanteAnalytic','', $null)) {
            # Positive assertion: `$null | Should -Not -Be` would also pass if the call threw or returned nothing.
            (Resolve-OwnerTokenVar -Owner $o).var | Should -Be 'GITHUB_TOKEN_PERSONAL' -Because "'$o' is not the business account"
        }
    }
}

Describe 'Get-OwnerTokenVar - the string-returning door Board-Merge and Get-GhAccount use (#665)' {
    It 'warns, naming the owner, when it cannot place it - and still returns the personal variable' {
        $out = @(Get-OwnerTokenVar -Owner 'BrandNewName' -IdLookup { param($o) '' } 3>&1)
        $warn = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warn.Count | Should -Be 1
        $warn[0].Message | Should -Match "'BrandNewName'"
        @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0] | Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'follows a renamed account by its ID, with no warning' {
        $out = @(Get-OwnerTokenVar -Owner 'NextRename' -IdLookup { param($o) '248682413' } 3>&1)
        @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        $out[0] | Should -Be 'GITHUB_TOKEN_BUSINESS'
    }
}

Describe 'the account ID survives the NEXT rename (#665)' {
    It 'matches a login the map never heard of when its account ID is the business account' {
        $r = Resolve-OwnerTokenVar -Owner 'SomeFutureName' -IdLookup { param($o) '248682413' }
        $r.mapped | Should -BeTrue
        $r.how    | Should -Be 'account-id'
        $r.var    | Should -Be 'GITHUB_TOKEN_BUSINESS'
        $r.reason | Should -Match 'se renombro'
    }
    It 'matches a renamed personal account to the personal token' {
        (Resolve-OwnerTokenVar -Owner 'SomeFutureName' -IdLookup { param($o) '73630372' }).var |
            Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'stays unmapped when the ID belongs to nobody we know - and says the ID was checked' {
        $r = Resolve-OwnerTokenVar -Owner 'Stranger' -IdLookup { param($o) '999999' }
        $r.mapped | Should -BeFalse
        $r.var    | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.reason | Should -Match '999999'
    }
    It 'stays unmapped, and says so, when GitHub cannot be asked' {
        $r = Resolve-OwnerTokenVar -Owner 'Stranger' -IdLookup { param($o) '' }
        $r.mapped | Should -BeFalse
        $r.reason | Should -Match 'No se pudo consultar'
    }
    It 'a lookup that THROWS is an unmapped owner, not a crash' {
        $r = Resolve-OwnerTokenVar -Owner 'Stranger' -IdLookup { param($o) throw 'network down' }
        $r.mapped | Should -BeFalse
        $r.var    | Should -Be 'GITHUB_TOKEN_PERSONAL'
    }
    It 'does not ask GitHub about a login the map already knows' {
        $script:asked = 0
        $null = Resolve-OwnerTokenVar -Owner 'PesanteAnalytics' -IdLookup { param($o) $script:asked++; '' }
        $script:asked | Should -Be 0
    }
    It 'the ID table can only ever choose an OWNER variable, never the agent identity' {
        foreach ($id in @('73630372','248682413')) {
            $lookup = { param($o) $id }.GetNewClosure()
            (Resolve-OwnerTokenVar -Owner 'Anything' -IdLookup $lookup).var |
                Should -BeIn @('GITHUB_TOKEN_PERSONAL','GITHUB_TOKEN_BUSINESS')
        }
    }
}

Describe 'Get-OwnerAccountId drives the real gh wrapper (only the process seam is faked)' {
    It 'returns the numeric ID gh printed' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @('248682413'); ExitCode = 0; StdErr = '' } }
        Get-OwnerAccountId -Owner 'PesanteAnalytics' | Should -Be '248682413'
        Should -Invoke Invoke-GhRaw -Times 1 -ParameterFilter { $GhArgs -contains 'users/PesanteAnalytics' }
    }
    It 'returns nothing - not a guess - when gh fails (a released old login is a 404)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @(); ExitCode = 1; StdErr = 'gh: Not Found (HTTP 404)' } }
        Get-OwnerAccountId -Owner 'PAL-Devs' | Should -Be ''
    }
    It 'returns nothing when gh printed something that is not an ID' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @('{"message":"Not Found"}'); ExitCode = 0; StdErr = '' } }
        Get-OwnerAccountId -Owner 'Whoever' | Should -Be ''
    }
    It 'refuses a login that could alter the API path, without calling gh at all' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = @('1'); ExitCode = 0; StdErr = '' } }
        foreach ($bad in @('../orgs/x', 'a/b', 'a b', '-x', '')) {
            Get-OwnerAccountId -Owner $bad | Should -Be ''
        }
        Should -Invoke Invoke-GhRaw -Times 0
    }
}

Describe 'Get-GhTokenForContext - the path the push script takes' {
    BeforeAll {
        $script:plain = Join-Path ([System.IO.Path]::GetTempPath()) ('rename-plain-' + [guid]::NewGuid().ToString('N'))
        $script:braked = Join-Path ([System.IO.Path]::GetTempPath()) ('rename-braked-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:plain -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:braked '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:braked '.agentic-board' 'brake-armed.json') -Value '{}'
    }
    AfterAll {
        Remove-Item -LiteralPath $script:plain, $script:braked -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        # Runs the real function and splits its output stream (3>&1) into the answer and the warnings.
        function script:Invoke-Ctx {
            param([string]$StartDir, [string]$Owner, [scriptblock]$IdLookup)
            $all = @(Get-GhTokenForContext -StartDir $StartDir -Owner $Owner -IdLookup $IdLookup 3>&1)
            @{ ctx  = @($all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
               warn = (@($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                         ForEach-Object { $_.Message }) -join ' ') }
        }
        # Never touches the real registry: the token VALUE is faked, the decision code is real.
        Mock Get-GhTokenValue { "value-of-$VarName" }
    }

    It 'warns - naming the owner - and returns the personal token for an unmapped owner' {
        $r = script:Invoke-Ctx -StartDir $script:plain -Owner 'BrandNewName' -IdLookup { param($o) '' }
        $r.ctx.var    | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.ctx.mapped | Should -BeFalse
        $r.warn | Should -Match "'BrandNewName'"
        $r.warn | Should -Match 'MAPA'
    }
    It 'is silent for an owner it can place' {
        $r = script:Invoke-Ctx -StartDir $script:plain -Owner 'PesanteAnalytics' -IdLookup { param($o) '' }
        $r.ctx.var    | Should -Be 'GITHUB_TOKEN_BUSINESS'
        $r.ctx.mapped | Should -BeTrue
        $r.warn | Should -BeNullOrEmpty
    }
    It 'follows a renamed business account to the business token via its account ID' {
        $r = script:Invoke-Ctx -StartDir $script:plain -Owner 'NextRename' -IdLookup { param($o) '248682413' }
        $r.ctx.var | Should -Be 'GITHUB_TOKEN_BUSINESS'
        $r.warn    | Should -BeNullOrEmpty
    }
    It 'a braked run gets the agent identity and NEVER looks the owner up' {
        $script:looked = 0
        $r = script:Invoke-Ctx -StartDir $script:braked -Owner 'BrandNewName' -IdLookup { param($o) $script:looked++; '248682413' }
        $r.ctx.var | Should -Be 'GITHUB_TOKEN_AGENT'
        $script:looked | Should -Be 0 -Because 'an ID match must not be able to pull a braked run toward the business token'
        $r.warn | Should -BeNullOrEmpty
    }
    It 'a braked run without an agent token still FAILS - the rename work did not open a fallback' {
        Mock Get-GhTokenValue { if ($VarName -eq 'GITHUB_TOKEN_AGENT') { '' } else { "value-of-$VarName" } }
        { Get-GhTokenForContext -StartDir $script:braked -Owner 'PesanteAnalytics' -IdLookup { param($o) '248682413' } } |
            Should -Throw -ExpectedMessage '*FRENADO*'
    }
    It 'a braked run cannot name the business variable explicitly' {
        { Get-GhTokenForContext -StartDir $script:braked -Owner 'PesanteAnalytics' -ExplicitVar 'GITHUB_TOKEN_BUSINESS' } |
            Should -Throw -ExpectedMessage '*no esta permitido*'
    }
}

Describe 'one copy of the alias map, not two (#665)' {
    It 'resolves every historical and current alias to the CURRENT login' {
        Get-AccountForAlias -Alias 'csalcedo' | Should -Be 'CSalcedoDataBI'
        Get-AccountForAlias -Alias 'pesante'  | Should -Be 'PesanteAnalytics'
        Get-AccountForAlias -Alias 'pal-devs' | Should -Be 'PesanteAnalytics'
        Get-AccountForAlias -Alias 'nobody'   | Should -Be ''
    }
    It 'every current login an alias points at is in the owner map' {
        foreach ($a in (Get-KnownAccountAliases)) {
            (Resolve-OwnerTokenVar -Owner (Get-AccountForAlias -Alias $a)).mapped | Should -BeTrue -Because "alias '$a'"
        }
    }
    It 'Get-GhAccount.ps1 takes its aliases from the resolver and keeps no map of its own' {
        $src = Get-Content (Join-Path $script:ScriptDir 'Get-GhAccount.ps1') -Raw
        $src | Should -Match 'Get-AccountForAlias'
        $src | Should -Not -Match "'pal-devs'\s*=\s*'"
    }
    It "Get-GhAccount's -Account ValidateSet offers exactly the aliases the resolver knows" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ScriptDir 'Get-GhAccount.ps1'), [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Account' }
        $vs = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $offered = @($vs.PositionalArguments | ForEach-Object { $_.Value })
        ($offered | Sort-Object) | Should -Be ((Get-KnownAccountAliases) | Sort-Object)
    }
}
