<#  Get-AbiosAccounts.ps1 - the user's account map and a cross-platform token reader (#762, #767).

    WHY. The plugin used to ship ONE author's accounts in code: a default owner, a second business
    account, their account IDs and the env var that holds each token. Anyone else who installed it
    got those defaults, a Windows-only registry read, and a failure on the first board operation.
    The map now lives in a per-user file that `/board setup` writes, and nothing account-specific
    ships in the plugin.

    FILE. $env:ABIOS_ACCOUNTS_FILE when set (tests), else ~/.agentic-board/accounts.json:

        {
          "defaultOwner":  "your-login",              // optional; else the login `gh` is signed in as
          "owners":        { "your-login": "GITHUB_TOKEN_PERSONAL", "work-org": "GITHUB_TOKEN_WORK" },
          "accountIds":    { "12345": "GITHUB_TOKEN_PERSONAL" },   // optional, survives renames
          "aliases":       { "me": "your-login", "work": "work-org" },
          "agentTokenVar": "GITHUB_TOKEN_AGENT"       // optional; the identity of brake-armed runs
        }

    Values are env var NAMES, never tokens. A missing or unreadable file is an empty map, not an
    error: with no map, every owner resolves to the ambient token (GH_TOKEN, then `gh auth token`).

    TOKEN ORDER (Get-AbiosTokenValue). For a named variable: the Windows USER scope first (the
    session copy can be stale on Windows), then the process environment. With -AllowAmbient, and
    only then, it falls back to GH_TOKEN and finally `gh auth token`. The agent identity never
    uses the ambient fallback: a brake-armed run with no agent token must stop, not continue as you.

    Function definitions only; safe to dot-source (no gh call, no output at load).  #>

function Get-AbiosAccountsPath {
    if ($env:ABIOS_ACCOUNTS_FILE) { return $env:ABIOS_ACCOUNTS_FILE }
    $home_ = if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path (Join-Path $home_ '.agentic-board') 'accounts.json')
}

# Turn a parsed JSON object (or $null) into a plain hashtable of strings. Pure.
function ConvertTo-AbiosStringMap([object]$Node) {
    $map = @{}
    if ($null -eq $Node) { return $map }
    foreach ($p in $Node.PSObject.Properties) {
        $k = "$($p.Name)".Trim(); $v = "$($p.Value)".Trim()
        if ($k -and $v) { $map[$k] = $v }
    }
    return $map
}

# The account config as a normalized object. Never throws: a broken file reads as empty, with the
# parse problem in .error so a caller (doctor, setup -Show) can say so.
function Get-AbiosAccountConfig {
    param([string]$Path = (Get-AbiosAccountsPath))
    $cfg = [pscustomobject]@{
        path = $Path; exists = $false; error = ''
        defaultOwner = ''; owners = @{}; accountIds = @{}; aliases = @{}; agentTokenVar = 'GITHUB_TOKEN_AGENT'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    $cfg.exists = $true
    try {
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $cfg.error = "could not read $Path - $($_.Exception.Message)"
        return $cfg
    }
    if ($j.PSObject.Properties['defaultOwner'] -and $j.defaultOwner) { $cfg.defaultOwner = "$($j.defaultOwner)".Trim() }
    if ($j.PSObject.Properties['owners'])     { $cfg.owners     = ConvertTo-AbiosStringMap $j.owners }
    if ($j.PSObject.Properties['accountIds']) { $cfg.accountIds = ConvertTo-AbiosStringMap $j.accountIds }
    if ($j.PSObject.Properties['aliases'])    { $cfg.aliases    = ConvertTo-AbiosStringMap $j.aliases }
    if ($j.PSObject.Properties['agentTokenVar'] -and $j.agentTokenVar) { $cfg.agentTokenVar = "$($j.agentTokenVar)".Trim() }
    # Only plain env var identifiers survive: these names are interpolated into scripts and lookups.
    foreach ($m in @($cfg.owners, $cfg.accountIds)) {
        foreach ($k in @($m.Keys)) { if ($m[$k] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $m.Remove($k) } }
    }
    if ($cfg.agentTokenVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $cfg.agentTokenVar = 'GITHUB_TOKEN_AGENT' }
    return $cfg
}

# Read one named variable: Windows USER scope first, then the process. '' when unset.
function Get-AbiosEnvValue {
    param([string]$VarName)
    if (-not $VarName) { return '' }
    $v = ''
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { $v = [Environment]::GetEnvironmentVariable($VarName, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($VarName) }
    return "$v"
}

# The token `gh` itself is signed in with ('' when gh is missing or signed out). Seam for tests.
function Get-AbiosGhAuthToken {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return '' }
    try { $t = (& gh auth token 2>$null | Out-String).Trim() } catch { $t = '' }
    if ($LASTEXITCODE -ne 0) { return '' }
    return $t
}

<#  The token for a named variable. -AllowAmbient adds GH_TOKEN, then `gh auth token`, as the last
    resort; leave it off for the agent identity, which must fail closed.  #>
function Get-AbiosTokenValue {
    param([string]$VarName, [switch]$AllowAmbient)
    $v = Get-AbiosEnvValue -VarName $VarName
    if ($v -or -not $AllowAmbient) { return $v }
    if ($VarName -ne 'GH_TOKEN' -and $env:GH_TOKEN) { return "$env:GH_TOKEN" }
    return (Get-AbiosGhAuthToken)
}

# The board owner to use when the caller named none: the configured default, else the login `gh`
# is signed in as, else ''. Calls gh only when there is no configured default.
function Get-AbiosDefaultOwner {
    param([object]$Config = (Get-AbiosAccountConfig))
    if ($Config.defaultOwner) { return $Config.defaultOwner }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return '' }
    try { $login = (& gh api user --jq .login 2>$null | Out-String).Trim() } catch { $login = '' }
    if ($LASTEXITCODE -ne 0) { return '' }
    if ($login -match '^[A-Za-z0-9][A-Za-z0-9-]*$') { return $login }
    return ''
}
