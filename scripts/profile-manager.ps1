# profile-manager.ps1 - named account profiles and the switch transaction.
#
# Credentials live in Windows Credential Manager under
# agy-auto-switch:profile:<name>. Only non-secret metadata reaches state.json.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'credential-manager.ps1')

function Get-AgyProfileMeta {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    if ((Get-AgyAutoPropertyNames $State.profiles) -contains $Name) { $State.profiles.$Name } else { $null }
}

function Set-AgyProfileMeta {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Meta)
    if ((Get-AgyAutoPropertyNames $State.profiles) -contains $Name) { $State.profiles.$Name = $Meta }
    else { $State.profiles | Add-Member -NotePropertyName $Name -NotePropertyValue $Meta }
}

function New-AgyProfileMeta {
    param([string]$Name, [int]$Order)
    [pscustomobject]@{
        name            = $Name
        createdAt       = (Get-Date).ToUniversalTime().ToString('o')
        lastUsedAt      = $null
        lastSavedAt     = (Get-Date).ToUniversalTime().ToString('o')
        exhaustedUntil  = $null
        enabled         = $true
        order           = $Order
        fingerprint     = ''
        blobBytes       = 0
    }
}

# ------------------------------------------------------------------- save ----

# Snapshot whatever credential is live right now into a named profile.
function Save-AgyProfile {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$Name)

    $live = Get-AgyCredential -Target (Get-AgyLiveTarget)
    if ($null -eq $live) {
        throw "No live credential at '$(Get-AgyLiveTarget)'. Sign in with agy first, then save the profile."
    }
    $bytes = $live.Blob.Length
    Clear-AgyBlob $live.Blob

    $fp = Copy-AgyCredential -From (Get-AgyLiveTarget) -To (Get-AgyProfileTarget $Name)

    $state = Get-AgyAutoState
    $meta = Get-AgyProfileMeta -State $state -Name $Name
    if ($null -eq $meta) {
        $existing = (Get-AgyAutoPropertyNames $state.profiles)
        $meta = New-AgyProfileMeta -Name $Name -Order (Get-AgyAutoCount $existing)
    }
    $meta.fingerprint = $fp
    $meta.blobBytes = $bytes
    $meta.lastSavedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-AgyProfileMeta -State $state -Name $Name -Meta $meta
    $state.activeProfile = $Name
    Set-AgyAutoState $state

    $cfg = Get-AgyAutoConfig
    if (@($cfg.profileOrder) -notcontains $Name) {
        $cfg.profileOrder = @(@($cfg.profileOrder) + $Name)
        Set-AgyAutoConfig $cfg
    }

    Write-AgyAutoLog -Level INFO -Message ("profile '{0}' saved ({1} bytes, fp {2})" -f $Name, $bytes, (Format-AgyFingerprint $fp))
    [pscustomobject]@{ Name = $Name; BlobBytes = $bytes; Fingerprint = $fp }
}

# The metadata in state.json can go missing while the credential itself survives
# in Credential Manager - a restored backup, a hand-edited state file, a wiped
# config. Adoption rebuilds the entry from what is already stored, so an account
# does not have to be signed into again merely to be registered a second time.
# It does not touch the live credential: adopting is not switching.
function Register-AgyStoredProfile {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$Name)

    $cred = Get-AgyCredential -Target (Get-AgyProfileTarget $Name)
    if ($null -eq $cred) {
        throw "No stored credential for profile '$Name'. Sign in as that account, then run: agy-auto profile save $Name"
    }
    $fp = ''
    $bytes = 0
    try { $fp = Get-AgyBlobFingerprint $cred.Blob; $bytes = $cred.Blob.Length } finally { Clear-AgyBlob $cred.Blob }

    $state = Get-AgyAutoState
    $meta = Get-AgyProfileMeta -State $state -Name $Name
    $wasNew = $null -eq $meta
    if ($wasNew) {
        $meta = New-AgyProfileMeta -Name $Name -Order (Get-AgyAutoCount (Get-AgyAutoPropertyNames $state.profiles))
    }
    $meta.fingerprint = $fp
    $meta.blobBytes = $bytes
    Set-AgyProfileMeta -State $state -Name $Name -Meta $meta
    Set-AgyAutoState $state

    $cfg = Get-AgyAutoConfig
    if (@($cfg.profileOrder) -notcontains $Name) {
        $cfg.profileOrder = @(@($cfg.profileOrder) + $Name)
        Set-AgyAutoConfig $cfg
    }

    Write-AgyAutoLog -Level INFO -Message ("profile '{0}' adopted from the credential store ({1} bytes, fp {2})" -f $Name, $bytes, (Format-AgyFingerprint $fp))
    [pscustomobject]@{ Name = $Name; BlobBytes = $bytes; Fingerprint = $fp; WasNew = $wasNew }
}

