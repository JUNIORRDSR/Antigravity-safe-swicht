. (Join-Path $global:AgyTestRepoRoot 'scripts\handoff.ps1')

function New-QuotaEvent {
    param([string]$Error = 'Individual quota reached. Resets in 1h4m13s.')
    [pscustomobject]@{
        category              = 'INDIVIDUAL_QUOTA'
        conversationId        = 'conv-1234'
        transcriptPath        = (Join-Path $env:LOCALAPPDATA 'fake-transcript.jsonl')
        artifactDirectoryPath = 'C:/brain/conv-1234'
        modelName             = 'gemini-3.8-flash-high'
        workspacePaths        = @()
        resetAt               = (Get-Date).ToUniversalTime().AddMinutes(64).ToString('o')
        errorRedacted         = $Error
    }
}

Describe 'checkpoint' {
    It 'captures continuity data as a file on disk' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        Assert-True (Test-Path -LiteralPath $cp.Path)
        Assert-Equal 'conv-1234' $cp.Data.conversationId
        Assert-Equal 'personal' $cp.Data.fromProfile
        Assert-Equal $global:AgyTestRepoRoot $cp.Data.cwd
        Assert-Equal 'INDIVIDUAL_QUOTA' $cp.Data.reason
    }
    It 'uses the transcript path the hook supplied rather than reconstructing one' {
        $ev = New-QuotaEvent
        $cp = New-AgyCheckpoint -Event $ev -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        Assert-Equal $ev.transcriptPath $cp.Data.transcriptPath
    }
    It 'records real git facts for the working directory' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        Assert-True $cp.Data.git.isRepo 'the project directory is a git repo'
        Assert-Match '^[0-9a-f]{40}$' $cp.Data.git.head
        Assert-NotNull $cp.Data.git.branch
    }
    It 'degrades gracefully outside a repository' {
        $tmp = Join-Path $env:LOCALAPPDATA ('notarepo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $tmp -FromProfile 'personal'
            Assert-False $cp.Data.git.isRepo
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'handoff document' {
    It 'writes a markdown file describing the interruption' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $h = New-AgyHandoff -Checkpoint $cp -ToProfile 'work'
        Assert-True (Test-Path -LiteralPath $h.Path)
        $md = Get-Content -LiteralPath $h.Path -Raw
        Assert-Match 'personal' $md
        Assert-Match 'work' $md
        Assert-Match 'conv-1234' $md
        Assert-Match 'Recovery protocol' $md
    }
    It 'includes the git snapshot so the next session can diff against it' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $h = New-AgyHandoff -Checkpoint $cp -ToProfile 'work'
        $md = Get-Content -LiteralPath $h.Path -Raw
        Assert-Match 'Branch' $md
        Assert-Match 'HEAD' $md
    }
    It 'says the transcript is unreadable rather than pretending it exists' {
        $ev = New-QuotaEvent
        $ev.transcriptPath = 'C:/definitely/not/here/transcript.jsonl'
        $cp = New-AgyCheckpoint -Event $ev -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $h = New-AgyHandoff -Checkpoint $cp -ToProfile 'work'
        Assert-Match 'not readable' (Get-Content -LiteralPath $h.Path -Raw)
    }
}

Describe 'handoff prompt' {
    It 'tells the next session not to start over' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $p = (New-AgyHandoff -Checkpoint $cp -ToProfile 'work').Prompt
        Assert-Match 'NOT start the work from scratch' $p
    }
    It 'points at the handoff file and the working directory' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $h = New-AgyHandoff -Checkpoint $cp -ToProfile 'work'
        Assert-Match ([regex]::Escape($h.Path)) $h.Prompt
        Assert-Match ([regex]::Escape($global:AgyTestRepoRoot)) $h.Prompt
    }
    It 'orders the filesystem to be trusted over the transcript' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $p = (New-AgyHandoff -Checkpoint $cp -ToProfile 'work').Prompt
        Assert-Match 'source of truth' $p
        Assert-Match 'git status' $p
        Assert-Match 'side effects' $p
    }
    It 'survives being passed as a single process argument' {
        . (Join-Path $global:AgyTestRepoRoot 'scripts\common.ps1')
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $p = (New-AgyHandoff -Checkpoint $cp -ToProfile 'work').Prompt
        $line = ConvertTo-AgyAutoArgString -Arguments @('-i', $p)
        $back = ConvertFrom-AgyAutoCommandLine $line
        Assert-Equal 2 $back.Count 'the whole prompt must stay one argument'
        Assert-Equal $p $back[1] 'and arrive byte for byte'
    }
}

Describe 'scenario N: handoff artefacts contain no credential material' {
    It 'never writes a token that appeared in the error text' {
        $ev = New-QuotaEvent -Error 'Individual quota reached. Resets in 5m.'
        $cp = New-AgyCheckpoint -Event $ev -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $h = New-AgyHandoff -Checkpoint $cp -ToProfile 'work'
        foreach ($f in $cp.Path, $h.Path) {
            $raw = Get-Content -LiteralPath $f -Raw
            Assert-NoMatch 'ya29\.' $raw
            Assert-NoMatch 'refresh_token' $raw
            Assert-NoMatch 'credentialBlob' $raw
        }
    }
    It 'records no blob bytes or fingerprints in the checkpoint' {
        $cp = New-AgyCheckpoint -Event (New-QuotaEvent) -Cwd $global:AgyTestRepoRoot -FromProfile 'personal'
        $raw = Get-Content -LiteralPath $cp.Path -Raw
        Assert-NoMatch '(?i)blob' $raw
        Assert-NoMatch '(?i)fingerprint' $raw
    }
}
