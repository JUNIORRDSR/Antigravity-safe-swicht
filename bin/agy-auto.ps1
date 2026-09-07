# agy-auto.ps1 - entry point behind the agy / agy-auto / agy-raw shims.
#
# Arguments arrive through AGY_AUTO_RAWARGS as the verbatim command-line tail
# and are parsed with CommandLineToArgvW, so the user's quoting survives exactly
# instead of being re-tokenised twice on the way through cmd and PowerShell.

[CmdletBinding()]
param(
    # agy.cmd sets this: never interpret management subcommands, just supervise.
    [switch]$Passthrough
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptsDir = $null
foreach ($candidate in @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'),
        (Join-Path $PSScriptRoot 'scripts'))) {
    if (Test-Path -LiteralPath (Join-Path $candidate 'common.ps1')) { $scriptsDir = $candidate; break }
}
if (-not $scriptsDir) {
    Write-Host 'agy-auto: cannot locate the agy-auto-switch scripts directory.' -ForegroundColor Red
    exit 127
}

. (Join-Path $scriptsDir 'common.ps1')
. (Join-Path $scriptsDir 'credential-manager.ps1')
. (Join-Path $scriptsDir 'profile-manager.ps1')
. (Join-Path $scriptsDir 'quota.ps1')
. (Join-Path $scriptsDir 'supervisor.ps1')
. (Join-Path $scriptsDir 'doctor.ps1')

$raw = $env:AGY_AUTO_RAWARGS
$env:AGY_AUTO_RAWARGS = $null
$argv = @(ConvertFrom-AgyAutoCommandLine $raw)

# --safe is ours alone and is never forwarded to agy.
$safe = $false
if ($argv -contains '--safe') {
    $safe = $true
    $argv = @($argv | Where-Object { $_ -ne '--safe' })
}

function Show-AgyAutoHelp {
    @'
agy-auto - quota-aware supervisor for Antigravity CLI

  agy [args...]                Normal work. Supervised, autonomous by default.
  agy --safe [args...]         Supervised, but without --dangerously-skip-permissions.
  agy-raw [args...]            The real agy, no supervisor, no added flags.

  agy-auto [args...]           Same as agy.
  agy-auto run [args...]       Supervised headless run (handoff uses -p).
  agy-auto tui [args...]       Supervised interactive session (default).

  agy-auto profile save <name>     Store the signed-in account as <name>.
  agy-auto profile list            Show profiles, quota state and fingerprints.
  agy-auto profile current         Which profile is signed in right now.
  agy-auto profile switch <name>   Switch accounts now (no agy may be running).
  agy-auto profile next            Show the profile rotation would pick next.
  agy-auto profile delete <name>   Forget a profile and its stored credential.

  agy-auto status              Config, state and profile summary.
  agy-auto doctor [--probe]    Full diagnosis. --probe spends one tiny turn.
  agy-auto quota               Live quota for the signed-in account.
  agy-auto enable | disable    Turn automatic rotation on or off.
  agy-auto help                This text.

Credentials are never printed, logged, or written outside Windows Credential
Manager.
'@ | Write-Host
}

function Show-AgyAutoStatus {
    $cfg = Get-AgyAutoConfig
    $state = Get-AgyAutoState
    Write-Host ''
    Write-Host 'agy-auto status' -ForegroundColor Cyan
    Write-Host ('  rotation        : {0}' -f $(if ($cfg.enabled) { 'enabled' } else { 'disabled' }))
    Write-Host ('  real agy        : {0}' -f $cfg.realAgyPath)
    Write-Host ('  resume strategy : {0}' -f $cfg.resumeStrategy)
    Write-Host ('  max switches    : {0}' -f $cfg.maxConsecutiveSwitches)
    Write-Host ('  last switch     : {0}' -f $(if ($state.lastSwitchAt) { $state.lastSwitchAt } else { 'never' }))
    Write-Host ''
    Show-AgyProfileTable
}

