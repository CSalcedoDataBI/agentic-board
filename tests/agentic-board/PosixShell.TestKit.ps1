<#  Puts a POSIX `sh` on PATH for the tests that drive the companion plugin's .sh shims (#768).
    Linux and macOS have one already. On Windows, `sh` ships with Git for Windows under usr/bin, which a
    plain pwsh session does not have on PATH: this finds it next to git. When no `sh` exists at all, the
    shim tests fail with "sh is not recognized" - install Git for Windows.  #>
function Use-PosixShell {
    if (Get-Command sh -ErrorAction SilentlyContinue) { return }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return }
    $dir = Split-Path $git.Source -Parent
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
        $bin = Join-Path $dir 'usr' 'bin'
        if (Test-Path -LiteralPath (Join-Path $bin 'sh.exe')) {
            $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
            return
        }
        $dir = Split-Path $dir -Parent
    }
}