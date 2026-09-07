. (Join-Path $global:AgyTestRepoRoot 'scripts\common.ps1')

$script:HookPath = Join-Path $global:AgyTestRepoRoot 'scripts\stop-hook.ps1'
$script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'

function Clear-Events {
    foreach ($d in 'events', 'events\processed') {
        $p = Get-AgyAutoPath $d
        if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Filter '*.json' | Remove-Item -Force }
    }
}

# Run the hook exactly the way agy does: JSON on stdin, JSON expected on stdout.
function Invoke-Hook {
    param([string]$Fixture, [string]$Session = 'test-session')
    Initialize-AgyAutoDirs
    $env:AGY_AUTO_SESSION = $Session
    $env:AGY_AUTO_CWD = $global:AgyTestRepoRoot
    $env:AGY_AUTO_PROFILE = 'personal'
    try {
        $json = Get-Content -LiteralPath (Join-Path $script:FixtureDir $Fixture) -Raw
        $out = $json | & powershell -NoProfile -ExecutionPolicy Bypass -File $script:HookPath
        return ("$out").Trim()
    } finally {
        $env:AGY_AUTO_SESSION = $null
        $env:AGY_AUTO_CWD = $null
        $env:AGY_AUTO_PROFILE = $null
    }
}

function Get-Events {
    $p = Get-AgyAutoPath 'events'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @(Get-ChildItem -LiteralPath $p -Filter '*.json' | ForEach-Object { Read-AgyAutoJson $_.FullName })
}

Describe 'stop hook - scenario H: a quota stop writes exactly one event' {
    It 'writes a single QUOTA_EXHAUSTED event' {
        Clear-Events
        [void](Invoke-Hook 'quota-exact.json')
        $events = @(Get-Events)
        Assert-Equal 1 $events.Count 'exactly one event, written atomically'
        Assert-Equal 'QUOTA_EXHAUSTED' $events[0].type
        Assert-True $events[0].shouldRotate
    }
    It 'always answers with valid JSON that permits the stop' {
        Clear-Events
        $out = Invoke-Hook 'quota-exact.json'
        $parsed = $null
        try { $parsed = $out | ConvertFrom-Json } catch { }
        Assert-NotNull $parsed 'agy requires a JSON object on stdout'
        Assert-NoMatch 'continue' $out 'a "continue" decision would block the stop'
    }
    It 'carries the continuity data the supervisor needs' {
        Clear-Events
        [void](Invoke-Hook 'quota-exact.json')
        $e = @(Get-Events)[0]
        Assert-Equal '11111111-2222-3333-4444-555555555555' $e.conversationId
        Assert-Match 'transcript_full\.jsonl$' $e.transcriptPath
        Assert-Match 'brain' $e.artifactDirectoryPath
        Assert-Equal 'gemini-3.8-flash-high' $e.modelName
        Assert-Equal 'ERROR' $e.terminationReason
    }
    It 'records the supervisor session so events are never crossed' {
        Clear-Events
        [void](Invoke-Hook 'quota-exact.json' -Session 'session-abc')
        Assert-Equal 'session-abc' @(Get-Events)[0].session
        Assert-Equal $global:AgyTestRepoRoot @(Get-Events)[0].cwd
    }
    It 'computes an absolute resetAt from the countdown' {
        Clear-Events
        [void](Invoke-Hook 'quota-exact.json')
        $e = @(Get-Events)[0]
        Assert-Equal 3853 $e.resetIn
        $at = ([datetime]$e.resetAt).ToUniversalTime()
        Assert-True ($at -gt (Get-Date).ToUniversalTime()) 'resetAt must be in the future'
    }
    It 'handles RESOURCE_EXHAUSTED wrapping the same message' {
        Clear-Events
        [void](Invoke-Hook 'quota-resource-exhausted.json')
        $e = @(Get-Events)[0]
        Assert-Equal 'QUOTA_EXHAUSTED' $e.type
        Assert-Equal 7200 $e.resetIn
    }
}

Describe 'stop hook - scenario I: a normal stop creates no rotation event' {
    It 'writes nothing for NO_TOOL_CALL with no error' {
        Clear-Events
        [void](Invoke-Hook 'normal-stop.json')
        Assert-Equal 0 @(Get-Events).Count 'a clean stop must not queue a rotation'
    }
    It 'still answers with valid JSON' {
        Clear-Events
        $out = Invoke-Hook 'normal-stop.json'
        $parsed = $null
        try { $parsed = $out | ConvertFrom-Json } catch { }
        Assert-NotNull $parsed
    }
}

Describe 'stop hook - non-rotating errors are recorded but never rotate' {
    It 'files a network error as ERROR_NOTICE' {
        Clear-Events
        [void](Invoke-Hook 'network-error.json')
        $e = @(Get-Events)[0]
        Assert-Equal 'ERROR_NOTICE' $e.type
        Assert-Equal 'NETWORK_ERROR' $e.category
        Assert-False $e.shouldRotate
    }
    It 'files an auth error as ERROR_NOTICE' {
        Clear-Events
        [void](Invoke-Hook 'auth-error.json')
        $e = @(Get-Events)[0]
        Assert-Equal 'AUTH_ERROR' $e.category
        Assert-False $e.shouldRotate
    }
}

Describe 'stop hook - robustness' {
    It 'answers with JSON even when stdin is not JSON at all' {
        Clear-Events
        Initialize-AgyAutoDirs
        $out = 'this is not json' | & powershell -NoProfile -ExecutionPolicy Bypass -File $script:HookPath
        $parsed = $null
        try { $parsed = ("$out").Trim() | ConvertFrom-Json } catch { }
        Assert-NotNull $parsed 'a hook crash must never take the agent down'
    }
    It 'answers with JSON on empty stdin' {
        Clear-Events
        Initialize-AgyAutoDirs
        $out = '' | & powershell -NoProfile -ExecutionPolicy Bypass -File $script:HookPath
        $parsed = $null
        try { $parsed = ("$out").Trim() | ConvertFrom-Json } catch { }
        Assert-NotNull $parsed
    }
}

Describe 'stop hook - scenario N: the event file carries no secrets' {
    It 'redacts a token that arrives inside the error text' {
        Clear-Events
        Initialize-AgyAutoDirs
        $env:AGY_AUTO_SESSION = 'leak-test'
        try {
            $payload = @{
                conversationId    = 'leak-1'
                terminationReason = 'ERROR'
                error             = 'Individual quota reached. Resets in 5m. authorization: Bearer ya29.aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefgh'
                transcriptPath    = 'C:/x/transcript.jsonl'
                modelName         = 'gemini'
            } | ConvertTo-Json
            [void]($payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $script:HookPath)
        } finally { $env:AGY_AUTO_SESSION = $null }

        $raw = Get-Content -LiteralPath (Get-ChildItem -LiteralPath (Get-AgyAutoPath 'events') -Filter '*.json')[0].FullName -Raw
        Assert-NoMatch 'ya29\.aBcDeFgHiJk' $raw 'the token must not survive into the event file'
        Assert-Match 'REDACTED' $raw
        Assert-Match 'QUOTA_EXHAUSTED' $raw 'classification must still work on the redacted text'
    }
}