function Remove-AgyProfile {
    param([Parameter(Mandatory)][string]$Name)
    $removed = Remove-AgyCredential -Target (Get-AgyProfileTarget $Name)
    $state = Get-AgyAutoState
    if ((Get-AgyAutoPropertyNames $state.profiles) -contains $Name) {
        $state.profiles.PSObject.Properties.Remove($Name)
    }
    if ($state.activeProfile -eq $Name) { $state.activeProfile = $null }
    Set-AgyAutoState $state
    $cfg = Get-AgyAutoConfig
    $cfg.profileOrder = @(@($cfg.profileOrder) | Where-Object { $_ -ne $Name })
    Set-AgyAutoConfig $cfg
    Write-AgyAutoLog -Level INFO -Message "profile '$Name' deleted"
    $removed
}

# ------------------------------------------------------------------- list ----

function Get-AgyProfileList {
    $state = Get-AgyAutoState
    $cfg = Get-AgyAutoConfig
    $order = @($cfg.profileOrder)
    $names = (Get-AgyAutoPropertyNames $state.profiles)
    foreach ($n in $names) { if ($order -notcontains $n) { $order += $n } }

    $now = (Get-Date).ToUniversalTime()
    foreach ($n in $order) {
        $meta = Get-AgyProfileMeta -State $state -Name $n
        if ($null -eq $meta) { continue }
        $cred = Get-AgyCredential -Target (Get-AgyProfileTarget $n)
        $present = $null -ne $cred
        $storedFp = ''
        if ($present) { $storedFp = Get-AgyBlobFingerprint $cred.Blob; Clear-AgyBlob $cred.Blob }

        $until = $null
        if ($meta.exhaustedUntil) { try { $until = ([datetime]$meta.exhaustedUntil).ToUniversalTime() } catch { } }
        $exhausted = ($null -ne $until -and $now -lt $until)

        [pscustomobject]@{
            Name            = $n
            Enabled         = [bool]$meta.enabled
            Order           = [int]$meta.order
            Present         = $present
            Fingerprint     = $storedFp
            MetaFingerprint = $meta.fingerprint
            Drifted         = ($present -and $meta.fingerprint -and $storedFp -ne $meta.fingerprint)
            BlobBytes       = [int]$meta.blobBytes
            LastUsedAt      = $meta.lastUsedAt
            LastSavedAt     = $meta.lastSavedAt
            ExhaustedUntil  = $until
            Exhausted       = $exhausted
            Available       = ($present -and $meta.enabled -and -not $exhausted)
        }
    }
}

