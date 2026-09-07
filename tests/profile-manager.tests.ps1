. (Join-Path $global:AgyTestRepoRoot 'scripts\profile-manager.ps1')

function New-TestBlob([int]$Size = 503) {
    $b = New-Object byte[] $Size
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    , $b
}

function Reset-TestWorld {
    Reset-AgyCredentialMemoryStore
    foreach ($f in 'state.json', 'config.json') {
        $p = Get-AgyAutoPath $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
}

function Set-LiveBlob([byte[]]$Blob) {
    Set-AgyCredential -Target (Get-AgyLiveTarget) -Blob $Blob -UserName 'antigravity' -Persist 2
}

function Get-LiveFingerprint {
    $c = Get-AgyCredential -Target (Get-AgyLiveTarget)
    if ($null -eq $c) { return $null }
    Get-AgyBlobFingerprint $c.Blob
}

Describe 'profiles - saving' {
    It 'stores the live credential under a namespaced target' {
        Reset-TestWorld
        $a = New-TestBlob
        Set-LiveBlob $a
        $r = Save-AgyProfile -Name 'personal'
        Assert-Equal (Get-AgyBlobFingerprint $a) $r.Fingerprint
        Assert-Equal 503 $r.BlobBytes
        Assert-NotNull (Get-AgyCredential -Target (Get-AgyProfileTarget 'personal'))
    }
    It 'refuses to save when nothing is signed in' {
        Reset-TestWorld
        Assert-Throws { Save-AgyProfile -Name 'personal' }
    }
    It 'rejects a name that could escape the target namespace' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob)
        Assert-Throws { Save-AgyProfile -Name 'a:b' }
        Assert-Throws { Save-AgyProfile -Name '../evil' }
    }
    It 'records the profile in the rotation order' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob)
        [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob)
        [void](Save-AgyProfile -Name 'work')
        Assert-Equal 'personal work' ((Get-AgyAutoConfig).profileOrder -join ' ')
    }
}

Describe 'profiles - identifying the active account' {
    It 'matches by fingerprint' {
        Reset-TestWorld
        $a = New-TestBlob
        Set-LiveBlob $a
        [void](Save-AgyProfile -Name 'personal')
        $cur = Get-AgyCurrentProfile
        Assert-Equal 'personal' $cur.Name
        Assert-Equal 'fingerprint' $cur.Match
    }
    It 'falls back to recorded state when agy has refreshed the credential' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob)
        [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob)     # agy rotated its own token
        $cur = Get-AgyCurrentProfile
        Assert-Equal 'personal' $cur.Name
        Assert-Equal 'state-drifted' $cur.Match
    }
}

Describe 'profiles - selection and exhaustion' {
    It 'skips a profile that is exhausted' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'work')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'other')
        [void](Set-AgyProfileExhausted -Name 'work' -Until ((Get-Date).ToUniversalTime().AddHours(1)))
        Assert-Equal 'other' (Get-AgyNextProfile -AfterProfile 'personal').Name
    }
    It 'never returns the profile being left behind' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'work')
        Assert-Equal 'work' (Get-AgyNextProfile -AfterProfile 'personal').Name
        Assert-Equal 'personal' (Get-AgyNextProfile -AfterProfile 'work').Name
    }
    It 'scenario L: returns nothing when every profile is exhausted, instead of looping' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'work')
        $until = (Get-Date).ToUniversalTime().AddHours(2)
        [void](Set-AgyProfileExhausted -Name 'personal' -Until $until)
        [void](Set-AgyProfileExhausted -Name 'work' -Until $until)
        Assert-Null (Get-AgyNextProfile -AfterProfile 'personal')
        Assert-Null (Get-AgyNextProfile -AfterProfile $null)
    }
    It 'makes a profile eligible again once its reset time has passed' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'work')
        [void](Set-AgyProfileExhausted -Name 'work' -Until ((Get-Date).ToUniversalTime().AddSeconds(-5)))
        Assert-True (Get-AgyProfileList | Where-Object { $_.Name -eq 'work' }).Available
        Assert-Equal 'work' (Get-AgyNextProfile -AfterProfile 'personal').Name
    }
    It 'reports the reset time so the user knows when to come back' {
        Reset-TestWorld
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'personal')
        $until = (Get-Date).ToUniversalTime().AddMinutes(64)
        [void](Set-AgyProfileExhausted -Name 'personal' -Until $until)
        $p = Get-AgyProfileList | Where-Object { $_.Name -eq 'personal' }
        Assert-True $p.Exhausted
        Assert-Equal $until.ToString('yyyy-MM-ddTHH:mm') $p.ExhaustedUntil.ToString('yyyy-MM-ddTHH:mm')
    }
}

