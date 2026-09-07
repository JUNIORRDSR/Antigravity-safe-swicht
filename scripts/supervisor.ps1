# supervisor.ps1 - spawns agy, watches for quota events, rotates between runs.
#
# The credential is only ever swapped BETWEEN child processes. agy refreshes its
# own credential while running and caches auth in memory, so a hot swap under a
# live agy.exe would be silently wrong.
#
# The supervisor manages exactly one child: the one it started. Identity is
# checked by PID *and* start time before any termination, so an unrelated agy
# session - or a recycled PID - is never touched.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'credential-manager.ps1')
. (Join-Path $PSScriptRoot 'profile-manager.ps1')
. (Join-Path $PSScriptRoot 'quota.ps1')
. (Join-Path $PSScriptRoot 'handoff.ps1')

$script:AgyStates = @(
    'IDLE', 'STARTING', 'RUNNING', 'QUOTA_DETECTED', 'CHECKPOINTING', 'STOPPING_CHILD',
    'SAVING_CURRENT_PROFILE', 'SWITCHING_PROFILE', 'STARTING_REPLACEMENT',
    'RESUMING', 'HANDOFF', 'FAILED', 'COMPLETED'
)
function Get-AgyStates { $script:AgyStates }

$script:AgyState = 'IDLE'
function Set-AgySupervisorState {
    param([Parameter(Mandatory)][string]$To, [string]$Note = '')
    if ($script:AgyStates -notcontains $To) { throw "Unknown supervisor state '$To'" }
    $from = $script:AgyState
    $script:AgyState = $To
    Write-AgyAutoLog -Message ("state {0} -> {1}{2}" -f $from, $To, $(if ($Note) { " ($Note)" } else { '' }))
}
function Get-AgySupervisorState { $script:AgyState }
function Reset-AgySupervisorState { $script:AgyState = 'IDLE' }

# ------------------------------------------------------------ argument work --

# Flags that consume a following value (Go's flag package also accepts --f=v).
$script:AgyValueFlags = @(
    '--model', '--effort', '--conversation', '--project', '--agent', '--mode',
    '--add-dir', '--input-format', '--output-format', '--json-schema',
    '--log-file', '--print-timeout', '--print', '--prompt', '-p',
    '--prompt-interactive', '-i'
)

function Remove-AgyArgs {
    param(
        [AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string[]]$Names
    )
    $out = New-Object System.Collections.Generic.List[string]
    $count = Get-AgyAutoCount $Arguments
    for ($i = 0; $i -lt $count; $i++) {
        $a = $Arguments[$i]
        $bare = $a
        $hasInline = $false
        if ($a -match '^(--?[^=]+)=') { $bare = $Matches[1]; $hasInline = $true }
        if ($Names -contains $bare) {
            if (-not $hasInline -and $script:AgyValueFlags -contains $bare -and $i + 1 -lt $count) { $i++ }
            continue
        }
        $out.Add($a)
    }
    $out.ToArray()
}

function Test-AgyHasArg {
    param([AllowEmptyCollection()][string[]]$Arguments, [Parameter(Mandatory)][string[]]$Names)
    foreach ($a in @($Arguments)) {
        $bare = if ($a -match '^(--?[^=]+)=') { $Matches[1] } else { $a }
        if ($Names -contains $bare) { return $true }
    }
    $false
}

# Build the real agy command line: autonomy flag first, then the user's own
# arguments untouched.
function Build-AgyChildArgs {
    param(
        [AllowEmptyCollection()][string[]]$UserArgs = @(),
        [switch]$Safe
    )
    $list = @($UserArgs)
    $prefix = @()
    if (-not $Safe) {
        if (-not (Test-AgyHasArg -Arguments $list -Names @('--dangerously-skip-permissions'))) {
            $prefix = @('--dangerously-skip-permissions')
        }
    }
    @($prefix) + @($list)
}

# ------------------------------------------------------------ child process --

