# setup.ps1 - install agy-auto-switch.
#
# Order matters: the real agy is discovered BEFORE the shims exist, otherwise
# the supervisor would later resolve `agy` to its own wrapper and recurse.

[CmdletBinding()]
param(
    [switch]$ConfigureAutonomy,   # write always-proceed / accept-edits into settings.json
    [switch]$NoAutonomy,          # never ask, never write
    [switch]$SkipPath             # do not touch the user PATH
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')

function Say { param([string]$M, [string]$C = 'Gray') Write-Host $M -ForegroundColor $C }
function Step { param([string]$M) Write-Host ''; Write-Host ('==> ' + $M) -ForegroundColor Cyan }

Write-Host ''
Write-Host 'agy-auto-switch setup' -ForegroundColor White

# ------------------------------------------------------------ 1. real agy ----
Step 'Locating the real Antigravity CLI'
$realAgy = Resolve-AgyAutoRealAgy -Refresh
if (-not $realAgy) {
    Say 'Could not find agy.exe. Install Antigravity CLI first, then re-run setup.' 'Red'
    exit 127
}
$version = Test-AgyAutoRealAgy -Path $realAgy
if (-not $version) {
    Say "Found $realAgy but '--version' did not succeed. Aborting rather than guessing." 'Red'
    exit 1
}
Say ("  {0}" -f $realAgy) 'Green'
Say ("  version {0}" -f $version) 'Green'

$ourBin = (Get-AgyAutoPath 'bin').TrimEnd('\')
if ($realAgy -like "$ourBin*") {
    Say '  That path is inside our own shim directory. Refusing to install a recursive wrapper.' 'Red'
    exit 1
}

# --------------------------------------------------------------- 2. plugin ---
Step 'Installing the plugin'
$pluginsRoot = Join-Path $env:USERPROFILE '.gemini\config\plugins'
$installed = Join-Path $pluginsRoot 'agy-auto-switch'

$installOk = $false
try {
    & $realAgy plugin install $repoRoot 2>&1 | ForEach-Object { Say ('  ' + $_) }
    $installOk = Test-Path -LiteralPath (Join-Path $installed 'plugin.json')
} catch {
    Say ('  official install failed: ' + $_.Exception.Message) 'Yellow'
}

if (-not $installOk) {
    Say '  falling back to a direct copy into the discovery directory' 'Yellow'
    if (Test-Path -LiteralPath $installed) { Remove-Item -LiteralPath $installed -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $installed | Out-Null
    foreach ($item in 'plugin.json', 'hooks.json', 'README.md') {
        $src = Join-Path $repoRoot $item
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $installed -Force }
    }
    foreach ($dir in 'scripts', 'skills', 'bin', 'docs') {
        $src = Join-Path $repoRoot $dir
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $installed -Recurse -Force }
    }
    $installOk = Test-Path -LiteralPath (Join-Path $installed 'plugin.json')
}

if (-not $installOk) { Say '  plugin installation failed' 'Red'; exit 1 }

# `plugin install` copies the whole source tree, .git included. Drop it.
$stagedGit = Join-Path $installed '.git'
if (Test-Path -LiteralPath $stagedGit) { Remove-Item -LiteralPath $stagedGit -Recurse -Force }

foreach ($required in 'hooks.json', 'scripts\stop-hook.ps1', 'bin\agy-auto.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $installed $required))) {
        Say ("  missing after install: {0}" -f $required) 'Red'
        exit 1
    }
}
try { $null = Get-Content -LiteralPath (Join-Path $installed 'hooks.json') -Raw | ConvertFrom-Json }
catch { Say '  installed hooks.json is not valid JSON' 'Red'; exit 1 }
Say ("  {0}" -f $installed) 'Green'

# --------------------------------------------------------------- 3. config ---
Step 'Writing configuration'
Initialize-AgyAutoDirs
$cfg = Get-AgyAutoConfig
$cfg.realAgyPath = $realAgy
$cfg.pluginPath = $installed
$cfg.enabled = $true
Set-AgyAutoConfig $cfg
Say ("  {0}" -f (Get-AgyAutoPath 'config.json')) 'Green'

# ---------------------------------------------------------------- 4. shims ---
Step 'Installing command shims'
$bin = New-AgyAutoShims -InstalledPluginPath $installed -RealAgyPath $realAgy
foreach ($f in 'agy.cmd', 'agy-auto.cmd', 'agy-raw.cmd') { Say ('  ' + (Join-Path $bin $f)) 'Green' }

if ($SkipPath) {
    Say '  PATH left untouched (-SkipPath)' 'Yellow'
} else {
    Step 'Updating the user PATH'
    if (Add-AgyAutoToUserPath) { Say ("  {0} is now first in the user PATH" -f $bin) 'Green' }
    else { Say '  already first in the user PATH' 'Green' }
    Say '  Open a new terminal for this to take effect.' 'DarkGray'
}

# ------------------------------------------------------------- 5. autonomy ---
$settingsPath = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'
$wantAutonomy = $false
if ($ConfigureAutonomy) { $wantAutonomy = $true }
elseif (-not $NoAutonomy -and [Environment]::UserInteractive) {
    Step 'Autonomous defaults'
    Say '  Antigravity can be set to stop asking for approval on tool calls,'
    Say '  file writes and artifact review:'
    Say '    toolPermission       = always-proceed'
    Say '    artifactReviewPolicy = always-proceed'
    Say '    agentMode            = accept-edits'
    $answer = Read-Host '  Apply these to settings.json? (y/N)'
    $wantAutonomy = $answer -match '^(y|yes|s|si)$'
}

if ($wantAutonomy) {
    Step 'Configuring autonomous defaults'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Say '  settings.json not found; skipping' 'Yellow'
    } else {
        $backup = "$settingsPath.agy-auto.bak"
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
        Say ("  backup: {0}" -f $backup) 'DarkGray'

        # Merge: read, change only the three keys, keep everything else -
        # including trustedWorkspaces and any key this version does not know.
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $desired = @{
            toolPermission       = 'always-proceed'
            artifactReviewPolicy = 'always-proceed'
            agentMode            = 'accept-edits'
        }
        foreach ($k in $desired.Keys) {
            if ((Get-AgyAutoPropertyNames $settings) -contains $k) { $settings.$k = $desired[$k] }
            else { $settings | Add-Member -NotePropertyName $k -NotePropertyValue $desired[$k] }
        }
        Write-AgyAutoFileAtomic -Path $settingsPath -Content ($settings | ConvertTo-Json -Depth 12)

        # Prove agy still accepts the file before leaving it in place.
        $check = Test-AgyAutoRealAgy -Path $realAgy
        if (-not $check) {
            Copy-Item -LiteralPath $backup -Destination $settingsPath -Force
            Say '  agy rejected the new settings; restored the backup' 'Red'
        } else {
            Say '  applied and verified' 'Green'
        }
    }
}

# ---------------------------------------------------------------- 6. doctor --
Step 'Running doctor'
. (Join-Path $installed 'scripts\doctor.ps1')
$code = Invoke-AgyAutoDoctor

Write-Host ''
Write-Host 'Next steps' -ForegroundColor White
Write-Host '  1. Open a NEW terminal (so the PATH change applies).'
Write-Host '  2. With account A signed in:   agy-auto profile save personal'
Write-Host '  3. Sign in as account B, then: agy-auto profile save work'
Write-Host '  4. Check everything:           agy-auto doctor'
Write-Host '  5. Work normally:              agy'
Write-Host ''

exit $code
