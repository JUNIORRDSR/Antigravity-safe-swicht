. (Join-Path $global:AgyTestRepoRoot 'scripts\supervisor.ps1')

Describe 'argument handling - autonomy flag' {
    It 'prepends --dangerously-skip-permissions by default' {
        $a = Build-AgyChildArgs -UserArgs @()
        Assert-Equal '--dangerously-skip-permissions' ($a -join ' ')
    }
    It 'keeps the user arguments after it, in order' {
        $a = Build-AgyChildArgs -UserArgs @('--continue')
        Assert-Equal '--dangerously-skip-permissions --continue' ($a -join ' ')
    }
    It 'does not duplicate the flag when the user already passed it' {
        $a = Build-AgyChildArgs -UserArgs @('--dangerously-skip-permissions', '--continue')
        Assert-Equal 1 (@($a | Where-Object { $_ -eq '--dangerously-skip-permissions' }).Count)
    }
    It '--safe suppresses the flag but keeps everything else' {
        $a = Build-AgyChildArgs -UserArgs @('--continue') -Safe
        Assert-Equal '--continue' ($a -join ' ')
    }
    It 'survives the one case that produces no arguments at all: agy --safe' {
        # The result is legitimately empty here, and an empty array unrolls to
        # $null on assignment - everything downstream has to cope.
        $a = Build-AgyChildArgs -UserArgs @() -Safe
        Assert-Equal 0 (Get-AgyAutoCount $a)
        $line = ConvertTo-AgyAutoArgString -Arguments @($a)
        Assert-Equal '' $line
        Assert-Equal 0 (Get-AgyAutoCount (ConvertFrom-AgyAutoCommandLine $line))
    }
    It 'preserves a prompt containing spaces as one argument' {
        $a = Build-AgyChildArgs -UserArgs @('-p', 'continua implementando MOB-02')
        Assert-Equal 3 $a.Count
        Assert-Equal 'continua implementando MOB-02' $a[2]
    }
}

Describe 'argument handling - stripping flags for the replacement session' {
    It 'removes --conversation together with its value' {
        $a = Remove-AgyArgs -Arguments @('--model', 'x', '--conversation', 'abc123', '--effort', 'high') -Names @('--conversation')
        Assert-Equal '--model x --effort high' ($a -join ' ')
    }
    It 'removes the --flag=value form too' {
        $a = Remove-AgyArgs -Arguments @('--conversation=abc123', '--effort', 'high') -Names @('--conversation')
        Assert-Equal '--effort high' ($a -join ' ')
    }
    It 'removes valueless flags without eating the next argument' {
        $a = Remove-AgyArgs -Arguments @('-c', '--model', 'x') -Names @('-c', '--continue')
        Assert-Equal '--model x' ($a -join ' ')
    }
    It 'removes a print prompt together with its text' {
        $a = Remove-AgyArgs -Arguments @('-p', 'do the thing', '--model', 'x') -Names @('-p')
        Assert-Equal '--model x' ($a -join ' ')
    }
    It 'leaves unrelated arguments alone' {
        $a = Remove-AgyArgs -Arguments @('--add-dir', 'C:\repo', '--sandbox') -Names @('--conversation')
        Assert-Equal '--add-dir C:\repo --sandbox' ($a -join ' ')
    }
}