# Which profile is the live credential? Fingerprint is authoritative; when agy
# has refreshed the token the fingerprints diverge and recorded state is the
# only remaining answer.
function Get-AgyCurrentProfile {
    $live = Get-AgyCredential -Target (Get-AgyLiveTarget)
    if ($null -eq $live) { return [pscustomobject]@{ Name = $null; Match = 'no-live-credential' } }
    try { $liveFp = Get-AgyBlobFingerprint $live.Blob } finally { Clear-AgyBlob $live.Blob }

    foreach ($p in Get-AgyProfileList) {
        if ($p.Present -and $p.Fingerprint -eq $liveFp) {
            return [pscustomobject]@{ Name = $p.Name; Match = 'fingerprint'; Fingerprint = $liveFp }
        }
    }
    $state = Get-AgyAutoState
    if ($state.activeProfile) {
        return [pscustomobject]@{ Name = $state.activeProfile; Match = 'state-drifted'; Fingerprint = $liveFp }
    }
    [pscustomobject]@{ Name = $null; Match = 'unknown'; Fingerprint = $liveFp }
}

# -------------------------------------------------------------- exhaustion ---

function Set-AgyProfileExhausted {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][Nullable[datetime]]$Until
    )
    $state = Get-AgyAutoState
    $meta = Get-AgyProfileMeta -State $state -Name $Name
    if ($null -eq $meta) { return $false }
    $meta.exhaustedUntil = if ($null -eq $Until) { $null } else { $Until.ToUniversalTime().ToString('o') }
    Set-AgyProfileMeta -State $state -Name $Name -Meta $meta
    Set-AgyAutoState $state
    if ($null -eq $Until) { Write-AgyAutoLog -Message "profile '$Name' is eligible again" }
    else { Write-AgyAutoLog -Message ("profile '{0}' unavailable until {1}" -f $Name, $Until.ToLocalTime().ToString('HH:mm')) }
    $true
}

function Clear-AgyExpiredExhaustion {
    $now = (Get-Date).ToUniversalTime()
    $state = Get-AgyAutoState
    $changed = $false
    foreach ($n in (Get-AgyAutoPropertyNames $state.profiles)) {
        $meta = $state.profiles.$n
        if (-not $meta.exhaustedUntil) { continue }
        $u = $null
        try { $u = ([datetime]$meta.exhaustedUntil).ToUniversalTime() } catch { $u = $null }
        if ($null -eq $u -or $now -ge $u) { $meta.exhaustedUntil = $null; $changed = $true }
    }
    if ($changed) { Set-AgyAutoState $state }
    $changed
}

# ---------------------------------------------------------------- selection --

function Get-AgyNextProfile {
    param([AllowNull()][string]$AfterProfile)
    Clear-AgyExpiredExhaustion | Out-Null
    $all = @(Get-AgyProfileList | Sort-Object Order, Name)
    if ((Get-AgyAutoCount $all) -eq 0) { return $null }

    # Round-robin from the position of the profile we are leaving.
    $start = 0
    if ($AfterProfile) {
        for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].Name -eq $AfterProfile) { $start = $i + 1; break } }
    }
    for ($k = 0; $k -lt $all.Count; $k++) {
        $c = $all[($start + $k) % $all.Count]
        if ($c.Name -eq $AfterProfile) { continue }
        if ($c.Available) { return $c }
    }
    $null
}

# --------------------------------------------------------------- transaction --

