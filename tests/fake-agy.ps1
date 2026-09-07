# fake-agy.ps1 - stands in for agy.exe during integration tests.
#
# It answers --version and /quota, can reject a --conversation resume, and can
# fire the REAL stop-hook with a real fixture so the supervisor sees a genuine
# quota event. No account, no network, no credentials.

$dir = $env:FAKE_AGY_DIR
if (-not $dir) { Write-Error 'FAKE_AGY_DIR not set'; exit 2 }

$log = Join-Path $dir 'invocations.log'
Add-Content -LiteralPath $log -Encoding utf8 -Value ('RUN | profile={0} | {1}' -f $env:AGY_AUTO_PROFILE, ($args -join ' '))

if ($args -contains '--version') { Write-Output '1.1.27'; exit 0 }

if ($args -contains '/quota') {
    $remaining = 0.90
    # The supervisor's quota probe is a plain child of the supervisor and does
    # not carry AGY_AUTO_PROFILE, so honour a global override as well.
    foreach ($f in @((Join-Path $dir 'quota-all.txt'), (Join-Path $dir ('quota-{0}.txt' -f $env:AGY_AUTO_PROFILE)))) {
        if (Test-Path -LiteralPath $f) { $remaining = [double](Get-Content -LiteralPath $f -Raw).Trim() }
    }
    $reset = (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $payload = @{
        conversation_id = ''
        status          = 'SUCCESS'
        usage           = @{ input_tokens = 0; output_tokens = 0; total_tokens = 0 }
        command         = @{
            name = 'usage'
            data = @{
                groups = @(@{
                        name    = 'Gemini Models'
                        buckets = @(
                            @{ id = 'gemini-weekly'; name = 'Weekly Limit Remaining'; window = 'weekly'; remaining_fraction = $remaining; reset_time = $reset },
                            @{ id = 'gemini-5h'; name = 'Five Hour Limit Remaining'; window = '5h'; remaining_fraction = $remaining; reset_time = $reset }
                        )
                    })
            }
        }
    }
    Write-Output ($payload | ConvertTo-Json -Depth 10 -Compress)
    exit 0
}

if ($args -contains '--conversation') {
    $mode = 'reject'
    $f = Join-Path $dir 'resume-mode.txt'
    if (Test-Path -LiteralPath $f) { $mode = (Get-Content -LiteralPath $f -Raw).Trim() }
    if ($mode -eq 'reject') {
        Write-Output 'Error: conversation not found for this account'
        exit 1
    }
    Write-Output 'resumed'
    exit 0
}

# A normal run. Fire the real Stop hook once if the test armed it.
$marker = Join-Path $dir 'emit-quota.txt'
if (Test-Path -LiteralPath $marker) {
    $fixture = (Get-Content -LiteralPath $marker -Raw).Trim()
    Remove-Item -LiteralPath $marker -Force
    $hook = Join-Path $env:FAKE_AGY_HOOK 'stop-hook.ps1'
    $json = Get-Content -LiteralPath $fixture -Raw
    $json | & powershell -NoProfile -ExecutionPolicy Bypass -File $hook | Out-Null
}
Write-Output 'done'
exit 0