# ProcessStartInfo rather than Start-Process: Windows PowerShell 5.1 joins
# -ArgumentList entries with plain spaces, which mangles any argument that
# contains one - the handoff prompt, for instance. Here the command line is
# built with the same quoting rules CommandLineToArgvW parses back.
function Start-AgyChild {
    param(
        [Parameter(Mandatory)][string]$RealAgyPath,
        [AllowEmptyCollection()][string[]]$ChildArgs,
        [Parameter(Mandatory)][string]$SessionId,
        [AllowNull()][string]$ProfileName,
        [Parameter(Mandatory)][string]$Cwd
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $RealAgyPath
    $psi.Arguments = ConvertTo-AgyAutoArgString -Arguments @($ChildArgs)
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false      # inherit this console: agy owns the TUI
    $psi.CreateNoWindow = $false

    # The hook reads these back out of its inherited environment. This is the
    # only correlation channel: workspacePaths arrives empty in print mode.
    $psi.EnvironmentVariables['AGY_AUTO_SESSION'] = $SessionId
    $psi.EnvironmentVariables['AGY_AUTO_SUPERVISOR_PID'] = "$PID"
    $psi.EnvironmentVariables['AGY_AUTO_CWD'] = $Cwd
    if ($ProfileName) { $psi.EnvironmentVariables['AGY_AUTO_PROFILE'] = $ProfileName }

    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    # Taken before Start(): no hook of this child can write an event earlier
    # than this, and every event from the previous child is already older.
    $spawnedAt = (Get-Date).ToUniversalTime()
    if (-not $p.Start()) { throw "Failed to start '$RealAgyPath'" }

    $startTime = $null
    try { $startTime = $p.StartTime } catch { }
    Write-AgyAutoLog -Message ("agy child PID {0} started" -f $p.Id)
    [pscustomobject]@{ Process = $p; Pid = $p.Id; StartTime = $startTime; SpawnedAt = $spawnedAt }
}

# The identity gate: only ever act on the exact process we launched.
function Test-AgyChildIdentity {
    param([Parameter(Mandatory)]$Child)
    $p = Get-Process -Id $Child.Pid -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    if ($null -eq $Child.StartTime) { return $true }
    try { return ($p.StartTime -eq $Child.StartTime) } catch { return $false }
}

# ponytail: a console child sharing our console has no window to close and
# cannot be sent Ctrl+C without hitting this process too, so the clean attempt
# usually times out and termination follows. That is acceptable only because
# every precondition below is already satisfied.
function Stop-AgyChild {
    param(
        [Parameter(Mandatory)]$Child,
        [int]$TimeoutSeconds = 10,
        [switch]$CheckpointReady
    )
    if ($Child.Process.HasExited) { return $true }

    try { [void]$Child.Process.CloseMainWindow() } catch { }
    if ($Child.Process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-AgyAutoLog -Message ("agy child PID {0} exited" -f $Child.Pid)
        return $true
    }

    # Forced termination is a last resort, and only once continuity is on disk.
    if (-not $CheckpointReady) {
        Write-AgyAutoLog -Level WARN -Message ("child PID {0} still running but no checkpoint yet; not terminating" -f $Child.Pid)
        return $false
    }
    if (-not (Test-AgyChildIdentity -Child $Child)) {
        Write-AgyAutoLog -Level WARN -Message ("PID {0} is no longer our child; leaving it alone" -f $Child.Pid)
        return $false
    }
    try {
        $Child.Process.Kill()
        [void]$Child.Process.WaitForExit(5000)
        Write-AgyAutoLog -Level WARN -Message ("agy child PID {0} terminated after clean shutdown timed out" -f $Child.Pid)
        $true
    } catch {
        Write-AgyAutoLog -Level ERROR -Message ("could not stop child PID {0}" -f $Child.Pid)
        $false
    }
}

# ------------------------------------------------------------------ events ---

# -Since is the current child's spawn instant. A quota error raised by the
# child we already replaced says nothing about the credential now in use, and
# one dying agy emits one event per conversation - the agent's own plus every
# sub-agent's - so the queue routinely outlives its author. Without this gate
# the first leftover is read back as a fresh hit and drains the new profile.
function Get-AgyPendingEvent {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [AllowNull()][Nullable[datetime]]$Since
    )
    $dir = Get-AgyAutoPath 'events'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name) {
        $e = Read-AgyAutoJson $f.FullName
        if ($null -eq $e) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        if ($e.session -ne $SessionId) { continue }   # another supervisor's event
        if ($null -ne $Since) {
            # A missing or unreadable createdAt is treated as stale: an event
            # that cannot prove it belongs to the live child must not rotate it.
            $created = $null
            try { $created = ([datetime]$e.createdAt).ToUniversalTime() } catch { }
            if ($null -eq $created -or $created -lt $Since) {
                Write-AgyAutoLog -Message ("ignoring event from a previous child: {0}" -f $f.Name)
                Complete-AgyEvent -Path $f.FullName
                continue
            }
        }
        return [pscustomobject]@{ File = $f.FullName; Data = $e }
    }
    $null
}

