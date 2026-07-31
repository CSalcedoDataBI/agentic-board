#Requires -Modules Pester
<#  Tests for Board-Merge.ps1 — specifically the end-to-end brake check (#536).

    THE DEFECT THESE EXIST FOR, because it is invisible in a normal reading:

    `Invoke-BrakeMergeCheck` dot-sources `Board-ReviewGate.ps1` to reuse its strict review parser.
    Dot-sourcing runs the sourced script's `param()` block IN THE CALLER'S SCOPE, and that block
    declares `[int]$PR = 0`. So halfway through the function `$PR` silently became 0, and the very
    next thing it did was ask CI about PR number 0:

        $chk = gh pr checks $PR --repo $Repo --json name,bucket 2>$null

    `gh pr checks 0` exits 1 with empty stdout, so `$tested` was ALWAYS false and the end-to-end
    mode could refuse but never allow. Verified against a real PR whose four checks all passed:
    the gate refused for "missing test evidence"; the identical inputs without the clobber were
    permitted.

    Nothing about that is visible in the function's logic - only in the ORDER of two statements.
    So the test is structural on purpose: it asserts the clobbered name is not read after the
    dot-source that clobbers it. A behavioural test would need the network and would not pin the
    cause. (Same failure family as the -DryRun incident: dot-sourcing clobbers your parameters.)  #>

BeforeAll {
    $script:MergePath = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Merge.ps1' | Resolve-Path
    $script:GatePath  = Join-Path $PSScriptRoot '..' 'scripts' 'Board-ReviewGate.ps1' | Resolve-Path

    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$script:MergePath", [ref]$tokens, [ref]$errors)
    $script:ParseErrors = $errors

    $script:BrakeFn = $script:Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                  $n.Name -eq 'Invoke-BrakeMergeCheck' }, $true) | Select-Object -First 1

    # Every dot-source inside the brake check, in source order.
    $script:DotSources = @()
    if ($script:BrakeFn) {
        $script:DotSources = @($script:BrakeFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      $n.InvocationOperator -eq 'Dot' }, $true) |
            Sort-Object { $_.Extent.StartOffset })
    }
}

Describe 'Board-Merge.ps1 parses and still has its brake check' {
    It 'has no parse errors' {
        $script:ParseErrors.Count | Should -Be 0
    }
    It 'defines Invoke-BrakeMergeCheck' {
        $script:BrakeFn | Should -Not -BeNullOrEmpty
    }
    It 'calls it before merging' {
        # Defined early, called after auth. If the call disappears the whole brake is prose again.
        $calls = $script:Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      "$($n.GetCommandName())" -eq 'Invoke-BrakeMergeCheck' }, $true)
        @($calls).Count | Should -BeGreaterThan 0
    }
}

Describe 'The review gate really does clobber $PR — the premise of the fix (#536)' {
    It 'declares a $PR parameter that a dot-source lands in the caller scope' {
        # If this ever stops being true the structural guard below becomes unnecessary rather
        # than wrong - but it must fail loudly here first, not silently pass there.
        $t = $null; $e = $null
        $gateAst = [System.Management.Automation.Language.Parser]::ParseFile(
            "$script:GatePath", [ref]$t, [ref]$e)
        $names = @($gateAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'PR'
    }

    It 'demonstrates the clobber concretely' {
        # Not a mock: dot-source the real gate inside a scope holding $PR and watch it reset.
        $probe = {
            $PR = 535
            $env:ABIOS_REVIEWGATE_DOTSOURCE = '1'
            . "$script:GatePath" -Repo 'o/r'
            $env:ABIOS_REVIEWGATE_DOTSOURCE = $null
            return $PR
        }
        (& $probe) | Should -Be 0 -Because 'this is exactly what silently disabled the tests condition'
    }
}

Describe 'Invoke-BrakeMergeCheck does not read a name the dot-source destroys (#536)' {
    It 'dot-sources at least one script inside the brake check' {
        @($script:DotSources).Count | Should -BeGreaterThan 0
    }

    It 'never reads $PR after the first dot-source' {
        # THE regression guard. Any read of $PR past that point is the defect returning, whatever
        # it is used for.
        $firstDot = @($script:DotSources)[0].Extent.StartOffset
        $late = @($script:BrakeFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                      $n.VariablePath.UserPath -eq 'PR' }, $true) |
            Where-Object { $_.Extent.StartOffset -gt $firstDot })

        $where = ($late | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
        @($late).Count | Should -Be 0 -Because "the review-gate dot-source resets `$PR to 0; found reads at $where"
    }

    It 'captures the PR number before any dot-source runs' {
        $firstDot = @($script:DotSources)[0].Extent.StartOffset
        $early = @($script:BrakeFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                      $n.VariablePath.UserPath -eq 'PR' }, $true) |
            Where-Object { $_.Extent.StartOffset -lt $firstDot })
        @($early).Count | Should -BeGreaterThan 0 -Because 'the real PR number has to be saved somewhere first'
    }

    It 'asks CI about a PR number, not about an empty variable' {
        # `gh pr checks` must receive the captured name. Guards the exact call that was broken.
        $ghChecks = @($script:BrakeFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      "$($n.Extent.Text)" -match '\bgh\s+pr\s+checks\b' }, $true))
        @($ghChecks).Count | Should -BeGreaterThan 0
        foreach ($c in $ghChecks) {
            $c.Extent.Text | Should -Not -Match '\bgh\s+pr\s+checks\s+\$PR\b'
        }
    }
}

Describe 'The tests requirement is taken from the contract, not hardcoded (#536)' {
    It 'passes -TestsRequired when deciding' {
        # Test-EndToEndAllowed documents that this comes from the contract's dod.tests. It was
        # never passed, so it defaulted to $true and the contract was ignored.
        $call = @($script:BrakeFn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      "$($n.GetCommandName())" -eq 'Test-EndToEndAllowed' }, $true) |
            Select-Object -First 1)
        $call | Should -Not -BeNullOrEmpty
        $call.Extent.Text | Should -Match '-TestsRequired'
    }
}
