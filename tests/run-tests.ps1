# run-tests.ps1 - dependency-free test runner.
#
# Pester 3.4 ships with Windows but its syntax differs from Pester 5, and
# requiring a module install contradicts the "no extra dependencies" rule.
# A 40-line assert runner covers everything this project needs.

[CmdletBinding()]
param([string]$Filter = '*')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Context = ''

function Describe {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    $script:Context = $Name
    Write-Host ''
    Write-Host $Name -ForegroundColor Cyan
    & $Body
}

function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ('  [pass] ' + $Name) -ForegroundColor Green
    } catch {
        $script:Fail++
        $msg = '{0} / {1}: {2}' -f $script:Context, $Name, $_.Exception.Message
        $script:Failures.Add($msg)
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        Write-Host ('         ' + $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) {
        throw ("expected [{0}] but got [{1}]{2}" -f $Expected, $Actual, $(if ($Because) { " - $Because" } else { '' }))
    }
}
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "expected true - $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "expected false - $Because" } }
function Assert-Null { param($Value, [string]$Because = '') if ($null -ne $Value) { throw "expected null but got [$Value] - $Because" } }
function Assert-NotNull { param($Value, [string]$Because = '') if ($null -eq $Value) { throw "expected non-null - $Because" } }
function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Because = '')
    if ($Text -notmatch $Pattern) { throw "expected [$Text] to match /$Pattern/ - $Because" }
}
function Assert-NoMatch {
    param([string]$Pattern, [string]$Text, [string]$Because = '')
    if ($Text -match $Pattern) { throw "expected [$Text] NOT to match /$Pattern/ - $Because" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Because = '')
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw "expected a terminating error - $Because" }
}

$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir

# Full isolation: fake credential store, and a throwaway LOCALAPPDATA so the
# suite can never read or write the real config, state, events or credentials.
$env:AGY_AUTO_CRED_BACKEND = 'memory'
$script:SandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("agy-auto-tests-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:SandboxRoot | Out-Null
$script:RealLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $script:SandboxRoot
$global:AgyTestRepoRoot = $repoRoot

Write-Host "agy-auto-switch test suite" -ForegroundColor White
Write-Host ("repo:    {0}" -f $repoRoot) -ForegroundColor DarkGray
Write-Host ("sandbox: {0}" -f $script:SandboxRoot) -ForegroundColor DarkGray

foreach ($f in Get-ChildItem -LiteralPath $testsDir -Filter '*.tests.ps1' | Sort-Object Name) {
    if ($f.BaseName -notlike $Filter -and $f.BaseName -notlike "*$Filter*") { continue }
    . $f.FullName
}

$env:LOCALAPPDATA = $script:RealLocalAppData
Remove-Item -LiteralPath $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host ''
    foreach ($m in $script:Failures) { Write-Host ('  - ' + $m) -ForegroundColor Red }
    exit 1
}
exit 0
