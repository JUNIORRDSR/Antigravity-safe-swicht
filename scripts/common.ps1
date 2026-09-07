# common.ps1 - shared primitives for agy-auto-switch.
# Never handles credential material. See credential-manager.ps1 for that.

Set-StrictMode -Version 2.0

$script:AgyAutoPluginRoot = Split-Path -Parent $PSScriptRoot
$script:AgyAutoDataRoot   = Join-Path $env:LOCALAPPDATA 'agy-auto-switch'

function Get-AgyAutoPluginRoot { $script:AgyAutoPluginRoot }
function Get-AgyAutoDataRoot   { $script:AgyAutoDataRoot }
function Get-AgyAutoPath([string]$Leaf) { Join-Path $script:AgyAutoDataRoot $Leaf }

# StrictMode 2.0 throws when you enumerate .Name over an EMPTY property
# collection, which happens for a freshly created object with no profiles yet.
function Get-AgyAutoPropertyNames {
    param([AllowNull()]$Object)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Object) { foreach ($p in $Object.PSObject.Properties) { $names.Add($p.Name) } }
    # Emitted plainly: an empty result becomes $null on the caller side, which
    # Get-AgyAutoCount and @() both handle. Returning it with -NoEnumerate would
    # nest the array whenever a caller writes @(Get-AgyAutoPropertyNames ...).
    $names.ToArray()
}

# @($null).Count throws under StrictMode 2.0, and an empty array assigned from
# an if/else block unrolls to $null - so counting is never safe inline.
function Get-AgyAutoCount {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 0 }
    @($Value).Count
}

function Initialize-AgyAutoDirs {
    foreach ($d in 'events', 'logs', 'handoffs', 'bin', 'checkpoints') {
        $p = Get-AgyAutoPath $d
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
}

# ---------------------------------------------------------------- redaction --

# Defensive: applied to every string that reaches a log or an event file.
$script:RedactPatterns = @(
    '(?i)\b(refresh_token|access_token|id_token|client_secret|client_id|api[_-]?key|apikey|password|passwd|secret|bearer|authorization|cookie|credentialblob|token)\b\s*[:=]\s*["'']?[^\s",''}]{6,}'
    '\bya29\.[A-Za-z0-9._\-]{10,}'
    '\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}'
    # Catch-all for token shapes we do not recognise. Path segments are exempt:
    # a long directory name is not a secret, and hiding it makes a log useless.
    '(?<![\\/:.])\b[A-Za-z0-9_\-]{40,}\b(?![\\/])'
)

function Protect-AgyAutoText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    foreach ($p in $script:RedactPatterns) { $out = [regex]::Replace($out, $p, '<REDACTED>') }
    $out
}

# --------------------------------------------------------------- atomic I/O --

function Write-AgyAutoFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N'))
    # UTF-8 without BOM: agy and Go tooling read these files.
    [IO.File]::WriteAllText($tmp, $Content, (New-Object Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path) {
            # File.Replace's 3-argument form needs a real null for "no backup",
            # but PowerShell turns $null into "" when binding a [string]
            # parameter and .NET then rejects it as a malformed path. Use a
            # temporary backup instead and drop it once the swap has committed.
            $bak = "$tmp.bak"
            [IO.File]::Replace($tmp, $Path, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        } else { [IO.File]::Move($tmp, $Path) }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function ConvertTo-AgyAutoJson { param($Object, [int]$Depth = 12) $Object | ConvertTo-Json -Depth $Depth }

function Read-AgyAutoJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { $raw | ConvertFrom-Json } catch { $null }
}

# ---------------------------------------------------------------- logging ----

function Write-AgyAutoLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [switch]$Console
    )
    $safe = Protect-AgyAutoText $Message
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('o'), $Level, $safe
    try {
        Initialize-AgyAutoDirs
        $file = Get-AgyAutoPath ('logs\{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding utf8
    } catch { }
    if ($Console) {
        $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkCyan' } }
        Write-Host ('[agy-auto] ' + $safe) -ForegroundColor $color
    }
}

function Write-AgyAutoStatus {
    param([Parameter(Mandatory)][string]$Message)
    Write-AgyAutoLog -Level INFO -Message $Message -Console
}

# ----------------------------------------------------------------- config ----

function Get-AgyAutoDefaultConfig {
    [ordered]@{
        enabled                     = $true
        realAgyPath                 = ''
        pluginPath                  = $script:AgyAutoPluginRoot
        profileOrder                = @()
        rotationPolicy              = 'round-robin'
        resumeStrategy              = 'try-original-then-handoff'
        skipExhaustedProfiles       = $true
        maxConsecutiveSwitches      = 5
        hookTimeoutSeconds          = 5
        childShutdownTimeoutSeconds = 10
        resumeProbeSeconds          = 20
        autoSkipPermissions         = $true
        quotaFloor                  = 0.005
        exhaustedAction             = 'report-and-exit'
    }
}

