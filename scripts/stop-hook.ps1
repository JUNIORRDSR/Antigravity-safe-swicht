# stop-hook.ps1 - Antigravity `Stop` lifecycle hook.
#
# Runs inside the agent loop, so it stays fast and does nothing risky: read
# stdin, classify, drop an event file, answer. The switch itself belongs to the
# supervisor, between processes - never while this agy.exe still holds the
# credential.
#
# Contract (agy 1.1.27): JSON on stdin, JSON on stdout. Returning a decision of
# "continue" would block the stop; anything else lets the agent stop, so an
# empty object is the correct "carry on" answer.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Emitted no matter what happens below.
$response = '{}'

try {
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'quota-classifier.ps1')

    $stdin = [Console]::In.ReadToEnd()
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($stdin)) {
        try { $payload = $stdin | ConvertFrom-Json } catch { $payload = $null }
    }

    if ($null -eq $payload) {
        Write-AgyAutoLog -Level WARN -Message 'stop hook received unparseable stdin'
    } else {
        function Get-Field($o, [string]$n, $default = '') {
            if ((Get-AgyAutoPropertyNames $o) -contains $n) { $o.$n } else { $default }
        }

        $reason = [string](Get-Field $payload 'terminationReason')
        $errText = [string](Get-Field $payload 'error')
        $verdict = Get-AgyQuotaClassification -TerminationReason $reason -ErrorText $errText

        # A clean stop writes nothing at all, which leaves no way to prove the
        # hook is wired up. `doctor --probe` sets this to get positive evidence.
        if ($env:AGY_AUTO_HOOK_TRACE) {
            Write-AgyAutoLog -Level DEBUG -Message ("stop hook trace: reason={0} category={1} session={2}" -f `
                    $verdict.terminationReason, $verdict.category, $env:AGY_AUTO_SESSION)
        }

        if ($verdict.category -ne 'NONE') {
            # workspacePaths comes back empty in print mode, so the supervisor's
            # own CWD (passed through the environment) is the reliable answer.
            $ws = @()
            $rawWs = Get-Field $payload 'workspacePaths' @()
            if ($rawWs -is [array]) { $ws = @($rawWs) }
            elseif ($rawWs -is [string] -and $rawWs) { $ws = @($rawWs) }

            $event = [ordered]@{
                type                  = $(if ($verdict.shouldRotate) { 'QUOTA_EXHAUSTED' } else { 'ERROR_NOTICE' })
                eventId               = [guid]::NewGuid().ToString()
                createdAt             = (Get-Date).ToUniversalTime().ToString('o')
                session               = $env:AGY_AUTO_SESSION
                supervisorPid         = $env:AGY_AUTO_SUPERVISOR_PID
                childPid              = $env:AGY_AUTO_CHILD_PID
                profile               = $env:AGY_AUTO_PROFILE
                cwd                   = $env:AGY_AUTO_CWD
                conversationId        = [string](Get-Field $payload 'conversationId' $env:ANTIGRAVITY_CONVERSATION_ID)
                transcriptPath        = [string](Get-Field $payload 'transcriptPath')
                artifactDirectoryPath = [string](Get-Field $payload 'artifactDirectoryPath')
                modelName             = [string](Get-Field $payload 'modelName')
                workspacePaths        = $ws
                terminationReason     = $verdict.terminationReason
                executionNum          = Get-Field $payload 'executionNum' 0
                fullyIdle             = Get-Field $payload 'fullyIdle' $null
                category              = $verdict.category
                shouldRotate          = [bool]$verdict.shouldRotate
                signal                = $verdict.signal
                resetIn               = $verdict.resetIn
                resetAt               = $verdict.resetAt
                # Redacted and truncated: enough to diagnose, never enough to leak.
                errorRedacted         = $(
                    $t = Protect-AgyAutoText $errText
                    if ($t.Length -gt 600) { $t.Substring(0, 600) + '...' } else { $t }
                )
            }

            Initialize-AgyAutoDirs
            $file = Get-AgyAutoPath ('events\{0}-{1}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff'), $event.eventId.Substring(0, 8))
            Write-AgyAutoFileAtomic -Path $file -Content (ConvertTo-AgyAutoJson $event)

            Write-AgyAutoLog -Message ("stop hook: {0} (reason {1}, conversation {2})" -f `
                    $event.type, $verdict.terminationReason, $event.conversationId)
        }
    }
} catch {
    # A hook failure must never take the agent down with it.
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'agy-auto-switch\logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = $_.Exception.Message -replace '[A-Za-z0-9_\-]{40,}', '<REDACTED>'
        Add-Content -LiteralPath (Join-Path $dir 'hook-errors.log') -Encoding utf8 `
            -Value ('{0} [ERROR] stop-hook: {1}' -f (Get-Date).ToString('o'), $safe)
    } catch { }
}

Write-Output $response