Describe 'argument handling - exact quoting through the shim' {
    # The shim hands over the raw command-line tail; this is the round trip that
    # has to be lossless, or a prompt with quotes silently changes meaning.
    foreach ($case in @(
            , @('simple')
            , @('-p', 'hello world')
            , @('-p', 'a "quoted" word')
            , @('--add-dir', 'C:\Program Files\repo')
            , @('-p', 'ends with backslash\')
            , @('-p', 'path "C:\a b\c" end')
            , @('-p', '')
        )) {
        It ("round-trips: " + ($case -join ' | ')) {
            $line = ConvertTo-AgyAutoArgString -Arguments $case
            $back = ConvertFrom-AgyAutoCommandLine $line
            Assert-Equal ($case -join "`u{1}") ($back -join "`u{1}")
        }
    }
}

Describe 'scenario M: the supervisor only ever touches its own child' {
    It 'accepts its own child and rejects an unrelated agy-like process' {
        $mine = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden
        $other = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden
        try {
            $child = [pscustomobject]@{ Process = $mine; Pid = $mine.Id; StartTime = $mine.StartTime }
            Assert-True (Test-AgyChildIdentity -Child $child) 'our own child must be recognised'

            # Same shape, different PID: this is the other session we must not touch.
            $imposter = [pscustomobject]@{ Process = $other; Pid = $other.Id; StartTime = $mine.StartTime }
            Assert-False (Test-AgyChildIdentity -Child $imposter) 'a different process must never match'

            Assert-True ($mine.Id -ne $other.Id)
            Assert-False $other.HasExited 'the unrelated process must still be running'
        } finally {
            foreach ($p in $mine, $other) { try { $p.Kill() } catch { } }
        }
    }
    It 'reports a recycled or vanished PID as not ours' {
        $p = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden
        $p.WaitForExit(10000) | Out-Null
        $child = [pscustomobject]@{ Process = $p; Pid = $p.Id; StartTime = $p.StartTime }
        Assert-False (Test-AgyChildIdentity -Child $child)
    }
    It 'refuses to terminate when no checkpoint has been written' {
        $p = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden
        try {
            $child = [pscustomobject]@{ Process = $p; Pid = $p.Id; StartTime = $p.StartTime }
            Assert-False (Stop-AgyChild -Child $child -TimeoutSeconds 1) 'no checkpoint means no forced kill'
            Assert-False $p.HasExited 'the child must still be alive'
        } finally { try { $p.Kill() } catch { } }
    }
    It 'terminates its own child once a checkpoint exists' {
        $p = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden
        $child = [pscustomobject]@{ Process = $p; Pid = $p.Id; StartTime = $p.StartTime }
        Assert-True (Stop-AgyChild -Child $child -TimeoutSeconds 1 -CheckpointReady)
        Assert-True $p.HasExited
    }
}

Describe 'supervisor state machine' {
    It 'knows every state the design calls for' {
        foreach ($s in 'IDLE', 'STARTING', 'RUNNING', 'QUOTA_DETECTED', 'CHECKPOINTING', 'STOPPING_CHILD',
            'SAVING_CURRENT_PROFILE', 'SWITCHING_PROFILE', 'STARTING_REPLACEMENT', 'RESUMING',
            'HANDOFF', 'FAILED', 'COMPLETED') {
            Assert-True ((Get-AgyStates) -contains $s) "missing state $s"
        }
    }
    It 'records transitions' {
        Reset-AgySupervisorState
        Assert-Equal 'IDLE' (Get-AgySupervisorState)
        Set-AgySupervisorState 'STARTING'
        Assert-Equal 'STARTING' (Get-AgySupervisorState)
        Set-AgySupervisorState 'RUNNING'
        Assert-Equal 'RUNNING' (Get-AgySupervisorState)
    }
    It 'rejects a state that is not in the machine' {
        Assert-Throws { Set-AgySupervisorState 'TELEPORTING' }
    }
}

Describe 'event routing between concurrent supervisors' {
    It 'only picks up events belonging to its own session' {
        Initialize-AgyAutoDirs
        Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json' | Remove-Item -Force
        foreach ($s in 'session-A', 'session-B') {
            Write-AgyAutoFileAtomic -Path (Get-AgyAutoPath "events\ev-$s.json") `
                -Content (ConvertTo-AgyAutoJson ([ordered]@{ session = $s; shouldRotate = $true; category = 'INDIVIDUAL_QUOTA' }))
        }
        Assert-Equal 'session-A' (Get-AgyPendingEvent -SessionId 'session-A').Data.session
        Assert-Equal 'session-B' (Get-AgyPendingEvent -SessionId 'session-B').Data.session
        Assert-Null (Get-AgyPendingEvent -SessionId 'session-C') 'a third supervisor must see nothing'
    }
    It 'does not re-deliver an event once it has been handled' {
        Initialize-AgyAutoDirs
        Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json' | Remove-Item -Force
        Write-AgyAutoFileAtomic -Path (Get-AgyAutoPath 'events\ev-once.json') `
            -Content (ConvertTo-AgyAutoJson ([ordered]@{ session = 'once'; shouldRotate = $true }))
        $e = Get-AgyPendingEvent -SessionId 'once'
        Assert-NotNull $e
        Complete-AgyEvent -Path $e.File
        Assert-Null (Get-AgyPendingEvent -SessionId 'once')
    }
}