function Complete-AgyEvent {
    param([Parameter(Mandatory)][string]$Path)
    $done = Get-AgyAutoPath 'events\processed'
    if (-not (Test-Path -LiteralPath $done)) { New-Item -ItemType Directory -Force -Path $done | Out-Null }
    try { Move-Item -LiteralPath $Path -Destination (Join-Path $done (Split-Path -Leaf $Path)) -Force }
    catch { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Clear-AgySessionEvents {
    param([Parameter(Mandatory)][string]$SessionId)
    while ($true) {
        $e = Get-AgyPendingEvent -SessionId $SessionId
        if ($null -eq $e) { break }
        Complete-AgyEvent -Path $e.File
    }
}

# An event whose supervisor died - a crash, a Ctrl+C, a rotation that gave up -
# carries a session id that can never match again, so nothing will ever consume
# it. Left alone they accumulate and every 500ms poll of every future run reads
# past them. Anything this old is abandoned by definition: a live supervisor
# picks its events up within a second.
function Clear-AgyOrphanEvents {
    param([int]$OlderThanHours = 1)
    $dir = Get-AgyAutoPath 'events'
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-[Math]::Abs($OlderThanHours))
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue) {
        $e = Read-AgyAutoJson $f.FullName
        $created = $null
        if ($null -ne $e) { try { $created = ([datetime]$e.createdAt).ToUniversalTime() } catch { } }
        if ($null -eq $created) { $created = $f.LastWriteTimeUtc }
        if ($created -lt $cutoff) { Complete-AgyEvent -Path $f.FullName; $n++ }
    }
    if ($n -gt 0) { Write-AgyAutoLog -Message ("archived {0} orphaned event(s)" -f $n) }
    $n
}

# --------------------------------------------------------------- reporting ---

