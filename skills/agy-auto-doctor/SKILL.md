---
name: agy-auto-doctor
description: >-
  Use this skill when agy-auto-switch is misbehaving or needs verification - the
  Stop hook not firing, `agy` resolving to the wrong executable, suspected
  wrapper recursion, profiles reporting drift or missing credentials, stale
  locks, or after Antigravity CLI has been reinstalled or updated.
---

# Diagnosing agy-auto-switch

## Start here

```
agy-auto doctor
```

Add `--probe` to spend one tiny turn proving the Stop hook fires. Add `--fix` to
let it repair a stale `realAgyPath` automatically.

Never paste credential material into a diagnosis. The doctor prints blob length
and a truncated fingerprint on purpose; that is the whole permitted surface.

## Reading the report

### Antigravity CLI

- `realAgyPath NOT FOUND` - Antigravity was moved, updated or uninstalled. Run
  `agy-auto doctor --fix`, or re-run `.\setup.ps1`.
- `Recursion guard: FAIL` - `realAgyPath` points inside our own shim directory,
  so the supervisor would call itself forever. Re-run setup from a shell where
  `agy` still resolves to the official executable, or set `realAgyPath` in
  `%LOCALAPPDATA%\agy-auto-switch\config.json` by hand.

### Command routing

All three names must resolve into `%LOCALAPPDATA%\agy-auto-switch\bin`:

```
  agy       C:\...\agy-auto-switch\bin\agy.cmd -> AGY Auto Supervisor   OK
```

- `supervisor NOT in front` - our bin directory is missing from the user PATH or
  sits after `%LOCALAPPDATA%\agy\bin`. Re-run setup, then open a NEW terminal.
- `agy install` purges shell aliases, which is exactly why this uses `.cmd`
  shims. Do not try to "fix" routing with `Set-Alias` - it will be wiped.

### Plugin

- `hooks.json INVALID JSON` - the hook will never run. The usual cause is a
  Windows path with backslashes inside the `command` string; `\s` is not a valid
  JSON escape. Use forward slashes: `scripts/stop-hook.ps1`.
- `Hook seen in cli.log: not yet` - only means no turn has run since install.
  Use `--probe`.
- If `agy plugin validate` reports `hooks: skipped (not found)` while the file
  clearly exists, the JSON does not parse - that command uses the same wording
  for both cases. Confirm in `~/.gemini/antigravity-cli/cli.log`, which logs
  `Failed to parse hooks for plugin <name>` with the real reason.

### Credential Manager

- `Target gemini:antigravity MISSING` - nobody is signed in. Run `agy-raw` and
  sign in. Nothing else can work until this entry exists.

### Profiles

- `NO CREDENTIAL` - metadata exists but the Credential Manager entry does not.
  Sign in as that account and run `agy-auto profile save <name>` again.
- `fingerprint drift` - benign. agy refreshed its token since the profile was
  saved; the stored copy is re-synced automatically before that profile is
  abandoned.
- `exhausted until HH:MM` - out of quota. `agy-auto quota` shows live numbers.

### Supervisor

- `Switch lock: held by another process` - a switch is in progress. If nothing
  is genuinely running, the mutex belongs to a process that has not exited; find
  it rather than forcing anything.
- `Unclaimed events: N pending` - events nobody consumed, usually from a
  supervisor that was killed. They are inert, because each is bound to a session
  id, but they can be deleted from `%LOCALAPPDATA%\agy-auto-switch\events\`.

## When the hook genuinely does not fire

1. Confirm the plugin is discovered:
   `~/.gemini/config/plugins/agy-auto-switch/plugin.json` must exist.
2. Confirm the JSON parses:
   `Get-Content hooks.json -Raw | ConvertFrom-Json`.
3. Grep `cli.log` for `hooks.go`, `stophooks.go`, `command_hook_executor`.
4. Run the hook by hand and check it answers with JSON:

```
Get-Content tests\fixtures\quota-exact.json -Raw | powershell -NoProfile -File scripts\stop-hook.ps1
```

5. Read `%LOCALAPPDATA%\agy-auto-switch\logs\hook-errors.log`.

Remember: the hook's working directory is the plugin directory, and the shell
that launches it is `cmd /c`.

## Escape hatches

- `agy-auto disable` - keep the supervisor, stop rotating.
- `agy-raw` - the real agy, no supervisor, no added flags.
- `.\uninstall.ps1` - remove everything. It never touches the live
  `gemini:antigravity` credential.
