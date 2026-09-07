. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\quota-classifier.ps1')

$fx = Join-Path $PSScriptRoot 'fixtures'
function Get-Fixture([string]$Name) { Get-Content -LiteralPath (Join-Path $fx $Name) -Raw | ConvertFrom-Json }
function Classify-Fixture([string]$Name) {
    $p = Get-Fixture $Name
    Get-AgyQuotaClassification -TerminationReason $p.terminationReason -ErrorText $p.error
}

Describe 'quota classifier - scenario A: the exact reported error' {
    It 'classifies the verbatim quota message as INDIVIDUAL_QUOTA' {
        $r = Classify-Fixture 'quota-exact.json'
        Assert-Equal 'INDIVIDUAL_QUOTA' $r.category
        Assert-True $r.shouldRotate 'the exact quota error must rotate'
    }
    It 'extracts resetAt from "Resets in 1h4m13s"' {
        $r = Classify-Fixture 'quota-exact.json'
        Assert-Equal 3853 $r.resetIn  # 1*3600 + 4*60 + 13
        Assert-NotNull $r.resetAt
    }
}

Describe 'quota classifier - scenario B: RESOURCE_EXHAUSTED + quota' {
    It 'still classifies as INDIVIDUAL_QUOTA, not rate limiting' {
        $r = Classify-Fixture 'quota-resource-exhausted.json'
        Assert-Equal 'INDIVIDUAL_QUOTA' $r.category
        Assert-True $r.shouldRotate
    }
}

Describe 'quota classifier - scenario C: network errors never rotate' {
    It 'classifies a network failure as NETWORK_ERROR' {
        $r = Classify-Fixture 'network-error.json'
        Assert-Equal 'NETWORK_ERROR' $r.category
        Assert-False $r.shouldRotate 'a network blip must not burn an account'
    }
    foreach ($t in @(
            'context deadline exceeded',
            'dial tcp 142.250.1.1:443: connect: connection refused',
            'Post "https://api": net/http: TLS handshake timeout',
            'unexpected EOF reading response')) {
        It ("does not rotate on: " + $t) {
            $r = Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText $t
            Assert-False $r.shouldRotate
            Assert-Equal 'NETWORK_ERROR' $r.category
        }
    }
}

Describe 'quota classifier - scenario D: auth errors never rotate' {
    It 'classifies an auth failure as AUTH_ERROR' {
        $r = Classify-Fixture 'auth-error.json'
        Assert-Equal 'AUTH_ERROR' $r.category
        Assert-False $r.shouldRotate 'rotating would mask a broken credential'
    }
    foreach ($t in @(
            'rpc error: code = Unauthenticated desc = request had invalid authentication credentials',
            'HTTP 401 Unauthorized',
            'invalid_grant: token has expired')) {
        It ("does not rotate on: " + $t) {
            $r = Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText $t
            Assert-Equal 'AUTH_ERROR' $r.category
            Assert-False $r.shouldRotate
        }
    }
}

Describe 'quota classifier - a bare 429 is not individual quota' {
    foreach ($t in @(
            'HTTP 429 Too Many Requests',
            'rpc error: code = ResourceExhausted desc = RESOURCE_EXHAUSTED',
            'rate limit exceeded, retry shortly')) {
        It ("treats as RATE_LIMIT_TEMPORARY: " + $t) {
            $r = Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText $t
            Assert-Equal 'RATE_LIMIT_TEMPORARY' $r.category
            Assert-False $r.shouldRotate 'only individual quota rotates'
        }
    }
}

Describe 'quota classifier - scenario I: a normal stop creates no rotation' {
    It 'returns NONE for NO_TOOL_CALL with an empty error' {
        $r = Get-AgyQuotaClassification -TerminationReason 'NO_TOOL_CALL' -ErrorText ''
        Assert-Equal 'NONE' $r.category
        Assert-False $r.shouldRotate
    }
    It 'returns NONE for a user cancellation' {
        $r = Get-AgyQuotaClassification -TerminationReason 'USER_CANCELED' -ErrorText ''
        Assert-Equal 'NONE' $r.category
        Assert-False $r.shouldRotate
    }
    It 'strips the TERMINATION_REASON_ prefix when present' {
        $r = Get-AgyQuotaClassification -TerminationReason 'TERMINATION_REASON_NO_TOOL_CALL' -ErrorText ''
        Assert-Equal 'NO_TOOL_CALL' $r.terminationReason
    }
}

Describe 'quota classifier - phrasing tolerance' {
    foreach ($t in @(
            'Individual quota reached. Please upgrade your subscription to increase your limits.',
            'You have exhausted your quota on this model.',
            'this account is used up; it resets in 22m',
            'Your quota has been exceeded for this period.')) {
        It ("rotates on: " + $t.Substring(0, [Math]::Min(46, $t.Length))) {
            $r = Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText $t
            Assert-Equal 'INDIVIDUAL_QUOTA' $r.category
            Assert-True $r.shouldRotate
        }
    }
    It 'does not rotate on unrelated prose that merely mentions quota' {
        $r = Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText 'disk quota check skipped; write failed with i/o timeout'
        Assert-False $r.shouldRotate
    }
}

Describe 'reset duration parsing' {
    It 'parses 45s' { Assert-Equal 45 ([int](ConvertFrom-AgyResetDuration 'Resets in 45s').TotalSeconds) }
    It 'parses 14m20s' { Assert-Equal 860 ([int](ConvertFrom-AgyResetDuration 'Resets in 14m20s').TotalSeconds) }
    It 'parses 1h4m13s' { Assert-Equal 3853 ([int](ConvertFrom-AgyResetDuration 'Resets in 1h4m13s').TotalSeconds) }
    It 'parses 2h' { Assert-Equal 7200 ([int](ConvertFrom-AgyResetDuration 'Resets in 2h').TotalSeconds) }
    It 'parses the long form used by /quota descriptions' {
        Assert-Equal 17520 ([int](ConvertFrom-AgyResetDuration 'it resets in 4 hours, 52 minutes').TotalSeconds)
    }
    It 'returns null when there is no countdown' { Assert-Null (ConvertFrom-AgyResetDuration 'no countdown here') }
    It 'returns null on empty input' { Assert-Null (ConvertFrom-AgyResetDuration '') }
}