function Write-AgyExhaustedReport {
    param([AllowEmptyCollection()]$Profiles)
    Write-Host ''
    Write-Host 'All profiles are temporarily exhausted.' -ForegroundColor Yellow
    Write-Host ''
    $next = $null
    foreach ($p in @($Profiles)) {
        $when = if ($p.ExhaustedUntil) { $p.ExhaustedUntil.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
        $flag = if (-not $p.Enabled) { 'disabled' } elseif (-not $p.Present) { 'no credential' } else { "until $when" }
        Write-Host ('  {0,-16} {1}' -f $p.Name, $flag)
        if ($p.Enabled -and $p.Present -and $p.ExhaustedUntil) {
            if ($null -eq $next -or $p.ExhaustedUntil -lt $next.ExhaustedUntil) { $next = $p }
        }
    }
    Write-Host ''
    if ($next) {
        Write-Host ('  Next available: {0} at {1}' -f $next.Name, $next.ExhaustedUntil.ToLocalTime().ToString('HH:mm')) -ForegroundColor Cyan
    } else {
        Write-Host '  No profile has a known reset time. Run: agy-auto doctor' -ForegroundColor Cyan
    }
    Write-Host ''
}

# ------------------------------------------------------------- main routine --

function Start-AgySupervisor {
    [CmdletBinding()]
    param(
        [ValidateSet('tui', 'run')][string]$Mode = 'tui',
        [AllowEmptyCollection()][string[]]$AgyArgs = @(),
        [switch]$Safe
    )

    Initialize-AgyAutoDirs
    Reset-AgySupervisorState
    $cfg = Get-AgyAutoConfig
    $cwd = (Get-Location).Path

    $realAgy = Resolve-AgyAutoRealAgy
    if (-not $realAgy) {
        Write-Host 'agy-auto: cannot find the real Antigravity CLI. Run setup.ps1, or agy-auto doctor.' -ForegroundColor Red
        return 127
    }
    if ($cfg.realAgyPath -ne $realAgy) { $cfg.realAgyPath = $realAgy; Set-AgyAutoConfig $cfg }

    $sessionId = [guid]::NewGuid().ToString()
    Clear-AgySessionEvents -SessionId $sessionId
    Clear-AgyOrphanEvents | Out-Null
    Clear-AgyExpiredExhaustion | Out-Null

    $current = Get-AgyCurrentProfile
    $profileName = $current.Name

    if (-not $cfg.enabled) {
        Write-AgyAutoStatus 'auto-switch disabled; running agy without rotation'
    } else {
        Write-AgyAutoStatus ('profile: {0}' -f $(if ($profileName) { $profileName } else { '(unregistered)' }))
        Write-AgyAutoStatus 'supervisor active'
    }

    $childArgs = Build-AgyChildArgs -UserArgs $AgyArgs -Safe:$Safe
    $switches = 0
    $exitCode = 0
    $pendingChild = $null

    Set-AgySupervisorState 'STARTING'

    while ($true) {
        if ($null -ne $pendingChild) {
            $child = $pendingChild            # already started by the resume probe
            $pendingChild = $null
        } else {
            $child = Start-AgyChild -RealAgyPath $realAgy -ChildArgs $childArgs `
                -SessionId $sessionId -ProfileName $profileName -Cwd $cwd
        }
        Set-AgySupervisorState 'RUNNING'

        # ---- watch ----------------------------------------------------------
        $quotaEvent = $null
        while ($true) {
            if ($child.Process.WaitForExit(500)) {
                # The hook runs before the process exits, but give the event
                # file a moment to land before concluding there is none.
                $pending = Get-AgyPendingEvent -SessionId $sessionId -Since $child.SpawnedAt
                if ($null -eq $pending) { Start-Sleep -Milliseconds 400; $pending = Get-AgyPendingEvent -SessionId $sessionId -Since $child.SpawnedAt }
                if ($null -ne $pending -and $pending.Data.shouldRotate) { $quotaEvent = $pending }
                elseif ($null -ne $pending) {
                    Write-AgyAutoLog -Message ("non-rotating event: {0}" -f $pending.Data.category)
                    Complete-AgyEvent -Path $pending.File
                }
                break
            }
            $pending = Get-AgyPendingEvent -SessionId $sessionId -Since $child.SpawnedAt
            if ($null -eq $pending) { continue }
            if (-not $pending.Data.shouldRotate) {
                if ($pending.Data.category -eq 'AUTH_ERROR') {
                    Write-AgyAutoStatus 'authentication error - not rotating (a bad credential would break the next profile too)'
                }
                Complete-AgyEvent -Path $pending.File
                continue
            }
            $quotaEvent = $pending
            break
        }

        if ($child.Process.HasExited) { $exitCode = $child.Process.ExitCode }

        if ($null -eq $quotaEvent) {
            Set-AgySupervisorState 'COMPLETED' 'child finished without a quota event'
            break
        }

        # ---- quota ----------------------------------------------------------
        Set-AgySupervisorState 'QUOTA_DETECTED'
        Write-AgyAutoStatus 'quota detected'
        if (-not $cfg.enabled) {
            Complete-AgyEvent -Path $quotaEvent.File
            Write-AgyAutoStatus 'auto-switch is disabled; stopping here'
            break
        }

        $switches++
        if ($switches -gt [int]$cfg.maxConsecutiveSwitches) {
            Complete-AgyEvent -Path $quotaEvent.File
            Write-AgyAutoStatus ("reached maxConsecutiveSwitches ({0}); stopping to avoid a rotation loop" -f $cfg.maxConsecutiveSwitches)
            Set-AgySupervisorState 'FAILED' 'switch budget exhausted'
            $exitCode = 75
            break
        }

        Set-AgySupervisorState 'CHECKPOINTING'
        $checkpoint = New-AgyCheckpoint -Event $quotaEvent.Data -Cwd $cwd -FromProfile $profileName
        $transcriptOk = $quotaEvent.Data.transcriptPath -and (Test-Path -LiteralPath $quotaEvent.Data.transcriptPath)
        Complete-AgyEvent -Path $quotaEvent.File
        Write-AgyAutoStatus 'checkpoint stored'

        Set-AgySupervisorState 'STOPPING_CHILD'
        $stopped = Stop-AgyChild -Child $child -TimeoutSeconds ([int]$cfg.childShutdownTimeoutSeconds) -CheckpointReady:$true
        if (-not $stopped) {
            Write-AgyAutoStatus 'could not stop the current agy session safely; not switching'
            Set-AgySupervisorState 'FAILED' 'child would not stop'
            $exitCode = 1
            break
        }
        if (-not $transcriptOk) {
            Write-AgyAutoLog -Level WARN -Message 'transcript path from the hook is not readable; handoff will rely on git only'
        }

        # ---- mark the drained profile ---------------------------------------
        Set-AgySupervisorState 'SAVING_CURRENT_PROFILE'
        if ($profileName) {
            $until = $null
            if ($quotaEvent.Data.resetAt) { try { $until = ([datetime]$quotaEvent.Data.resetAt).ToUniversalTime() } catch { } }
            if ($null -eq $until) { $until = (Get-Date).ToUniversalTime().AddHours(1) }
            Set-AgyProfileExhausted -Name $profileName -Until $until | Out-Null
            Write-AgyAutoStatus ("{0} unavailable until {1}" -f $profileName, $until.ToLocalTime().ToString('HH:mm'))
        }

        # ---- pick and verify a successor ------------------------------------
        Set-AgySupervisorState 'SWITCHING_PROFILE'
        $switched = $null
        $tried = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $candidate = Get-AgyNextProfile -AfterProfile $profileName
            if ($null -eq $candidate -or $tried.Contains($candidate.Name)) { break }
            $tried.Add($candidate.Name)

            try { $result = Switch-AgyProfile -To $candidate.Name }
            catch {
                Write-AgyAutoStatus ("switch to {0} failed and was rolled back" -f $candidate.Name)
                continue
            }

            # Verified selection: ask agy itself whether this account has room.
            # Free - no turn, no conversation, no tokens.
            $snap = Get-AgyQuotaSnapshot -RealAgyPath $realAgy
            $avail = Test-AgyQuotaAvailable -Snapshot $snap -Floor ([double]$cfg.quotaFloor)
            if ($avail -eq $false) {
                $nextReset = Get-AgyQuotaNextReset -Snapshot $snap -Floor ([double]$cfg.quotaFloor)
                if ($null -eq $nextReset) { $nextReset = (Get-Date).ToUniversalTime().AddHours(1) }
                Set-AgyProfileExhausted -Name $candidate.Name -Until $nextReset | Out-Null
                Write-AgyAutoStatus ("{0} is already out of quota; trying the next profile" -f $candidate.Name)
                continue
            }
            if ($null -eq $avail) {
                Write-AgyAutoLog -Level WARN -Message "could not read quota for '$($candidate.Name)'; proceeding anyway"
            }
            $switched = $result
            break
        }

        if ($null -eq $switched) {
            Write-AgyExhaustedReport -Profiles (Get-AgyProfileList)
            Set-AgySupervisorState 'FAILED' 'no profile available'
            $exitCode = 75
            break
        }

        $previousProfile = $profileName
        $profileName = $switched.To
        Write-AgyAutoStatus ("switching {0} -> {1}" -f $(if ($previousProfile) { $previousProfile } else { '(unknown)' }), $profileName)

        # ---- resume, or hand off --------------------------------------------
        Set-AgySupervisorState 'STARTING_REPLACEMENT'
        $conversationId = $quotaEvent.Data.conversationId
        $base = Remove-AgyArgs -Arguments $AgyArgs `
            -Names @('--conversation', '-c', '--continue', '-p', '--print', '--prompt', '-i', '--prompt-interactive')

        $resumed = $false
        if ($cfg.resumeStrategy -eq 'try-original-then-handoff' -and $conversationId) {
            Set-AgySupervisorState 'RESUMING'
            $probeArgs = Build-AgyChildArgs -UserArgs (@($base) + @('--conversation', $conversationId)) -Safe:$Safe
            $probe = Start-AgyChild -RealAgyPath $realAgy -ChildArgs $probeArgs `
                -SessionId $sessionId -ProfileName $profileName -Cwd $cwd

            # A conversation the new account cannot open fails fast and non-zero.
            if ($probe.Process.WaitForExit([int]$cfg.resumeProbeSeconds * 1000) -and $probe.Process.ExitCode -ne 0) {
                Write-AgyAutoStatus 'resume original conversation rejected; using handoff'
            } else {
                Write-AgyAutoStatus 'resuming task...'
                $pendingChild = $probe
                $childArgs = $probeArgs
                $resumed = $true
            }
        }

        if (-not $resumed) {
            Set-AgySupervisorState 'HANDOFF'
            $handoff = New-AgyHandoff -Checkpoint $checkpoint -ToProfile $profileName
            Write-AgyAutoStatus ("handoff written: {0}" -f $handoff.Path)
            $promptFlag = if ($Mode -eq 'run') { '-p' } else { '-i' }
            $childArgs = Build-AgyChildArgs -UserArgs (@($base) + @($promptFlag, $handoff.Prompt)) -Safe:$Safe
            Write-AgyAutoStatus 'starting replacement session'
        }
    }

    $exitCode
}