Describe 'profiles - the switch transaction' {
    It 'writes the target credential and verifies it landed' {
        Reset-TestWorld
        $a = New-TestBlob; Set-LiveBlob $a; [void](Save-AgyProfile -Name 'personal')
        $b = New-TestBlob; Set-LiveBlob $b; [void](Save-AgyProfile -Name 'work')
        Set-LiveBlob $a   # back to A, as if A were signed in
        $r = Switch-AgyProfile -To 'work'
        Assert-Equal 'work' $r.To
        Assert-Equal (Get-AgyBlobFingerprint $b) (Get-LiveFingerprint)
        Assert-Equal 'work' (Get-AgyAutoState).activeProfile
    }

    It 'scenario G: refreshes the outgoing profile snapshot before leaving it' {
        Reset-TestWorld
        $a1 = New-TestBlob; Set-LiveBlob $a1; [void](Save-AgyProfile -Name 'personal')
        $b = New-TestBlob; Set-LiveBlob $b; [void](Save-AgyProfile -Name 'work')

        # agy refreshes A's token while it is running.
        $a2 = New-TestBlob
        Set-LiveBlob $a2
        $st = Get-AgyAutoState; $st.activeProfile = 'personal'; Set-AgyAutoState $st

        [void](Switch-AgyProfile -To 'work')

        $saved = Get-AgyCredential -Target (Get-AgyProfileTarget 'personal')
        Assert-Equal (Get-AgyBlobFingerprint $a2) (Get-AgyBlobFingerprint $saved.Blob) 'stored copy of A must be the refreshed one'
        Assert-True ((Get-AgyBlobFingerprint $saved.Blob) -ne (Get-AgyBlobFingerprint $a1)) 'the stale copy must not survive'
    }

    It 'scenario E: rolls back and keeps A when the write to the live target fails' {
        Reset-TestWorld
        $a = New-TestBlob; Set-LiveBlob $a; [void](Save-AgyProfile -Name 'personal')
        $b = New-TestBlob; Set-LiveBlob $b; [void](Save-AgyProfile -Name 'work')
        Set-LiveBlob $a
        $before = Get-LiveFingerprint

        $env:AGY_AUTO_CRED_FAILWRITE = Get-AgyLiveTarget
        try { Assert-Throws { Switch-AgyProfile -To 'work' } }
        finally { $env:AGY_AUTO_CRED_FAILWRITE = $null }

        Assert-Equal $before (Get-LiveFingerprint) 'the live credential must still be A'
        Assert-Equal (Get-AgyBlobFingerprint $a) (Get-LiveFingerprint)
    }

    It 'refuses to switch to a profile with no stored credential' {
        Reset-TestWorld
        $a = New-TestBlob; Set-LiveBlob $a; [void](Save-AgyProfile -Name 'personal')
        Assert-Throws { Switch-AgyProfile -To 'ghost' }
        Assert-Equal (Get-AgyBlobFingerprint $a) (Get-LiveFingerprint) 'A must be untouched'
    }
}

Describe 'profiles - deletion' {
    It 'removes the profile without touching the live credential' {
        Reset-TestWorld
        $a = New-TestBlob; Set-LiveBlob $a; [void](Save-AgyProfile -Name 'personal')
        Set-LiveBlob (New-TestBlob); [void](Save-AgyProfile -Name 'work')
        Set-LiveBlob $a
        [void](Remove-AgyProfile -Name 'work')
        Assert-Null (Get-AgyCredential -Target (Get-AgyProfileTarget 'work'))
        Assert-NotNull (Get-AgyCredential -Target (Get-AgyLiveTarget))
        Assert-Equal (Get-AgyBlobFingerprint $a) (Get-LiveFingerprint)
        Assert-Equal 'personal' ((Get-AgyAutoConfig).profileOrder -join ' ')
    }
}

Describe 'scenario F: two switches cannot run at once' {
    It 'refuses the second caller while the lock is held, changing nothing' {
        Reset-TestWorld
        $a = New-TestBlob; Set-LiveBlob $a; [void](Save-AgyProfile -Name 'personal')
        $b = New-TestBlob; Set-LiveBlob $b; [void](Save-AgyProfile -Name 'work')
        Set-LiveBlob $a
        $before = Get-LiveFingerprint

        $held = Enter-AgyAutoLock -TimeoutSeconds 5
        Assert-NotNull $held 'the first caller must get the lock'
        try {
            # A genuinely separate process, so this exercises the OS mutex.
            $script = @"
`$env:AGY_AUTO_CRED_BACKEND = 'memory'
`$env:LOCALAPPDATA = '$($env:LOCALAPPDATA)'
. '$(Join-Path $global:AgyTestRepoRoot 'scripts\profile-manager.ps1')'
try { Switch-AgyProfile -To 'work' -LockTimeoutSeconds 2 | Out-Null; 'SWITCHED' }
catch { 'BLOCKED' }
"@
            $f = Join-Path $env:LOCALAPPDATA 'lock-probe.ps1'
            Set-Content -LiteralPath $f -Value $script -Encoding ascii
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $f
            Assert-Equal 'BLOCKED' ("$out".Trim()) 'the second caller must not proceed'
        } finally { Exit-AgyAutoLock $held }

        Assert-Equal $before (Get-LiveFingerprint) 'nothing may change while the lock is contended'
    }
    It 'releases the lock so the next caller can take it' {
        $l = Enter-AgyAutoLock -TimeoutSeconds 5
        Assert-NotNull $l
        Exit-AgyAutoLock $l
        $l2 = Enter-AgyAutoLock -TimeoutSeconds 5
        Assert-NotNull $l2
        Exit-AgyAutoLock $l2
    }
}
