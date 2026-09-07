# handoff.ps1 - continuity across an account switch.
#
# The transcript records intent; git and the filesystem record what actually
# happened. The handoff hands both to the next session and tells it to trust the
# filesystem over any summary.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'common.ps1')

# git writes to stderr for ordinary conditions ("not a git repository"), and in
# Windows PowerShell that becomes a NativeCommandError - fatal under the
# ErrorActionPreference=Stop that the entry point sets. Every git call goes
# through here so a non-repo working directory can never break the handoff.
function Invoke-AgyGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = & git -C $Path @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        @($out)
    } catch { $null } finally { $ErrorActionPreference = $prev }
}

function Get-AgyGitFacts {
    param([Parameter(Mandatory)][string]$Path)
    $facts = [ordered]@{
        isRepo        = $false
        branch        = ''
        head          = ''
        headSubject   = ''
        porcelain     = ''
        diffStat      = ''
        recentCommits = ''
        untrackedCount = 0
        modifiedCount = 0
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$facts }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return [pscustomobject]$facts }

    $inside = Invoke-AgyGit -Path $Path -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($null -eq $inside -or "$inside".Trim() -ne 'true') { return [pscustomobject]$facts }

    $facts.isRepo = $true
    $facts.branch = "$(Invoke-AgyGit -Path $Path -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD'))".Trim()
    $facts.head = "$(Invoke-AgyGit -Path $Path -GitArgs @('rev-parse', 'HEAD'))".Trim()
    $facts.headSubject = "$(Invoke-AgyGit -Path $Path -GitArgs @('log', '-1', '--pretty=%s'))".Trim()
    $porcelain = @(Invoke-AgyGit -Path $Path -GitArgs @('status', '--porcelain'))
    $facts.porcelain = ($porcelain -join [Environment]::NewLine)
    $facts.untrackedCount = @($porcelain | Where-Object { $_ -like '??*' }).Count
    $facts.modifiedCount = @($porcelain | Where-Object { $_ -and $_ -notlike '??*' }).Count
    $facts.diffStat = (@(Invoke-AgyGit -Path $Path -GitArgs @('diff', '--stat')) -join [Environment]::NewLine)
    $facts.recentCommits = (@(Invoke-AgyGit -Path $Path -GitArgs @('log', '-5', '--pretty=%h %s')) -join [Environment]::NewLine)
    [pscustomobject]$facts
}

function New-AgyCheckpoint {
    param(
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)][string]$Cwd,
        [AllowNull()][string]$FromProfile
    )
    Initialize-AgyAutoDirs
    $git = Get-AgyGitFacts -Path $Cwd
    $cp = [ordered]@{
        checkpointId          = [guid]::NewGuid().ToString()
        createdAt             = (Get-Date).ToUniversalTime().ToString('o')
        reason                = $Event.category
        fromProfile           = $FromProfile
        conversationId        = $Event.conversationId
        transcriptPath        = $Event.transcriptPath
        artifactDirectoryPath = $Event.artifactDirectoryPath
        modelName             = $Event.modelName
        workspacePaths        = @($Event.workspacePaths)
        cwd                   = $Cwd
        resetAt               = $Event.resetAt
        git                   = $git
    }
    $file = Get-AgyAutoPath ('checkpoints\{0}-{1}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $cp.checkpointId.Substring(0, 8))
    Write-AgyAutoFileAtomic -Path $file -Content (ConvertTo-AgyAutoJson $cp)
    Write-AgyAutoLog -Message "checkpoint stored"
    [pscustomobject]@{ Path = $file; Data = [pscustomobject]$cp }
}

function New-AgyHandoff {
    param(
        [Parameter(Mandatory)]$Checkpoint,
        [AllowNull()][string]$ToProfile
    )
    Initialize-AgyAutoDirs
    $c = $Checkpoint.Data
    $g = $c.git

    $transcriptNote = if ($c.transcriptPath -and (Test-Path -LiteralPath $c.transcriptPath)) {
        "Available at: ``$($c.transcriptPath)``"
    } else {
        "Recorded path ``$($c.transcriptPath)`` is not readable from here - rely on git and the filesystem."
    }

    $gitSection = if ($g.isRepo) {
        @"
- Branch: ``$($g.branch)``
- HEAD: ``$($g.head)`` - $($g.headSubject)
- Uncommitted: $($g.modifiedCount) tracked file(s) modified, $($g.untrackedCount) untracked

``````
$($g.porcelain)
``````

Recent commits:

``````
$($g.recentCommits)
``````
"@
    } else {
        "- Not a git repository (or git unavailable). The filesystem is the only record of completed work."
    }

    $md = @"
# Task handoff - account switch

The previous session stopped because profile **$($c.fromProfile)** hit its
individual quota. Work continues under **$ToProfile**.

| | |
| :--- | :--- |
| Handoff created | $($c.createdAt) |
| Reason | $($c.reason) |
| Previous conversation | ``$($c.conversationId)`` |
| Model in use | $($c.modelName) |
| Working directory | ``$($c.cwd)`` |
| Previous profile quota returns | $(if ($c.resetAt) { $c.resetAt } else { 'unknown' }) |

## Transcript of the interrupted session

$transcriptNote

## Repository state at the moment of interruption

$gitSection

## Recovery protocol

Do not restart the task from zero, and do not trust any summary over the
filesystem.

1. Inspect the workspace at ``$($c.cwd)``.
2. Run ``git status`` and ``git diff`` and compare them against the snapshot above.
3. Read the transcript named above to recover intent and decisions - what the
   previous session was trying to do and why.
4. Work out which actions already completed. Files on disk and commits in git
   are proof; the transcript is only evidence of intent.
5. Work out what was still pending.
6. Before repeating anything with side effects - writes, migrations, network
   calls, package installs, deployments - verify whether it already happened.
7. Continue from the last consistent point.
"@

    $file = Get-AgyAutoPath ('handoffs\{0}-{1}.md' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $c.checkpointId.Substring(0, 8))
    Write-AgyAutoFileAtomic -Path $file -Content $md

    # The prompt actually handed to the replacement session.
    $prompt = @"
You are continuing a development task that was interrupted because the previous
account reached its individual quota. You are now running under a different
account, so the earlier conversation is not available to you.

Do NOT start the work from scratch.

First reconstruct the real state:
1. Read the handoff file: $file
2. Inspect the workspace at $($c.cwd).
3. Run git status and git diff.
4. Read the transcript referenced in the handoff file to recover intent.
5. Identify which actions already completed - the filesystem and git are the
   source of truth for what ran; the transcript only shows what was intended.
6. Identify what was still pending.
7. Verify before repeating any operation with side effects.
8. Continue from the last consistent point, then tell me where you resumed.
"@

    Write-AgyAutoLog -Message "handoff written for conversation $($c.conversationId)"
    [pscustomobject]@{ Path = $file; Prompt = $prompt }
}
