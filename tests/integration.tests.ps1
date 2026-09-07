# End-to-end exercise of the supervisor loop against a stand-in agy.
# Real stop hook, real classifier, real switch transaction, real handoff -
# only the CLI itself and the credential store are substituted.

. (Join-Path $global:AgyTestRepoRoot 'scripts\supervisor.ps1')

$script:FakeDir = Join-Path $env:LOCALAPPDATA 'fake-agy'
$script:FakeCmd = Join-Path $script:FakeDir 'fake-agy.cmd'

function Initialize-FakeAgy {
    if (Test-Path -LiteralPath $script:FakeDir) { Remove-Item -LiteralPath $script:FakeDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:FakeDir | Out-Null
    $ps1 = Join-Path $global:AgyTestRepoRoot 'tests\fake-agy.ps1'
    $body = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    Set-Content -LiteralPath $script:FakeCmd -Value $body -Encoding ascii
    $env:FAKE_AGY_DIR = $script:FakeDir
    $env:FAKE_AGY_HOOK = Join-Path $global:AgyTestRepoRoot 'scripts'
}

function New-TestBlob([int]$Size = 503) {
    $b = New-Object byte[] $Size
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    , $b
}

function Reset-World {
    Reset-AgyCredentialMemoryStore
    foreach ($f in 'state.json', 'config.json') {
        $p = Get-AgyAutoPath $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($d in 'events', 'events\processed', 'checkpoints', 'handoffs') {
        $p = Get-AgyAutoPath $d
        if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -File | Remove-Item -Force }
    }
    Initialize-FakeAgy

    $blobs = @{}
    foreach ($name in 'alpha', 'beta') {
        $blobs[$name] = New-TestBlob
        Set-AgyCredential -Target (Get-AgyLiveTarget) -Blob $blobs[$name] -UserName 'antigravity' -Persist 2
        [void](Save-AgyProfile -Name $name)
    }
    # Sign back in as alpha.
    Set-AgyCredential -Target (Get-AgyLiveTarget) -Blob $blobs['alpha'] -UserName 'antigravity' -Persist 2
    $st = Get-AgyAutoState; $st.activeProfile = 'alpha'; Set-AgyAutoState $st

    $cfg = Get-AgyAutoConfig
    $cfg.realAgyPath = $script:FakeCmd
    $cfg.resumeProbeSeconds = 15
    $cfg.childShutdownTimeoutSeconds = 3
    Set-AgyAutoConfig $cfg
    $blobs
}

function Arm-Quota([string]$Fixture = 'quota-exact.json') {
    Set-Content -LiteralPath (Join-Path $script:FakeDir 'emit-quota.txt') `
        -Value (Join-Path $PSScriptRoot ('fixtures\' + $Fixture)) -Encoding ascii
}
function Set-ResumeMode([string]$Mode) {
    Set-Content -LiteralPath (Join-Path $script:FakeDir 'resume-mode.txt') -Value $Mode -Encoding ascii
}
function Get-Invocations {
    $f = Join-Path $script:FakeDir 'invocations.log'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    @(Get-Content -LiteralPath $f)
}
function Get-LiveFp {
    $c = Get-AgyCredential -Target (Get-AgyLiveTarget)
    if ($null -eq $c) { return $null }
    Get-AgyBlobFingerprint $c.Blob
}

Describe 'integration: quota -> checkpoint -> switch -> handoff -> resume work' {
    It 'runs the whole recovery without human intervention' {
        $blobs = Reset-World
        Arm-Quota
        Set-ResumeMode 'reject'

        $exit = Start-AgySupervisor -Mode run -AgyArgs @('-p', 'build the thing')

        Assert-Equal 0 $exit 'the supervisor should finish cleanly'
        Assert-Equal 'COMPLETED' (Get-AgySupervisorState)

        # The account actually changed, and to the right one.
        Assert-Equal (Get-AgyBlobFingerprint $blobs['beta']) (Get-LiveFp) 'the live credential must now be beta'
        Assert-Equal 'beta' (Get-AgyAutoState).activeProfile

        # The drained account is parked with the reset time from the error text.
        $alpha = Get-AgyProfileList | Where-Object { $_.Name -eq 'alpha' }
        Assert-True $alpha.Exhausted 'alpha must be marked exhausted'
        $mins = ($alpha.ExhaustedUntil - (Get-Date).ToUniversalTime()).TotalMinutes
        Assert-True ($mins -gt 60 -and $mins -lt 70) "reset should be ~64 min out, was $mins"

        # Continuity artefacts exist.
        Assert-True (@(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'checkpoints') -Filter '*.json').Count -ge 1) 'a checkpoint must be stored'
        Assert-True (@(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'handoffs') -Filter '*.md').Count -ge 1) 'a handoff must be written'
    }

    It 'launches the child with autonomy on and the user arguments intact' {
        $inv = Get-Invocations
        Assert-Match 'dangerously-skip-permissions' $inv[0]
        Assert-Match 'build the thing' $inv[0]
    }

    It 'verifies the candidate account has quota before committing to it' {
        Assert-True (@(Get-Invocations | Where-Object { $_ -match '/quota' }).Count -ge 1) 'the supervisor must ask agy for quota'
    }

    It 'tries the original conversation first, then falls back to handoff' {
        $inv = Get-Invocations
        $resumeIdx = [array]::FindIndex($inv, [Predicate[string]] { param($x) $x -match '--conversation' })
        Assert-True ($resumeIdx -ge 0) 'a resume attempt must happen'
        # The run after the rejected resume carries the handoff prompt.
        $handoffRun = @($inv | Where-Object { $_ -match 'interrupted because the previous' -or $_ -match 'handoff' })
        Assert-True ((Get-AgyAutoCount $handoffRun) -ge 1) 'the replacement run must carry the handoff prompt'
    }

    It 'consumes the quota event exactly once' {
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json').Count 'no event may be left pending'
        Assert-True (@(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events\processed') -Filter '*.json').Count -ge 1) 'the event must be archived'
    }

    It 'never wrote a secret into any artefact it produced' {
        $files = @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'checkpoints') -Filter '*.json') +
                 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'handoffs') -Filter '*.md') +
                 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events\processed') -Filter '*.json') +
                 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'logs') -Filter '*.log')
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            Assert-NoMatch 'ya29\.' $raw $f.Name
            Assert-NoMatch '(?i)credentialblob\s*[:=]\s*[A-Za-z0-9]' $raw $f.Name
            Assert-NoMatch '(?i)refresh_token\s*[:=]\s*[A-Za-z0-9]' $raw $f.Name
        }
    }
}

Describe 'integration: the original conversation still works under the new account' {
    It 'resumes instead of handing off' {
        $blobs = Reset-World
        Arm-Quota
        Set-ResumeMode 'accept'

        $exit = Start-AgySupervisor -Mode run -AgyArgs @('-p', 'keep going')

        Assert-Equal 0 $exit
        Assert-Equal (Get-AgyBlobFingerprint $blobs['beta']) (Get-LiveFp)
        Assert-True (@(Get-Invocations | Where-Object { $_ -match '--conversation' }).Count -ge 1) 'it must try the original conversation'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'handoffs') -Filter '*.md').Count 'a successful resume needs no handoff'
    }
}

Describe 'integration: scenario L - every account is out of quota' {
    It 'reports and stops instead of looping' {
        $blobs = Reset-World
        Arm-Quota
        # Every account answers "no quota left" when asked.
        Set-Content -LiteralPath (Join-Path $script:FakeDir 'quota-all.txt') -Value '0' -Encoding ascii

        $exit = Start-AgySupervisor -Mode run -AgyArgs @('-p', 'build the thing')

        Assert-Equal 75 $exit 'a dedicated exit code, not a hang and not a loop'
        Assert-Equal 'FAILED' (Get-AgySupervisorState)
        foreach ($n in 'alpha', 'beta') {
            Assert-True (Get-AgyProfileList | Where-Object { $_.Name -eq $n }).Exhausted "$n must be marked exhausted"
        }
        # Rotation reverted to nothing usable, but a credential is still installed.
        Assert-NotNull (Get-LiveFp) 'the machine must not be left signed out'
    }
}

Describe 'integration: a normal session is left completely alone' {
    It 'does not switch when the run ends without a quota error' {
        $blobs = Reset-World
        Set-ResumeMode 'reject'

        $exit = Start-AgySupervisor -Mode run -AgyArgs @('-p', 'small task')

        Assert-Equal 0 $exit
        Assert-Equal 'COMPLETED' (Get-AgySupervisorState)
        Assert-Equal (Get-AgyBlobFingerprint $blobs['alpha']) (Get-LiveFp) 'the account must not change'
        Assert-Equal 'alpha' (Get-AgyAutoState).activeProfile
        Assert-Equal 1 @(Get-Invocations).Count 'exactly one child, no rotation machinery'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Get-AgyAutoPath 'handoffs') -Filter '*.md').Count
    }
}

Describe 'integration: rotation is disabled' {
    It 'detects quota but changes nothing' {
        $blobs = Reset-World
        $cfg = Get-AgyAutoConfig; $cfg.enabled = $false; Set-AgyAutoConfig $cfg
        Arm-Quota

        [void](Start-AgySupervisor -Mode run -AgyArgs @('-p', 'build the thing'))

        Assert-Equal (Get-AgyBlobFingerprint $blobs['alpha']) (Get-LiveFp) 'disabled means no switch'
        Assert-False (Get-AgyProfileList | Where-Object { $_.Name -eq 'alpha' }).Exhausted
    }
}