# Transactional credential switch. Every failure path restores profile A.
function Switch-AgyProfile {
    param(
        [Parameter(Mandatory)][string]$To,
        [switch]$NoRefreshCurrent,
        [int]$LockTimeoutSeconds = 30
    )

    $lock = Enter-AgyAutoLock -TimeoutSeconds $LockTimeoutSeconds
    if ($null -eq $lock) {
        throw 'Another agy-auto-switch operation holds the lock; nothing was changed.'
    }

    $liveTarget = Get-AgyLiveTarget
    $snapshot = $null          # bytes of A, for rollback
    $snapshotUser = 'antigravity'
    $snapshotPersist = 2
    $fromName = $null

    try {
        # --- snapshot current -------------------------------------------------
        $live = Get-AgyCredential -Target $liveTarget
        if ($null -ne $live) {
            $snapshot = $live.Blob.Clone()
            $snapshotUser = $live.UserName
            $snapshotPersist = $live.Persist
            Clear-AgyBlob $live.Blob
        }

        # --- backup/update A --------------------------------------------------
        # agy rewrites the credential as it refreshes tokens, so the stored copy
        # of the profile we are leaving must be re-synced from the live one.
        if (-not $NoRefreshCurrent -and $null -ne $snapshot) {
            $cur = Get-AgyCurrentProfile
            $fromName = $cur.Name
            if ($fromName -and $fromName -ne $To) {
                try {
                    $fp = Copy-AgyCredential -From $liveTarget -To (Get-AgyProfileTarget $fromName)
                    $st = Get-AgyAutoState
                    $m = Get-AgyProfileMeta -State $st -Name $fromName
                    if ($null -ne $m) {
                        $m.fingerprint = $fp
                        $m.blobBytes = $snapshot.Length
                        $m.lastSavedAt = (Get-Date).ToUniversalTime().ToString('o')
                        Set-AgyProfileMeta -State $st -Name $fromName -Meta $m
                        Set-AgyAutoState $st
                    }
                    Write-AgyAutoLog -Message "current credential snapshot refreshed for '$fromName'"
                } catch {
                    Write-AgyAutoLog -Level WARN -Message ("could not refresh snapshot for '{0}': {1}" -f $fromName, $_.Exception.Message)
                }
            }
        }

        # --- write B ----------------------------------------------------------
        $target = Get-AgyCredential -Target (Get-AgyProfileTarget $To)
        if ($null -eq $target) { throw "Profile '$To' has no stored credential." }
        $expected = $null
        try {
            $expected = Get-AgyBlobFingerprint $target.Blob
            Set-AgyCredential -Target $liveTarget -Blob $target.Blob -UserName $target.UserName -Persist $target.Persist
        } finally { Clear-AgyBlob $target.Blob }

        # --- verify hash ------------------------------------------------------
        $check = Get-AgyCredential -Target $liveTarget
        if ($null -eq $check) { throw "Verification failed: live credential unreadable after write." }
        $actual = $null
        try { $actual = Get-AgyBlobFingerprint $check.Blob } finally { Clear-AgyBlob $check.Blob }
        if ($actual -ne $expected) { throw "Verification failed: live credential fingerprint does not match profile '$To'." }

        # --- commit metadata --------------------------------------------------
        $st = Get-AgyAutoState
        $m = Get-AgyProfileMeta -State $st -Name $To
        if ($null -ne $m) {
            $m.lastUsedAt = (Get-Date).ToUniversalTime().ToString('o')
            Set-AgyProfileMeta -State $st -Name $To -Meta $m
        }
        $st.activeProfile = $To
        $st.lastSwitchAt = (Get-Date).ToUniversalTime().ToString('o')
        Set-AgyAutoState $st

        Write-AgyAutoLog -Message ("switched {0} -> {1}" -f $(if ($fromName) { $fromName } else { '(unknown)' }), $To)
        [pscustomobject]@{ From = $fromName; To = $To; Fingerprint = $expected; RolledBack = $false }

    } catch {
        # --- rollback ---------------------------------------------------------
        $reason = Protect-AgyAutoText $_.Exception.Message
        if ($null -ne $snapshot) {
            try {
                Set-AgyCredential -Target $liveTarget -Blob $snapshot -UserName $snapshotUser -Persist $snapshotPersist
                Write-AgyAutoLog -Level WARN -Message "switch failed; rolled back to the previous credential ($reason)"
            } catch {
                Write-AgyAutoLog -Level ERROR -Message "switch failed AND rollback failed; run 'agy-auto doctor' before continuing"
            }
        } else {
            Write-AgyAutoLog -Level ERROR -Message "switch failed with no credential to restore ($reason)"
        }
        throw
    } finally {
        if ($null -ne $snapshot) { Clear-AgyBlob $snapshot }
        Exit-AgyAutoLock $lock
    }
}
