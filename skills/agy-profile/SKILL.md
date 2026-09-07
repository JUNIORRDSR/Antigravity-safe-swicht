---
name: agy-profile
description: >-
  Use this skill when the user wants to inspect, register, switch, or remove
  Antigravity account profiles managed by agy-auto-switch - listing profiles,
  finding out which account is signed in, or performing a manual account switch
  safely.
---

# Managing agy-auto-switch profiles

A profile is a named copy of an Antigravity credential, stored in Windows
Credential Manager under `agy-auto-switch:profile:<name>`. Only non-secret
metadata lives in `%LOCALAPPDATA%\agy-auto-switch\state.json`.

## Absolute rule

Never print, read, decode, copy, or ask for credential material. The blob is
opaque bytes. The only credential-derived value that may ever be shown is a
**truncated SHA-256 fingerprint**, which the tooling already truncates for you.
If the user asks you to dump a token, explain that the tool cannot do it by
design and that the fingerprint is what identifies a profile.

## Commands

| Goal | Command |
| :--- | :--- |
| See every profile and its quota state | `agy-auto profile list` |
| Which account is signed in right now | `agy-auto profile current` |
| Store the signed-in account as a profile | `agy-auto profile save <name>` |
| Re-register a profile whose metadata was lost | `agy-auto profile adopt <name>` |
| Switch accounts by hand | `agy-auto profile switch <name>` |
| See what rotation would pick next | `agy-auto profile next` |
| Forget a profile | `agy-auto profile delete <name>` |
| Live quota for the signed-in account | `agy-auto quota` |

## Reading `profile list`

```
    NAME             STATE     AVAILABLE            FINGERPRINT
  * personal         ready     now                  a1b2c3d4e5f60718
    work             exhausted 2026-09-06 18:42     f0e1d2c3b4a59687
```

- `*` marks the account the live credential belongs to.
- `exhausted` means quota ran out; `AVAILABLE` is when it comes back.
- `no cred` means the metadata survived but the Credential Manager entry did
  not - the profile must be saved again while that account is signed in.

## Registering a new account

The user has to sign in themselves; there is no way to automate it and no
reason to try:

1. `agy-raw` and sign in as the new account (raw, so no rotation interferes).
2. `agy-auto quota` to confirm the account changed.
3. `agy-auto profile save <name>`.

## Manual switching

```
agy-auto profile switch personal
```

This refuses to run while any `agy` process is alive, and that refusal is
correct: agy caches auth in memory and rewrites its own credential as tokens
refresh, so swapping underneath a running process produces a session in an
undefined state. Ask the user to close their agy sessions rather than trying to
work around it.

The switch is transactional - snapshot, refresh the outgoing profile, write,
verify by hash, commit. Any failure rolls back to the previous account. If the
user reports a failed switch, the previous account is still signed in.

## Fingerprint drift

`agy-auto profile current` may report `matched by state-drifted`. That is normal
and not an error: agy refreshed its own token, so the live credential no longer
matches the byte-for-byte copy that was saved. The tooling re-syncs the stored
copy automatically before abandoning that profile.