function Show-AgyProfileTable {
    $profiles = @(Get-AgyProfileList)
    if ((Get-AgyAutoCount $profiles) -eq 0) {
        Write-Host '  No profiles registered. Run: agy-auto profile save <name>' -ForegroundColor Yellow
        return
    }
    $cur = Get-AgyCurrentProfile
    Write-Host ('  {0,-3} {1,-16} {2,-9} {3,-20} {4}' -f '', 'NAME', 'STATE', 'AVAILABLE', 'FINGERPRINT')
    foreach ($p in $profiles) {
        $marker = if ($p.Name -eq $cur.Name) { '*' } else { ' ' }
        $state = if (-not $p.Present) { 'no cred' } elseif (-not $p.Enabled) { 'disabled' } elseif ($p.Exhausted) { 'exhausted' } else { 'ready' }
        $avail = if ($p.Exhausted) { $p.ExhaustedUntil.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'now' }
        $color = if ($state -eq 'ready') { 'Green' } elseif ($state -eq 'exhausted') { 'Yellow' } else { 'Red' }
        Write-Host ('  {0,-3} {1,-16} ' -f $marker, $p.Name) -NoNewline
        Write-Host ('{0,-9} ' -f $state) -NoNewline -ForegroundColor $color
        Write-Host ('{0,-20} {1}' -f $avail, (Format-AgyFingerprint $p.Fingerprint))
    }
    if ($cur.Match -eq 'state-drifted') {
        Write-Host '  (the live credential was refreshed by agy since it was saved)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Invoke-AgyProfileCommand {
    param([string[]]$Rest)
    $n = Get-AgyAutoCount $Rest
    $sub = if ($n -gt 0) { $Rest[0] } else { 'list' }
    $name = if ($n -gt 1) { $Rest[1] } else { $null }

    switch ($sub) {
        'save' {
            if (-not $name) { Write-Host 'usage: agy-auto profile save <name>' -ForegroundColor Red; return 2 }
            $r = Save-AgyProfile -Name $name
            Write-Host ("Saved profile '{0}' ({1} bytes, fingerprint {2})." -f $r.Name, $r.BlobBytes, (Format-AgyFingerprint $r.Fingerprint)) -ForegroundColor Green
            Write-Host 'The credential itself stays in Windows Credential Manager and is never shown.' -ForegroundColor DarkGray
            return 0
        }
        'list' { Show-AgyProfileTable; return 0 }
        'current' {
            $c = Get-AgyCurrentProfile
            if ($c.Name) { Write-Host ("{0}  (matched by {1})" -f $c.Name, $c.Match) }
            else { Write-Host ("unknown  ({0})" -f $c.Match) -ForegroundColor Yellow }
            return 0
        }
        'switch' {
            if (-not $name) { Write-Host 'usage: agy-auto profile switch <name>' -ForegroundColor Red; return 2 }
            $running = @(Get-Process -Name 'agy' -ErrorAction SilentlyContinue)
            if ((Get-AgyAutoCount $running) -gt 0) {
                Write-Host ("{0} agy process(es) are running. Close them first - swapping the credential under a live agy is not safe." -f (Get-AgyAutoCount $running)) -ForegroundColor Red
                return 1
            }
            try {
                $r = Switch-AgyProfile -To $name
                Write-Host ("Switched {0} -> {1}." -f $(if ($r.From) { $r.From } else { 'unknown' }), $r.To) -ForegroundColor Green
                return 0
            } catch {
                Write-Host ("Switch failed and was rolled back: {0}" -f (Protect-AgyAutoText $_.Exception.Message)) -ForegroundColor Red
                return 1
            }
        }
        'next' {
            $cur = Get-AgyCurrentProfile
            $n = Get-AgyNextProfile -AfterProfile $cur.Name
            if ($null -eq $n) { Write-AgyExhaustedReport -Profiles (Get-AgyProfileList); return 75 }
            Write-Host $n.Name
            return 0
        }
        'delete' {
            if (-not $name) { Write-Host 'usage: agy-auto profile delete <name>' -ForegroundColor Red; return 2 }
            $removed = Remove-AgyProfile -Name $name
            Write-Host ("Profile '{0}' removed{1}." -f $name, $(if ($removed) { '' } else { ' (it had no stored credential)' }))
            Write-Host 'The active gemini:antigravity credential was not touched.' -ForegroundColor DarkGray
            return 0
        }
        default { Write-Host "unknown: agy-auto profile $sub" -ForegroundColor Red; Show-AgyAutoHelp; return 2 }
    }
}

# ------------------------------------------------------------------ dispatch --

$argc = Get-AgyAutoCount $argv
$first = if ($argc -gt 0) { $argv[0] } else { '' }
# Assigned in two steps on purpose: `$x = if (...) { } else { @() }` sends the
# empty array through the pipeline, where it unrolls to $null.
$rest = @()
if ($argc -gt 1) { $rest = @($argv[1..($argc - 1)]) }
$exit = 0

if (-not $Passthrough -and $first -and $first -notmatch '^-') {
    switch ($first) {
        'profile' { $exit = Invoke-AgyProfileCommand -Rest $rest }
        'status' { Show-AgyAutoStatus; $exit = 0 }
        'help' { Show-AgyAutoHelp; $exit = 0 }
        'doctor' {
            $exit = Invoke-AgyAutoDoctor -Probe:($rest -contains '--probe') -Fix:($rest -contains '--fix')
        }
        'quota' {
            $cfg = Get-AgyAutoConfig
            $realAgy = Resolve-AgyAutoRealAgy
            if (-not $realAgy) { Write-Host 'real agy not found' -ForegroundColor Red; $exit = 127 }
            else {
                $snap = Get-AgyQuotaSnapshot -RealAgyPath $realAgy
                if ($null -eq $snap) { Write-Host 'quota query failed' -ForegroundColor Yellow; $exit = 1 }
                else { Write-Host (Format-AgyQuotaSnapshot -Snapshot $snap); $exit = 0 }
            }
        }
        'enable' {
            $cfg = Get-AgyAutoConfig; $cfg.enabled = $true; Set-AgyAutoConfig $cfg
            Write-Host 'Automatic rotation enabled.' -ForegroundColor Green; $exit = 0
        }
        'disable' {
            $cfg = Get-AgyAutoConfig; $cfg.enabled = $false; Set-AgyAutoConfig $cfg
            Write-Host 'Automatic rotation disabled. agy still runs through the supervisor.' -ForegroundColor Yellow; $exit = 0
        }
        'run' { $exit = Start-AgySupervisor -Mode run -AgyArgs $rest -Safe:$safe }
        'tui' { $exit = Start-AgySupervisor -Mode tui -AgyArgs $rest -Safe:$safe }
        default { $exit = Start-AgySupervisor -Mode tui -AgyArgs $argv -Safe:$safe }
    }
} else {
    $exit = Start-AgySupervisor -Mode tui -AgyArgs $argv -Safe:$safe
}

exit $exit