function Get-AgyAutoConfig {
    $path = Get-AgyAutoPath 'config.json'
    $cfg = Read-AgyAutoJson $path
    $defaults = Get-AgyAutoDefaultConfig
    if ($null -eq $cfg) { return [pscustomobject]$defaults }
    # Fill in keys added by newer versions without discarding the user's file.
    foreach ($k in $defaults.Keys) {
        if (-not ((Get-AgyAutoPropertyNames $cfg) -contains $k)) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
        }
    }
    $cfg
}

function Set-AgyAutoConfig {
    param([Parameter(Mandatory)]$Config)
    Initialize-AgyAutoDirs
    Write-AgyAutoFileAtomic -Path (Get-AgyAutoPath 'config.json') -Content (ConvertTo-AgyAutoJson $Config)
}

# ------------------------------------------------------------------ state ----

function Get-AgyAutoState {
    $s = Read-AgyAutoJson (Get-AgyAutoPath 'state.json')
    if ($null -eq $s) {
        $s = [pscustomobject]@{
            activeProfile       = $null
            consecutiveSwitches = 0
            lastSwitchAt        = $null
            profiles            = [pscustomobject]@{}
        }
    }
    foreach ($k in 'activeProfile', 'consecutiveSwitches', 'lastSwitchAt', 'profiles') {
        if (-not ((Get-AgyAutoPropertyNames $s) -contains $k)) {
            $v = if ($k -eq 'consecutiveSwitches') { 0 } elseif ($k -eq 'profiles') { [pscustomobject]@{} } else { $null }
            $s | Add-Member -NotePropertyName $k -NotePropertyValue $v
        }
    }
    $s
}

function Set-AgyAutoState {
    param([Parameter(Mandatory)]$State)
    Initialize-AgyAutoDirs
    Write-AgyAutoFileAtomic -Path (Get-AgyAutoPath 'state.json') -Content (ConvertTo-AgyAutoJson $State)
}

# ------------------------------------------------------------------- lock ----

# Mutual exclusion for the switch transaction. Global namespace so separate
# logon sessions still serialise; falls back to Local when Global is denied.
function Enter-AgyAutoLock {
    param([int]$TimeoutSeconds = 30)
    $suffix = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes("$env:USERDOMAIN\$env:USERNAME"))).Replace('-', '').Substring(0, 16)
    foreach ($ns in 'Global', 'Local') {
        try {
            $created = $false
            $m = New-Object Threading.Mutex($false, "$ns\agy-auto-switch-$suffix", [ref]$created)
            $held = $false
            try { $held = $m.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
            catch [Threading.AbandonedMutexException] { $held = $true }  # previous holder crashed
            if (-not $held) { $m.Dispose(); return $null }
            return $m
        } catch { continue }
    }
    $null
}

