. (Join-Path $global:AgyTestRepoRoot 'scripts\common.ps1')
. (Join-Path $global:AgyTestRepoRoot 'scripts\credential-manager.ps1')

function New-TestBlob([int]$Size = 503) {
    $b = New-Object byte[] $Size
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    , $b
}

Describe 'credential manager - opaque blob handling' {
    It 'uses the in-memory backend under test' {
        Assert-Equal 'memory' (Get-AgyCredBackend) 'tests must never touch the real credential store'
    }
    It 'round-trips a blob byte for byte' {
        Reset-AgyCredentialMemoryStore
        $b = New-TestBlob
        Set-AgyCredential -Target 'test:a' -Blob $b
        $back = Get-AgyCredential -Target 'test:a'
        Assert-Equal (Get-AgyBlobFingerprint $b) (Get-AgyBlobFingerprint $back.Blob)
        Assert-Equal 503 $back.Blob.Length
    }
    It 'returns null for a missing target rather than throwing' {
        Reset-AgyCredentialMemoryStore
        Assert-Null (Get-AgyCredential -Target 'test:absent')
    }
    It 'reports a missing target as not present' {
        Reset-AgyCredentialMemoryStore
        Assert-False (Get-AgyCredentialInfo -Target 'test:absent').Present
    }
}

Describe 'credential manager - fingerprints' {
    It 'produces a stable 64-hex-character digest' {
        $b = New-TestBlob
        $fp = Get-AgyBlobFingerprint $b
        Assert-Equal 64 $fp.Length
        Assert-Equal $fp (Get-AgyBlobFingerprint $b)
        Assert-Match '^[0-9a-f]{64}$' $fp
    }
    It 'changes when a single byte changes' {
        $b = New-TestBlob
        $fp1 = Get-AgyBlobFingerprint $b
        $b[0] = [byte](($b[0] + 1) % 256)
        Assert-True ((Get-AgyBlobFingerprint $b) -ne $fp1)
    }
    It 'never displays more than 16 characters' {
        Assert-Equal 16 (Format-AgyFingerprint ('a' * 64)).Length
    }
    It 'is not reversible to the blob' {
        # A fingerprint is a digest, not an encoding: it carries no blob bytes.
        $b = New-TestBlob
        $fp = Get-AgyBlobFingerprint $b
        $hex = ([BitConverter]::ToString($b) -replace '-', '').ToLowerInvariant()
        Assert-NoMatch ([regex]::Escape($fp)) $hex
    }
}

Describe 'credential manager - copy with verification' {
    It 'copies and returns the verified fingerprint' {
        Reset-AgyCredentialMemoryStore
        $b = New-TestBlob
        Set-AgyCredential -Target 'test:src' -Blob $b -UserName 'antigravity' -Persist 2
        $fp = Copy-AgyCredential -From 'test:src' -To 'test:dst'
        Assert-Equal (Get-AgyBlobFingerprint $b) $fp
        $dst = Get-AgyCredential -Target 'test:dst'
        Assert-Equal 'antigravity' $dst.UserName
        Assert-Equal 2 $dst.Persist
    }
    It 'throws when the source does not exist' {
        Reset-AgyCredentialMemoryStore
        Assert-Throws { Copy-AgyCredential -From 'test:none' -To 'test:dst' }
    }
    It 'scenario E: surfaces a CredWrite failure instead of reporting success' {
        Reset-AgyCredentialMemoryStore
        Set-AgyCredential -Target 'test:src' -Blob (New-TestBlob)
        $env:AGY_AUTO_CRED_FAILWRITE = 'test:dst'
        try { Assert-Throws { Copy-AgyCredential -From 'test:src' -To 'test:dst' } }
        finally { $env:AGY_AUTO_CRED_FAILWRITE = $null }
        Assert-Null (Get-AgyCredential -Target 'test:dst') 'a failed write must not leave a partial credential'
    }
}

Describe 'credential manager - target naming' {
    It 'uses the real live target' { Assert-Equal 'gemini:antigravity' (Get-AgyLiveTarget) }
    It 'namespaces profile targets' { Assert-Equal 'agy-auto-switch:profile:work' (Get-AgyProfileTarget 'work') }
}

Describe 'scenario N: nothing leaks into logs' {
    It 'redacts token-shaped values' {
        $s = Protect-AgyAutoText 'refresh_token: 1//0gABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop'
        Assert-Match 'REDACTED' $s
        Assert-NoMatch 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' $s
    }
    It 'redacts a Google access token prefix' {
        Assert-Match 'REDACTED' (Protect-AgyAutoText 'ya29.a0AfH6SMBx7QlKjhgfdsaPOIUYTREWQmnbvcxzLKJHGFDSA')
    }
    It 'redacts a JWT' {
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk'
        Assert-Match 'REDACTED' (Protect-AgyAutoText $jwt)
    }
    It 'redacts any long opaque run of credential-shaped characters' {
        Assert-Match 'REDACTED' (Protect-AgyAutoText ('blob=' + ('A1b2C3d4' * 8)))
    }
    It 'leaves ordinary diagnostic text readable' {
        $s = Protect-AgyAutoText 'quota detected; switching personal -> work'
        Assert-Equal 'quota detected; switching personal -> work' $s
    }
    It 'a real 503-byte blob never appears in a log line' {
        $b = New-TestBlob
        $hex = ([BitConverter]::ToString($b) -replace '-', '')
        Assert-Match 'REDACTED' (Protect-AgyAutoText "credentialBlob=$hex")
    }
}
