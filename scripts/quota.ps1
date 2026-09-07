# quota.ps1 - read live quota from agy itself.
#
# `agy -p "/quota" --output-format json` answers without starting an agent turn,
# spending quota, or leaving a conversation behind (verified: conversation_id is
# empty and every token counter is zero). That makes it safe to call before
# committing to a profile, which is what turns blind rotation into verified
# rotation.

Set-StrictMode -Version 2.0

function Get-AgyQuotaSnapshot {
    param(
        [Parameter(Mandatory)][string]$RealAgyPath,
        [int]$TimeoutSeconds = 45
    )
    if (-not (Test-Path -LiteralPath $RealAgyPath)) { return $null }

    $tmpOut = [IO.Path]::GetTempFileName()
    $tmpErr = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $RealAgyPath `
            -ArgumentList @('-p', '/quota', '--output-format', 'json') `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch { }
            return $null
        }
        $raw = [IO.File]::ReadAllText($tmpOut)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { return $null }
        if ($null -eq $obj -or $obj.status -ne 'SUCCESS') { return $null }
        if (-not ((Get-AgyAutoPropertyNames $obj) -contains 'command')) { return $null }

        $groups = @()
        foreach ($g in @($obj.command.data.groups)) {
            $buckets = @()
            foreach ($b in @($g.buckets)) {
                $reset = $null
                if ((Get-AgyAutoPropertyNames $b) -contains 'reset_time' -and $b.reset_time) {
                    try { $reset = ([datetime]$b.reset_time).ToUniversalTime() } catch { }
                }
                $buckets += [pscustomobject]@{
                    Id        = $b.id
                    Name      = $b.name
                    Window    = $b.window
                    Remaining = [double]$b.remaining_fraction
                    ResetAt   = $reset
                }
            }
            $groups += [pscustomobject]@{ Name = $g.name; Buckets = $buckets }
        }
        [pscustomobject]@{ CapturedAt = (Get-Date).ToUniversalTime(); Groups = $groups }
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# A group is usable when every one of its windows still has headroom; the
# account is usable when at least one group is.
function Test-AgyQuotaAvailable {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [double]$Floor = 0.005
    )
    if ($null -eq $Snapshot) { return $null }   # unknown, not "unavailable"
    foreach ($g in $Snapshot.Groups) {
        if ((Get-AgyAutoCount $g.Buckets) -eq 0) { continue }
        $ok = $true
        foreach ($b in $g.Buckets) { if ($b.Remaining -le $Floor) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    $false
}

# Earliest moment any currently-drained bucket comes back.
function Get-AgyQuotaNextReset {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [double]$Floor = 0.005
    )
    if ($null -eq $Snapshot) { return $null }
    $times = foreach ($g in $Snapshot.Groups) {
        foreach ($b in $g.Buckets) {
            if ($b.Remaining -le $Floor -and $null -ne $b.ResetAt) { $b.ResetAt }
        }
    }
    if (-not $times) { return $null }
    ($times | Sort-Object)[0]
}

function Format-AgyQuotaSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    if ($null -eq $Snapshot) { return '  (unavailable)' }
    $lines = foreach ($g in $Snapshot.Groups) {
        foreach ($b in $g.Buckets) {
            '  {0,-24} {1,-26} {2,3}%  resets {3}' -f `
                $g.Name, $b.Name, [int][Math]::Round($b.Remaining * 100), `
                $(if ($b.ResetAt) { $b.ResetAt.ToLocalTime().ToString('MM-dd HH:mm') } else { '?' })
        }
    }
    $lines -join [Environment]::NewLine
}
