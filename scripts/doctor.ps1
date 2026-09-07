# doctor.ps1 - diagnose the whole installation without revealing a single secret.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'credential-manager.ps1')
. (Join-Path $PSScriptRoot 'profile-manager.ps1')
. (Join-Path $PSScriptRoot 'quota.ps1')

$script:DoctorFail = 0
$script:DoctorWarn = 0

function Write-Section { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }
function Write-Check {
    param([string]$Label, [string]$Value, [ValidateSet('ok', 'warn', 'fail', 'info')][string]$Status = 'info')
    $color = switch ($Status) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } default { 'Gray' } }
    if ($Status -eq 'fail') { $script:DoctorFail++ }
    if ($Status -eq 'warn') { $script:DoctorWarn++ }
    Write-Host ('  {0,-34} ' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $color
}

function Get-AgySettingsPath { Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json' }
function Get-AgyPluginInstallPath { Join-Path $env:USERPROFILE '.gemini\config\plugins\agy-auto-switch' }

function Invoke-AgyAutoDoctor {
    [CmdletBinding()]
    param([switch]$Probe, [switch]$Fix)

    $script:DoctorFail = 0
    $script:DoctorWarn = 0
    Initialize-AgyAutoDirs

    Write-Host ''
    Write-Host 'AGY Auto Switch Doctor' -ForegroundColor Cyan

    # ---------------------------------------------------------- Antigravity --
    Write-Section 'Antigravity CLI'
    $cfg = Get-AgyAutoConfig
    $ourBin = Get-AgyAutoPath 'bin'
    $realAgy = $cfg.realAgyPath
    $realOk = $realAgy -and (Test-Path -LiteralPath $realAgy)

    if (-not $realOk) {
        $discovered = Resolve-AgyAutoRealAgy -Refresh
        if ($discovered) {
            Write-Check 'realAgyPath' "stale, found $discovered" 'warn'
            if ($Fix) { $cfg.realAgyPath = $discovered; Set-AgyAutoConfig $cfg; Write-Check 'realAgyPath repaired' $discovered 'ok' }
            $realAgy = $discovered; $realOk = $true
        } else {
            Write-Check 'realAgyPath' 'NOT FOUND' 'fail'
        }
    }

    if ($realOk) {
        Write-Check 'Executable' $realAgy 'ok'
        if ($realAgy -like "$ourBin*") {
            Write-Check 'Recursion guard' 'FAIL - realAgyPath points at our own shim' 'fail'
        } else {
            Write-Check 'Recursion guard' 'no recursion' 'ok'
        }
        $ver = Test-AgyAutoRealAgy -Path $realAgy
        if ($ver) { Write-Check 'Version' $ver 'ok' }
        else { Write-Check 'Version' 'could not run --version' 'fail' }
    }

    # -------------------------------------------------------- shim routing --
    Write-Section 'Command routing'

    # Persisted configuration is what matters; the PATH of the shell running
    # doctor may simply predate setup.
    $userPath = @((Get-AgyAutoUserPathRaw).Value -split ';' | Where-Object { $_ })
    $ourIdx = [array]::FindIndex($userPath, [Predicate[string]] { param($x) $x.TrimEnd('\') -eq $ourBin.TrimEnd('\') })
    $agyIdx = [array]::FindIndex($userPath, [Predicate[string]] { param($x) $x -like '*\agy\bin' })
    $pathOk = ($ourIdx -ge 0) -and ($agyIdx -lt 0 -or $ourIdx -lt $agyIdx)
    $shellStale = (Get-AgyAutoCount (($env:PATH -split ";") | Where-Object { $_.TrimEnd("\") -eq $ourBin.TrimEnd("\") })) -eq 0

    foreach ($name in 'agy', 'agy-auto', 'agy-raw') {
        $shim = Join-Path $ourBin "$name.cmd"
        if (-not (Test-Path -LiteralPath $shim)) { Write-Check $name 'shim missing' 'fail'; continue }
        $target = if ($name -eq 'agy-raw') { $realAgy } else { 'AGY Auto Supervisor' }
        if ($pathOk -and -not $shellStale) { Write-Check $name "$shim -> $target" 'ok' }
        elseif ($pathOk) { Write-Check $name "$shim -> $target (this shell predates setup)" 'warn' }
        else { Write-Check $name "$shim -> $target (NOT reachable via PATH)" 'fail' }
    }

    if ($ourIdx -lt 0) { Write-Check 'PATH entry' 'missing from user PATH' 'fail' }
    elseif (-not $pathOk) { Write-Check 'PATH precedence' 'official agy comes first' 'fail' }
    else { Write-Check 'PATH precedence' 'supervisor first' 'ok' }
    if ($shellStale -and $pathOk) {
        Write-Check 'This shell' 'started before setup - open a new terminal' 'warn'
    }

    # The one thing that must never be true: agy-raw pointing at a wrapper.
    $rawShim = Join-Path $ourBin 'agy-raw.cmd'
    if (Test-Path -LiteralPath $rawShim) {
        $rawBody = Get-Content -LiteralPath $rawShim -Raw
        if ($rawBody -like "*$ourBin*") { Write-Check 'agy-raw target' 'points back at our own bin' 'fail' }
        elseif ($realAgy -and $rawBody -like "*$realAgy*") { Write-Check 'agy-raw target' 'real agy' 'ok' }
        else { Write-Check 'agy-raw target' 'does not match realAgyPath - re-run setup.ps1' 'warn' }
    }

    # -------------------------------------------------------------- plugin --
    Write-Section 'Plugin'
    $pluginDir = Get-AgyPluginInstallPath
    if (Test-Path -LiteralPath $pluginDir) {
        Write-Check 'Installed' $pluginDir 'ok'
        $hooksFile = Join-Path $pluginDir 'hooks.json'
        if (Test-Path -LiteralPath $hooksFile) {
            $hooksOk = $false
            try { $null = Get-Content -LiteralPath $hooksFile -Raw | ConvertFrom-Json; $hooksOk = $true } catch { }
            Write-Check 'hooks.json' $(if ($hooksOk) { 'present, valid JSON' } else { 'INVALID JSON' }) $(if ($hooksOk) { 'ok' } else { 'fail' })
        } else { Write-Check 'hooks.json' 'missing' 'fail' }
        Write-Check 'stop-hook.ps1' $(if (Test-Path (Join-Path $pluginDir 'scripts\stop-hook.ps1')) { 'present' } else { 'missing' }) `
            $(if (Test-Path (Join-Path $pluginDir 'scripts\stop-hook.ps1')) { 'ok' } else { 'fail' })
    } else {
        Write-Check 'Installed' 'not found under ~/.gemini/config/plugins' 'fail'
    }

    # cli.log is the only honest source: `agy plugin validate` reports hooks as
    # "not found" even while it is loading and running them.
    $cliLog = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\cli.log'
    if (Test-Path -LiteralPath $cliLog) {
        $recent = Get-Content -LiteralPath $cliLog -Tail 4000 -ErrorAction SilentlyContinue
        $bad = @($recent | Select-String -Pattern 'Failed to parse hooks for plugin agy-auto-switch' -SimpleMatch)
        $ran = @($recent | Select-String -Pattern 'jsonhook__agy-auto-switch' -SimpleMatch)
        if ((Get-AgyAutoCount $bad) -gt 0) { Write-Check 'Hook parse (cli.log)' 'hooks.json rejected by agy' 'fail' }
        elseif ((Get-AgyAutoCount $ran) -gt 0) { Write-Check 'Hook seen in cli.log' 'yes' 'ok' }
        else { Write-Check 'Hook seen in cli.log' 'not yet (run a turn)' 'info' }
    }

    $lastEvent = Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events\processed') -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lastEvent) { Write-Check 'Last hook event' $lastEvent.LastWriteTime.ToString('yyyy-MM-dd HH:mm') 'ok' }
    else { Write-Check 'Last hook event' 'none recorded yet' 'info' }

    if ($Probe -and $realOk) {
        Write-Check 'Stop probe' 'running one minimal turn...' 'info'
        # A clean stop deliberately writes no event, so the hook is asked to
        # leave a trace line instead. That trace is the proof it ran.
        $probeId = 'doctor-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $env:AGY_AUTO_SESSION = $probeId
        $env:AGY_AUTO_HOOK_TRACE = '1'
        try {
            & $realAgy -p 'Reply with exactly: DOCTOR-PROBE' --print-timeout 2m | Out-Null
        } finally {
            $env:AGY_AUTO_SESSION = $null
            $env:AGY_AUTO_HOOK_TRACE = $null
        }
        $logFile = Get-AgyAutoPath ('logs\{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        $hookLog = Get-Content -LiteralPath $logFile -Tail 100 -ErrorAction SilentlyContinue
        $trace = @($hookLog | Select-String -Pattern $probeId -SimpleMatch | Select-String -Pattern 'stop hook trace' -SimpleMatch)
        if ((Get-AgyAutoCount $trace) -gt 0) {
            Write-Check 'Stop probe' 'PASS - the hook ran and classified the stop' 'ok'
        } else {
            Write-Check 'Stop probe' 'FAIL - no trace from the hook (see agy-auto-doctor skill)' 'fail'
        }
        Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { (Read-AgyAutoJson $_.FullName).session -eq $probeId } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }

    # -------------------------------------------------- credential manager --
    Write-Section 'Credential Manager'
    $liveInfo = Get-AgyCredentialInfo -Target (Get-AgyLiveTarget)
    if ($liveInfo.Present) {
        Write-Check "Target $(Get-AgyLiveTarget)" 'present' 'ok'
        Write-Check 'Blob readable' 'yes' 'ok'
        Write-Check 'Blob length' "$($liveInfo.BlobBytes) bytes" 'info'
        Write-Check 'Blob fingerprint' (Format-AgyFingerprint $liveInfo.Fingerprint) 'info'
        Write-Check 'Last written' $liveInfo.LastWrittenUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') 'info'
        Write-Check 'Secret content' 'NEVER DISPLAYED' 'ok'
    } else {
        Write-Check "Target $(Get-AgyLiveTarget)" 'MISSING - sign in with agy first' 'fail'
    }

    # ------------------------------------------------------------ profiles --
    Write-Section 'Profiles'
    $profiles = @(Get-AgyProfileList)
    if ((Get-AgyAutoCount $profiles) -eq 0) {
        Write-Check 'Registered' 'none - run: agy-auto profile save <name>' 'warn'
    } else {
        foreach ($p in $profiles) {
            $bits = New-Object System.Collections.Generic.List[string]
            if (-not $p.Present) { $bits.Add('NO CREDENTIAL') }
            if (-not $p.Enabled) { $bits.Add('disabled') }
            if ($p.Drifted) { $bits.Add('fingerprint drift') }
            if ($p.Exhausted) { $bits.Add('exhausted until ' + $p.ExhaustedUntil.ToLocalTime().ToString('HH:mm')) }
            $nbits = Get-AgyAutoCount $bits
            $status = if ($nbits -eq 0) { 'OK' } else { $bits -join ', ' }
            $sev = if (-not $p.Present) { 'fail' } elseif ($nbits -eq 0) { 'ok' } else { 'warn' }
            Write-Check $p.Name ("{0}  [{1}]" -f $status, (Format-AgyFingerprint $p.Fingerprint)) $sev
        }
        $cur = Get-AgyCurrentProfile
        Write-Check 'Active profile' ("{0} (matched by {1})" -f $(if ($cur.Name) { $cur.Name } else { 'unknown' }), $cur.Match) `
            $(if ($cur.Name) { 'ok' } else { 'warn' })
    }

    # ----------------------------------------------------------- supervisor --
    Write-Section 'Supervisor'
    foreach ($f in 'agy.cmd', 'agy-auto.cmd', 'agy-raw.cmd') {
        $p = Join-Path $ourBin $f
        Write-Check $f $(if (Test-Path -LiteralPath $p) { 'installed' } else { 'missing' }) $(if (Test-Path -LiteralPath $p) { 'ok' } else { 'fail' })
    }
    # The entry point lives with the plugin, not in the shim directory.
    $entry = Join-Path $pluginDir 'bin\agy-auto.ps1'
    Write-Check 'agy-auto.ps1' $(if (Test-Path -LiteralPath $entry) { 'installed' } else { 'missing' }) `
        $(if (Test-Path -LiteralPath $entry) { 'ok' } else { 'fail' })
    try {
        $probeFile = Get-AgyAutoPath ('.writetest-{0}' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probeFile -Value 'ok' -Encoding utf8
        Remove-Item -LiteralPath $probeFile -Force
        Write-Check 'LOCALAPPDATA writable' (Get-AgyAutoDataRoot) 'ok'
    } catch { Write-Check 'LOCALAPPDATA writable' 'NO' 'fail' }

    $lock = Enter-AgyAutoLock -TimeoutSeconds 2
    if ($null -eq $lock) { Write-Check 'Switch lock' 'held by another process' 'warn' }
    else { Exit-AgyAutoLock $lock; Write-Check 'Switch lock' 'free' 'ok' }

    $stale = @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json' -ErrorAction SilentlyContinue)
    $nstale = Get-AgyAutoCount $stale
    Write-Check 'Unclaimed events' $(if ($nstale) { "$nstale pending" } else { 'none' }) $(if ($nstale) { 'warn' } else { 'ok' })

    # ------------------------------------------------------------- autonomy --
    Write-Section 'Autonomy'
    Write-Check '--dangerously-skip-permissions' $(if ($cfg.autoSkipPermissions) { 'DEFAULT' } else { 'off' }) `
        $(if ($cfg.autoSkipPermissions) { 'ok' } else { 'info' })
    $settings = Read-AgyAutoJson (Get-AgySettingsPath)
    if ($null -eq $settings) { Write-Check 'settings.json' 'not found' 'warn' }
    else {
        function Show-Setting($key, $label, $want) {
            $has = (Get-AgyAutoPropertyNames $settings) -contains $key
            $v = if ($has) { "$($settings.$key)" } else { '(unset)' }
            Write-Check $label $v $(if ($has -and $v -eq $want) { 'ok' } else { 'info' })
        }
        Show-Setting 'toolPermission' 'Tool Permission' 'always-proceed'
        Show-Setting 'artifactReviewPolicy' 'Artifact Review' 'always-proceed'
        Show-Setting 'agentMode' 'Agent Mode' 'accept-edits'
        Show-Setting 'dangerouslySkipPermissions' 'Skip permissions (settings)' 'True'
    }

    # ------------------------------------------------------------ continuity --
    Write-Section 'Continuity'
    $lastCp = Get-ChildItem -LiteralPath (Get-AgyAutoPath 'checkpoints') -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lastCp) {
        $cp = Read-AgyAutoJson $lastCp.FullName
        $tOk = $cp.transcriptPath -and (Test-Path -LiteralPath $cp.transcriptPath)
        Write-Check 'Last checkpoint' $lastCp.LastWriteTime.ToString('yyyy-MM-dd HH:mm') 'ok'
        Write-Check 'transcript accessible' $(if ($tOk) { 'yes' } else { 'no' }) $(if ($tOk) { 'ok' } else { 'warn' })
    } else {
        Write-Check 'Checkpoints' 'none yet' 'info'
    }

    # ----------------------------------------------------------------- quota --
    if ($realOk) {
        Write-Section 'Live quota (active account)'
        $snap = Get-AgyQuotaSnapshot -RealAgyPath $realAgy
        if ($null -eq $snap) { Write-Check 'Query' 'failed' 'warn' }
        else {
            Write-Host (Format-AgyQuotaSnapshot -Snapshot $snap)
            $avail = Test-AgyQuotaAvailable -Snapshot $snap -Floor ([double]$cfg.quotaFloor)
            Write-Check 'Headroom' $(if ($avail) { 'available' } else { 'exhausted' }) $(if ($avail) { 'ok' } else { 'warn' })
        }
    }

    # ---------------------------------------------------------------- result --
    Write-Host ''
    Write-Host 'Result:' -ForegroundColor White
    if ($script:DoctorFail -gt 0) {
        Write-Host ("  NOT READY - {0} failure(s), {1} warning(s)" -f $script:DoctorFail, $script:DoctorWarn) -ForegroundColor Red
        Write-Host ''
        return 1
    }
    if ($script:DoctorWarn -gt 0) {
        Write-Host ("  READY WITH WARNINGS - {0} warning(s)" -f $script:DoctorWarn) -ForegroundColor Yellow
        Write-Host ''
        return 0
    }
    Write-Host '  READY' -ForegroundColor Green
    Write-Host ''
    return 0
}
