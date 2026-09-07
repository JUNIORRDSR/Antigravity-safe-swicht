# credential-manager.ps1 - Windows Credential Manager access.
#
# The credential blob is opaque bytes. Nothing here parses it, decodes it,
# logs it, or lets it escape as a return value in string form. Callers get
# bytes or a fingerprint, never text.
#
# Backend is pluggable purely so the test suite can run without touching real
# credentials: set $env:AGY_AUTO_CRED_BACKEND = 'memory'.

Set-StrictMode -Version 2.0

$script:AgyLiveTarget = 'gemini:antigravity'
function Get-AgyLiveTarget { $script:AgyLiveTarget }
function Get-AgyProfileTarget { param([Parameter(Mandatory)][string]$Name) "agy-auto-switch:profile:$Name" }

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AgyAuto {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags;
    public uint Type;
    public IntPtr TargetName;
    public IntPtr Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    public IntPtr TargetAlias;
    public IntPtr UserName;
  }

  public static class CredApi {
    public const uint CRED_TYPE_GENERIC = 1;
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredReadW")]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredWriteW")]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredDeleteW")]
    public static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll", SetLastError = false)]
    public static extern void CredFree(IntPtr buffer);
  }
}
'@

$script:AgyMemoryStore = @{}

function Get-AgyCredBackend {
    if ($env:AGY_AUTO_CRED_BACKEND -eq 'memory') { 'memory' } else { 'wincred' }
}

# --------------------------------------------------------------------- read --

function Get-AgyCredential {
    param([Parameter(Mandatory)][string]$Target)

    if ((Get-AgyCredBackend) -eq 'memory') {
        if (-not $script:AgyMemoryStore.ContainsKey($Target)) { return $null }
        $e = $script:AgyMemoryStore[$Target]
        return [pscustomobject]@{
            Target = $Target; Blob = $e.Blob.Clone(); UserName = $e.UserName
            Persist = $e.Persist; Type = 1; LastWrittenUtc = $e.LastWrittenUtc
        }
    }

    $ptr = [IntPtr]::Zero
    if (-not [AgyAuto.CredApi]::CredRead($Target, [AgyAuto.CredApi]::CRED_TYPE_GENERIC, 0, [ref]$ptr)) {
        return $null   # 1168 ERROR_NOT_FOUND is the normal miss; do not surface Win32 text
    }
    try {
        $c = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type]'AgyAuto.CREDENTIAL')
        $n = [int]$c.CredentialBlobSize
        $blob = New-Object byte[] $n
        if ($n -gt 0) { [Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $blob, 0, $n) }
        $user = if ($c.UserName -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::PtrToStringUni($c.UserName) } else { '' }
        $ft = $c.LastWritten
        $lw = [datetime]::FromFileTimeUtc((([long]$ft.dwHighDateTime) -shl 32) -bor (([long]$ft.dwLowDateTime) -band 0xFFFFFFFFL))
        [pscustomobject]@{
            Target = $Target; Blob = $blob; UserName = $user
            Persist = $c.Persist; Type = $c.Type; LastWrittenUtc = $lw
        }
    } finally { [AgyAuto.CredApi]::CredFree($ptr) }
}

# -------------------------------------------------------------------- write --

function Set-AgyCredential {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][byte[]]$Blob,
        [string]$UserName = 'antigravity',
        [uint32]$Persist = 2   # CRED_PERSIST_LOCAL_MACHINE, matching what agy writes
    )

    if ((Get-AgyCredBackend) -eq 'memory') {
        if ($env:AGY_AUTO_CRED_FAILWRITE -eq $Target) { throw "CredWrite failed for '$Target' (simulated)" }
        $script:AgyMemoryStore[$Target] = @{
            Blob = $Blob.Clone(); UserName = $UserName; Persist = $Persist; LastWrittenUtc = [datetime]::UtcNow
        }
        return
    }

    $c = New-Object AgyAuto.CREDENTIAL
    $c.Type = [AgyAuto.CredApi]::CRED_TYPE_GENERIC
    $c.Persist = $Persist
    $c.AttributeCount = 0
    $c.TargetName = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($Target)
    $c.UserName = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($UserName)
    $gc = [Runtime.InteropServices.GCHandle]::Alloc($Blob, 'Pinned')
    try {
        $c.CredentialBlob = $gc.AddrOfPinnedObject()
        $c.CredentialBlobSize = [uint32]$Blob.Length
        if (-not [AgyAuto.CredApi]::CredWrite([ref]$c, 0)) {
            throw ("CredWrite failed for '{0}' (win32 {1})" -f $Target, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    } finally {
        $gc.Free()
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($c.TargetName)
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($c.UserName)
    }
}

function Remove-AgyCredential {
    param([Parameter(Mandatory)][string]$Target)
    if ((Get-AgyCredBackend) -eq 'memory') {
        $had = $script:AgyMemoryStore.ContainsKey($Target)
        $script:AgyMemoryStore.Remove($Target) | Out-Null
        return $had
    }
    [AgyAuto.CredApi]::CredDelete($Target, [AgyAuto.CredApi]::CRED_TYPE_GENERIC, 0)
}

function Reset-AgyCredentialMemoryStore { $script:AgyMemoryStore = @{} }

# -------------------------------------------------------------- fingerprint --

function Get-AgyBlobFingerprint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Blob)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Blob)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Only ever show a truncated fingerprint to a human.
function Format-AgyFingerprint {
    param([AllowNull()][string]$Fingerprint)
    if ([string]::IsNullOrEmpty($Fingerprint)) { return '(none)' }
    $Fingerprint.Substring(0, [Math]::Min(16, $Fingerprint.Length))
}

# Best-effort scrub of a blob we are done with.
function Clear-AgyBlob {
    param([AllowNull()][byte[]]$Blob)
    if ($null -ne $Blob) { [Array]::Clear($Blob, 0, $Blob.Length) }
}

# Non-secret description of a credential, safe to print or log.
function Get-AgyCredentialInfo {
    param([Parameter(Mandatory)][string]$Target)
    $c = Get-AgyCredential -Target $Target
    if ($null -eq $c) { return [pscustomobject]@{ Target = $Target; Present = $false } }
    try {
        [pscustomobject]@{
            Target         = $Target
            Present        = $true
            BlobBytes      = $c.Blob.Length
            Fingerprint    = Get-AgyBlobFingerprint $c.Blob
            UserName       = $c.UserName
            Persist        = $c.Persist
            LastWrittenUtc = $c.LastWrittenUtc
        }
    } finally { Clear-AgyBlob $c.Blob }
}

# Copy a credential between targets and prove the bytes landed intact.
# Returns the fingerprint on success; throws on mismatch.
function Copy-AgyCredential {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    $src = Get-AgyCredential -Target $From
    if ($null -eq $src) { throw "Source credential '$From' not found" }
    try {
        $expected = Get-AgyBlobFingerprint $src.Blob
        Set-AgyCredential -Target $To -Blob $src.Blob -UserName $src.UserName -Persist $src.Persist
        $back = Get-AgyCredential -Target $To
        if ($null -eq $back) { throw "Verification failed: '$To' unreadable after write" }
        try {
            $actual = Get-AgyBlobFingerprint $back.Blob
            if ($actual -ne $expected) { throw "Verification failed: '$To' fingerprint mismatch after write" }
            $expected
        } finally { Clear-AgyBlob $back.Blob }
    } finally { Clear-AgyBlob $src.Blob }
}
