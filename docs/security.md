# Security

This tool copies OAuth credentials between Windows Credential Manager entries.
That is the entire risk surface, and the design is built to keep it that small.

## Non-negotiables, and how each is enforced

| Rule | Enforcement |
| :--- | :--- |
| Zero plaintext credentials on disk | The blob only ever moves Credential Manager -> memory -> Credential Manager. Nothing else writes it. |
| Zero credentials in logs | `Protect-AgyAutoText` runs on every string reaching a log or event file. |
| Zero credentials in exceptions | Error messages are redacted before being logged or shown. |
| Zero OAuth calls of our own | No HTTP client exists in this codebase. |
| Zero network calls of our own | Only `agy` itself talks to the network. |
| Zero automatic self-update | Nothing calls `git pull`, `agy update`, or any installer. |
| Blob treated as opaque bytes | `byte[]` throughout. Never decoded, never converted to a string. |
| SHA-256 verification | Every write is read back and compared before being called successful. |
| Not copied to the clipboard | No clipboard API is referenced anywhere. |
| Not stored in environment variables | The environment carries only a session id, a PID, a profile name and a path. |
| Not passed as process arguments | Arguments carry flags and prompts only. |
| Not written to stdout/stderr | Only byte counts and truncated fingerprints are ever printed. |
| Sensitive buffers cleared | `Clear-AgyBlob` zeroes each `byte[]` in a `finally` block. |
| The blob's internal JSON never logged | It is never parsed, so there is nothing to log. |

## What is allowed to be visible

Three derived facts, none of which help an attacker who does not already have
the credential:

- **Byte length** (`503 bytes`) - a size, no content.
- **A truncated SHA-256 fingerprint** (16 of 64 hex characters) - identifies
  which account a profile holds and detects drift. Preimage resistance means it
  cannot be reversed; truncation removes even theoretical collision-search value.
- **`LastWritten`** - when agy last refreshed it.

The doctor prints `Secret content: NEVER DISPLAYED` as a standing reminder that
this is a deliberate boundary, not an omission.

## Redaction

Applied to every log line and every event field, in layers, so an unrecognised
token shape is still caught:

1. `key: value` pairs where the key looks credential-ish (`refresh_token`,
   `access_token`, `client_secret`, `authorization`, `cookie`, `bearer`, ...).
2. Google access-token prefixes (`ya29.`).
3. JWT shapes (`eyJ........`).
4. A catch-all for any run of 40+ credential-shaped characters, with path
   segments exempted so logs stay readable.

Redaction is defensive, not primary. The primary defence is that credential
material never reaches a code path that could log it.

## Threat model

### An attacker who can already run code as this user

**Not defended against, and not defensible.** They can call `CredRead` on
`gemini:antigravity` directly - the credential Antigravity itself stores. This
tool adds sibling entries protected by the same Windows ACLs as the original.
It does not lower the bar; it also cannot raise it.

### An attacker who can read files

Defended. `%LOCALAPPDATA%\agy-auto-switch\` holds configuration, state, logs,
checkpoints and handoffs. None contains credential material. The worst it
reveals is which accounts you have named and when they hit quota.

### An attacker who can read logs or a bug report

Defended by redaction plus the fact that credentials never enter those paths.
The test suite asserts this directly: a 503-byte random blob, a Google token, a
JWT and a long opaque run are all rendered unreadable, and every artefact the
integration test produces is scanned for leakage.

### A crash or power loss mid-switch

Defended. `config.json` and `state.json` are written to a temporary file and
swapped in with `File.Replace`, so a reader sees either the old file or the new
one. The credential write itself is a single `CredWrite`, and a rollback
snapshot is held in memory for the duration of the transaction.

### Two switches at once

Defended by a named mutex scoped to the user - `Global` where permitted,
`Local` as a fallback. The loser changes nothing and says so. An abandoned mutex
from a crashed holder is acquired rather than deadlocked on. A real second
process is used to test this, not a simulation.

### A wrong or corrupted credential being installed

Defended. Every write is read back and its SHA-256 compared with what was
intended. A mismatch rolls back to the previous credential and refuses to start
a session.

### Rotating on the wrong signal

Defended by the classifier. A network blip, a plain 429, or an auth failure
must not burn an account, and auth failures specifically must not be papered
over by switching. Covered by explicit tests, including the verbatim error text
from the original report.

### Killing the wrong process

Defended. The supervisor records PID **and** start time at spawn and verifies
both before any termination. A separate `agy` session in another terminal, or a
recycled PID, fails the check. There is no `Get-Process agy | Stop-Process`
anywhere in the codebase.

## Testing without real credentials

The credential backend is swappable: `AGY_AUTO_CRED_BACKEND=memory` substitutes
an in-process store. The suite also redirects `LOCALAPPDATA` to a throwaway
directory, so it cannot read or write real configuration, state, or credentials.
Failure injection (`AGY_AUTO_CRED_FAILWRITE`) exercises the rollback path
without needing a way to make the real Windows API fail.

## Uninstalling safely

`uninstall.ps1` never touches `gemini:antigravity`. It removes the shims, its
own PATH entry, and the plugin. Stored profile credentials are kept unless
`-RemoveProfiles` is passed, and that path requires typing `DELETE` in full.

## Reporting a problem

If you find a way to make this tool expose credential material, that is a
security bug. Include the log line or file that leaked - after checking it does
not contain a live token.
