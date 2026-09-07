# quota-classifier.ps1 - decide whether a Stop event justifies rotating accounts.
#
# Pure functions, no I/O, no state. Only INDIVIDUAL_QUOTA ever triggers a switch.
# The user-facing quota string is server-supplied (it is not in the agy binary),
# so this matches a family of phrasings rather than one literal.

Set-StrictMode -Version 2.0

$script:AgyQuotaCategories = @(
    'NONE', 'INDIVIDUAL_QUOTA', 'RATE_LIMIT_TEMPORARY',
    'AUTH_ERROR', 'NETWORK_ERROR', 'MODEL_ERROR', 'UNKNOWN_ERROR'
)
function Get-AgyQuotaCategories { $script:AgyQuotaCategories }

# "Resets in 1h4m13s" / "Resets in 45s" / "resets in 4 hours, 52 minutes"
function ConvertFrom-AgyResetDuration {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $m = [regex]::Match($Text, '(?i)reset[s]?\s+in\s+(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?(?![a-z])')
    if ($m.Success -and ($m.Groups[1].Success -or $m.Groups[2].Success -or $m.Groups[3].Success)) {
        $h = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { 0 }
        $mi = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
        $s = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }
        return New-TimeSpan -Hours $h -Minutes $mi -Seconds $s
    }

    # Long form: "it resets in 4 hours, 52 minutes"
    $m2 = [regex]::Match($Text, '(?i)reset[s]?\s+in\s+(.+?)(?:[.\r\n]|$)')
    if ($m2.Success) {
        $tail = $m2.Groups[1].Value
        $total = [TimeSpan]::Zero
        $any = $false
        foreach ($u in [regex]::Matches($tail, '(?i)(\d+)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?|days?)')) {
            $any = $true
            $n = [int]$u.Groups[1].Value
            switch -Regex ($u.Groups[2].Value) {
                '(?i)^d' { $total += New-TimeSpan -Days $n }
                '(?i)^h' { $total += New-TimeSpan -Hours $n }
                '(?i)^m' { $total += New-TimeSpan -Minutes $n }
                default { $total += New-TimeSpan -Seconds $n }
            }
        }
        if ($any) { return $total }
    }
    $null
}

function Get-AgyQuotaClassification {
    param(
        [AllowNull()][string]$TerminationReason,
        [AllowNull()][string]$ErrorText
    )

    $reason = if ($TerminationReason) { $TerminationReason.Trim() } else { '' }
    $reason = $reason -replace '^TERMINATION_REASON_', ''
    $text = if ($ErrorText) { $ErrorText } else { '' }

    $result = [ordered]@{
        category          = 'NONE'
        terminationReason = $reason
        shouldRotate      = $false
        resetIn           = $null
        resetAt           = $null
        signal            = ''
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        # No error payload: a clean stop, whatever the reason label says.
        if ($reason -eq 'ERROR') { $result.category = 'UNKNOWN_ERROR'; $result.signal = 'error-reason-without-text' }
        return [pscustomobject]$result
    }

    # 1. Individual quota - the only category that rotates.
    $quotaStrong = @(
        'individual quota reached'
        'exhausted your quota'
        'account is used up'
        'quota (?:has been )?(?:reached|exceeded|exhausted)'
        'upgrade your subscription'
        'out of quota'
    )
    foreach ($p in $quotaStrong) {
        if ($text -match "(?i)$p") {
            $result.category = 'INDIVIDUAL_QUOTA'; $result.shouldRotate = $true; $result.signal = $p
            break
        }
    }
    # Weaker: the word quota alongside an explicit reset countdown.
    if ($result.category -eq 'NONE' -and $text -match '(?i)quota' -and $text -match '(?i)reset[s]?\s+in\s+\d') {
        $result.category = 'INDIVIDUAL_QUOTA'; $result.shouldRotate = $true; $result.signal = 'quota+reset-countdown'
    }

    if ($result.category -eq 'INDIVIDUAL_QUOTA') {
        $span = ConvertFrom-AgyResetDuration $text
        if ($null -ne $span) {
            $result.resetIn = [int]$span.TotalSeconds
            $result.resetAt = (Get-Date).ToUniversalTime().Add($span).ToString('o')
        }
        return [pscustomobject]$result
    }

    # 2. Auth - never rotates automatically; a broken credential would just
    #    break the next profile too, and rotating hides the real problem.
    $auth = 'unauthenticated|invalid[_ ]grant|token (?:has )?expired|expired token|\b401\b|\b403\b|permission denied|not (?:logged|signed) in|re-?authenticat|login required|credentials? (?:are )?(?:invalid|expired|missing)'
    if ($text -match "(?i)$auth") {
        $result.category = 'AUTH_ERROR'; $result.signal = 'auth-pattern'
        return [pscustomobject]$result
    }

    # 3. Transient rate limiting - a bare 429 or RESOURCE_EXHAUSTED is NOT
    #    proof of individual quota exhaustion.
    if ($text -match '(?i)\b429\b|too many requests|rate[ _-]?limit|resource[_ ]exhausted') {
        $result.category = 'RATE_LIMIT_TEMPORARY'; $result.signal = 'rate-limit-pattern'
        $span = ConvertFrom-AgyResetDuration $text
        if ($null -ne $span) {
            $result.resetIn = [int]$span.TotalSeconds
            $result.resetAt = (Get-Date).ToUniversalTime().Add($span).ToString('o')
        }
        return [pscustomobject]$result
    }

    # 4. Network
    $net = 'timeout|timed out|connection (?:refused|reset|closed)|no such host|dial tcp|\bEOF\b|unavailable|network is unreachable|deadline exceeded|i/o timeout|tls handshake|proxy'
    if ($text -match "(?i)$net") {
        $result.category = 'NETWORK_ERROR'; $result.signal = 'network-pattern'
        return [pscustomobject]$result
    }

    # 5. Model / request shape
    $model = 'model .{0,40}(?:not found|unavailable|invalid|unsupported)|unsupported model|context (?:length|window)|invalid argument|\b400\b|failed precondition'
    if ($text -match "(?i)$model") {
        $result.category = 'MODEL_ERROR'; $result.signal = 'model-pattern'
        return [pscustomobject]$result
    }

    $result.category = 'UNKNOWN_ERROR'; $result.signal = 'unmatched'
    [pscustomobject]$result
}
