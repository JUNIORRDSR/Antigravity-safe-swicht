# uninstall.ps1 - remove agy-auto-switch and leave Antigravity CLI exactly as it was.
#
# The live gemini:antigravity credential is NEVER touched. After this runs,
# `agy` resolves to the official executable again.

[CmdletBinding()]
param(
    [switch]$RemoveProfiles,   # also delete the stored per-profile credentials
    [switch]$Purge,            # also delete %LOCALAPPDATA%\agy-auto-switch
    [switch]$RestoreSettings,  # restore settings.json from the setup backup
    [switch]$Yes               # do not prompt
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$scripts = if (Test-Path -LiteralPath (Join-Path $here 'scripts\common.ps1')) { Join-Path $here 'scripts' }
else { Join-Path $env:USERPROFILE '.gemini\config\plugins\agy-auto-switch\scripts' }

. (Join-Path $scripts 'common.ps1')
. (Join-Path $scripts 'credential-manager.ps1')

function Say { param([string]$M, [string]$C = 'Gray') Write-Host $M -ForegroundColor $C }

Write-Host ''
Write-Host 'agy-auto-switch uninstall' -ForegroundColor White
Write-Host ''

$cfg = Get-AgyAutoConfig
$realAgy = $cfg.realAgyPath
if (-not ($realAgy -and (Test-Path -LiteralPath $realAgy))) { $realAgy = Resolve-AgyAutoRealAgy -Refresh }

# --------------------------------------------------------------- 1. shims ----
Remove-AgyAutoShims
Say '[ok] command shims removed' 'Green'

# ---------------------------------------------------------------- 2. PATH ----
if (Remove-AgyAutoFromUserPath) { Say '[ok] our PATH entry removed (nothing else changed)' 'Green' }
else { Say '[--] our PATH entry was not present' 'DarkGray' }

# -------------------------------------------------------------- 3. plugin ----
$installed = Join-Path $env:USERPROFILE '.gemini\config\plugins\agy-auto-switch'
if ($realAgy -and (Test-Path -LiteralPath $realAgy)) {
    try { & $realAgy plugin uninstall agy-auto-switch 2>&1 | ForEach-Object { Say ('     ' + $_) 'DarkGray' } } catch { }
}
if (Test-Path -LiteralPath $installed) {
    Remove-Item -LiteralPath $installed -Recurse -Force -ErrorAction SilentlyContinue
}
Say $(if (Test-Path -LiteralPath $installed) { '[!!] plugin directory could not be removed' } else { '[ok] plugin removed' }) `
    $(if (Test-Path -LiteralPath $installed) { 'Yellow' } else { 'Green' })

# ------------------------------------------------------------ 4. settings ----
$settingsPath = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'
$backup = "$settingsPath.agy-auto.bak"
if ($RestoreSettings) {
    if (Test-Path -LiteralPath $backup) {
        Copy-Item -LiteralPath $backup -Destination $settingsPath -Force
        Say '[ok] settings.json restored from the setup backup' 'Green'
    } else { Say '[--] no settings backup found' 'DarkGray' }
} elseif (Test-Path -LiteralPath $backup) {
    Say ("[--] settings.json left as-is. Backup kept at {0}" -f $backup) 'DarkGray'
    Say '     Re-run with -RestoreSettings to roll the autonomy settings back.' 'DarkGray'
}

# ------------------------------------------------------------ 5. profiles ----
$profileNames = @(Get-AgyAutoPropertyNames (Get-AgyAutoState).profiles)
if ($RemoveProfiles) {
    $confirmed = $Yes
    if (-not $confirmed) {
        Say ''
        Say ("About to delete {0} stored profile credential(s): {1}" -f (Get-AgyAutoCount $profileNames), ($profileNames -join ', ')) 'Yellow'
        Say 'The active gemini:antigravity credential is NOT affected.' 'Yellow'
        $confirmed = (Read-Host 'Type DELETE to confirm') -ceq 'DELETE'
    }
    if ($confirmed) {
        foreach ($n in $profileNames) { [void](Remove-AgyCredential -Target (Get-AgyProfileTarget $n)) }
        Say '[ok] stored profile credentials deleted' 'Green'
    } else { Say '[--] profile credentials kept' 'DarkGray' }
} elseif ((Get-AgyAutoCount $profileNames) -gt 0) {
    Say ("[--] {0} profile credential(s) kept in Credential Manager: {1}" -f (Get-AgyAutoCount $profileNames), ($profileNames -join ', ')) 'DarkGray'
    Say '     Re-run with -RemoveProfiles to delete them.' 'DarkGray'
}

# ---------------------------------------------------------------- 6. data ----
if ($Purge) {
    $root = Get-AgyAutoDataRoot
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    Say '[ok] local data removed' 'Green'
} else {
    Say ("[--] logs, checkpoints and handoffs kept at {0}" -f (Get-AgyAutoDataRoot)) 'DarkGray'
    Say '     Re-run with -Purge to delete them.' 'DarkGray'
}

# ------------------------------------------------------------ verification ---
Write-Host ''
$live = Get-AgyCredentialInfo -Target (Get-AgyLiveTarget)
Say ("[{0}] live credential {1}: {2}" -f $(if ($live.Present) { 'ok' } else { '!!' }), (Get-AgyLiveTarget),
    $(if ($live.Present) { "intact ($($live.BlobBytes) bytes)" } else { 'MISSING' })) `
    $(if ($live.Present) { 'Green' } else { 'Red' })

$cmd = Get-Command agy -All -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { Say ("[ok] agy now resolves to {0}" -f $cmd.Source) 'Green' }
else { Say '[--] agy is not on this shell PATH yet; open a new terminal' 'DarkGray' }

Write-Host ''
Write-Host 'Antigravity CLI is untouched. Open a new terminal to pick up the PATH change.' -ForegroundColor White
Write-Host ''