function Exit-AgyAutoLock {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

# ------------------------------------------------------- Win32 argv handling --

# Compiled on demand: Add-Type costs ~1s and the Stop hook must stay fast.
function Initialize-AgyAutoArgApi {
    if ('AgyAuto.Shell32' -as [type]) { return }
    Add-Type -Namespace AgyAuto -Name Shell32 -MemberDefinition @'
[DllImport("shell32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
[DllImport("kernel32.dll")]
public static extern IntPtr LocalFree(IntPtr hMem);
'@
}

# Parse a raw command-line tail exactly the way Windows itself does, so the
# quoting the user typed survives the shim verbatim.
function ConvertFrom-AgyAutoCommandLine {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    Initialize-AgyAutoArgApi
    # CommandLineToArgvW treats argv[0] specially; prepend a dummy and drop it.
    $n = 0
    $ptr = [AgyAuto.Shell32]::CommandLineToArgvW("agy $CommandLine", [ref]$n)
    if ($ptr -eq [IntPtr]::Zero) { throw 'CommandLineToArgvW failed' }
    try {
        $out = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 1; $i -lt $n; $i++) {
            $p = [Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size)
            $out.Add([Runtime.InteropServices.Marshal]::PtrToStringUni($p))
        }
        $out.ToArray()
    } finally { [void][AgyAuto.Shell32]::LocalFree($ptr) }
}

# Inverse: MSVCRT quoting rules, so an argument array becomes a command line
# that CommandLineToArgvW parses back into the identical array.
function ConvertTo-AgyAutoArgString {
    param([AllowEmptyCollection()][string[]]$Arguments)
    if ((Get-AgyAutoCount $Arguments) -eq 0) { return '' }
    $parts = foreach ($a in $Arguments) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        for ($i = 0; $i -lt $a.Length; $i++) {
            $slashes = 0
            while ($i -lt $a.Length -and $a[$i] -eq '\') { $slashes++; $i++ }
            if ($i -eq $a.Length) { [void]$sb.Append('\' * ($slashes * 2)); break }
            if ($a[$i] -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)).Append('"') }
            else { [void]$sb.Append('\' * $slashes).Append($a[$i]) }
        }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    $parts -join ' '
}

# ------------------------------------------------------------------ misc -----

function Resolve-AgyAutoRealAgy {
    param([switch]$Refresh)
    $cfg = Get-AgyAutoConfig
    if (-not $Refresh -and $cfg.realAgyPath -and (Test-Path -LiteralPath $cfg.realAgyPath)) { return $cfg.realAgyPath }

    $ourBin = Get-AgyAutoPath 'bin'
    $candidates = @(Get-Command agy -All -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq 'Application' -and $_.Source -and (Split-Path -Parent $_.Source) -ne $ourBin } |
        ForEach-Object { $_.Source })
    $candidates += (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c) -and ($c -notlike "$ourBin*")) { return $c }
    }
    $null
}

# ------------------------------------------------------------------ shims ---

# Absolute paths are baked in on purpose: a .cmd that had to resolve config
# first would need a PowerShell round-trip on every single invocation.
function New-AgyAutoShims {
    param(
        [Parameter(Mandatory)][string]$InstalledPluginPath,
        [Parameter(Mandatory)][string]$RealAgyPath
    )
    $bin = Get-AgyAutoPath 'bin'
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }
    $entry = Join-Path $InstalledPluginPath 'bin\agy-auto.ps1'

    # AGY_AUTO_RAWARGS carries the verbatim tail so quoting is parsed once, by
    # CommandLineToArgvW, instead of being re-tokenised by cmd and PowerShell.
    $supervised = @"
@echo off
setlocal
set "AGY_AUTO_RAWARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "$entry"{0}
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath (Join-Path $bin 'agy.cmd') -Value ($supervised -f ' -Passthrough') -Encoding ascii
    Set-Content -LiteralPath (Join-Path $bin 'agy-auto.cmd') -Value ($supervised -f '') -Encoding ascii

    $raw = @"
@echo off
rem Direct passthrough: no supervisor, no rotation, no added flags.
"$RealAgyPath" %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath (Join-Path $bin 'agy-raw.cmd') -Value $raw -Encoding ascii
    $bin
}

function Remove-AgyAutoShims {
    $bin = Get-AgyAutoPath 'bin'
    foreach ($f in 'agy.cmd', 'agy-auto.cmd', 'agy-raw.cmd') {
        $p = Join-Path $bin $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
}

# ------------------------------------------------------------------- PATH ----

# Read/write the raw registry value: [Environment]::GetEnvironmentVariable
# expands %VARS% and writing that back would permanently bake them in.
function Get-AgyAutoUserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return @{ Value = ''; Kind = 'ExpandString' } }
    try {
        $v = $key.GetValue('PATH', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $k = 'ExpandString'
        try { $k = $key.GetValueKind('PATH').ToString() } catch { }
        @{ Value = [string]$v; Kind = $k }
    } finally { $key.Close() }
}

function Set-AgyAutoUserPathRaw {
    param([Parameter(Mandatory)][string]$Value, [string]$Kind = 'ExpandString')
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('PATH', $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $key.Close() }
    Publish-AgyAutoEnvChange
}

# Tell the shell that user environment changed, so new terminals see the PATH
# without a sign-out.
function Publish-AgyAutoEnvChange {
    if (-not ('AgyAuto.User32' -as [type])) {
        Add-Type -Namespace AgyAuto -Name User32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
    }
    try {
        $r = [UIntPtr]::Zero
        [void][AgyAuto.User32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r)
    } catch { }
}

function Add-AgyAutoToUserPath {
    $bin = (Get-AgyAutoPath 'bin').TrimEnd('\')
    $cur = Get-AgyAutoUserPathRaw
    $parts = @($cur.Value -split ';' | Where-Object { $_ })
    $others = @($parts | Where-Object { $_.TrimEnd('\') -ne $bin })
    if ((Get-AgyAutoCount $parts) -gt 0 -and $parts[0].TrimEnd('\') -eq $bin) { return $false }   # already first
    Set-AgyAutoUserPathRaw -Value ((@($bin) + $others) -join ';') -Kind $cur.Kind
    $true
}

function Remove-AgyAutoFromUserPath {
    $bin = (Get-AgyAutoPath 'bin').TrimEnd('\')
    $cur = Get-AgyAutoUserPathRaw
    $parts = @($cur.Value -split ';' | Where-Object { $_ })
    $kept = @($parts | Where-Object { $_.TrimEnd('\') -ne $bin })
    if ((Get-AgyAutoCount $kept) -eq (Get-AgyAutoCount $parts)) { return $false }
    Set-AgyAutoUserPathRaw -Value ($kept -join ';') -Kind $cur.Kind
    $true
}

function Test-AgyAutoRealAgy {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $v = & $Path --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return ($v | Select-Object -First 1).ToString().Trim() }
    } catch { }
    $null
}
