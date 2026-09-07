# Troubleshooting

Start here:

```powershell
agy-auto doctor --probe
```

`--probe` spends one tiny turn and proves the Stop hook actually fires. Almost
everything below shows up in that report.

## `agy` still runs the official CLI

`doctor` says `supervisor NOT in front`, or `where agy` lists
`%LOCALAPPDATA%\agy\bin\agy.exe` first.

- **Most likely: your terminal predates setup.** PATH is read at process start.
  Open a new terminal. `doctor` says `This shell started before setup` when this
  is the cause and the persisted PATH is correct.
- Otherwise re-run `.\setup.ps1`, which prepends
  `%LOCALAPPDATA%\agy-auto-switch\bin` to the user PATH.
- Do **not** fix this with `Set-Alias`. `agy install` purges shell aliases as
  part of its normal operation, so an alias disappears at the next update.

## `Recursion guard: FAIL`

`realAgyPath` points inside our own bin directory, so the supervisor would
launch itself forever.

```powershell
agy-auto doctor --fix
```

If that cannot find the real executable, set it by hand in
`%LOCALAPPDATA%\agy-auto-switch\config.json`:

```json
"realAgyPath": "C:\\Users\\<you>\\AppData\\Local\\agy\\bin\\agy.exe"
```

## The Stop hook does not fire

`Stop probe: FAIL`, or a quota error passes with no rotation.

1. Is the plugin there?
   `~\.gemini\config\plugins\agy-auto-switch\plugin.json`
2. Does the hook config parse?
   ```powershell
   Get-Content ~\.gemini\config\plugins\agy-auto-switch\hooks.json -Raw | ConvertFrom-Json
   ```
   The classic failure is a Windows path inside the `command` string: `\s` is
   not a valid JSON escape. Use forward slashes - `scripts/stop-hook.ps1`.
3. Check what agy itself said:
   ```powershell
   Select-String -Path ~\.gemini\antigravity-cli\cli.log -Pattern 'hooks.go|stophooks.go|command_hook_executor'
   ```
   `Failed to parse hooks for plugin agy-auto-switch` names the real reason.
4. Run the hook by hand. It must answer with JSON:
   ```powershell
   Get-Content tests\fixtures\quota-exact.json -Raw | powershell -NoProfile -File scripts\stop-hook.ps1
   ```
5. Read `%LOCALAPPDATA%\agy-auto-switch\logs\hook-errors.log`.

> `agy plugin validate` reports a **malformed** `hooks.json` with the same
> wording as a **missing** one (`hooks: skipped (not found)`). Do not use it to
> conclude the file is absent. `cli.log` tells the truth.

The hook runs under `cmd /c`, with its working directory set to the plugin
directory. Relative script paths are correct; absolute ones are unnecessary.

## PowerShell parse errors from the hook

Windows PowerShell 5.1 reads `.ps1` files as the system ANSI codepage unless
they carry a UTF-8 BOM. A single non-ASCII character - an em dash in a comment
is enough - becomes a parser error. Every `.ps1` in this project is ASCII-only.
Keep it that way if you edit them.

## `Target gemini:antigravity MISSING`

Nobody is signed in. Nothing can work until this exists:

```powershell
agy-raw
```

Sign in, then re-run the doctor.

## A profile says `NO CREDENTIAL`

Metadata survived but the Credential Manager entry did not. Sign in as that
account and save it again:

```powershell
agy-raw                        # sign in as that account
agy-auto profile save <name>
```

## A profile says `fingerprint drift`

Benign, and expected. agy refreshed its own token since the profile was saved,
so the live credential no longer matches the stored copy byte for byte. The
stored copy is re-synced automatically before that profile is abandoned.
`agy-auto profile current` reporting `matched by state-drifted` means the same
thing.

## `agy-auto profile switch` refuses to run

```
N agy process(es) are running. Close them first
```

Correct behaviour, not a bug. agy caches auth in memory and rewrites its own
credential as tokens refresh; swapping underneath a live process gives a session
in an undefined state. Close your agy sessions.

## `Switch lock: held by another process`

Another switch is in progress. If nothing is genuinely running, some process
holding the mutex has not exited - find it rather than forcing anything. The
mutex is released automatically when its holder dies, so this clears on its own
once that process is gone.

## `All profiles are temporarily exhausted`

Working as designed. The report names each account and when the first one comes
back. Check live numbers with:

```powershell
agy-auto quota
```

Exit code 75 means exactly this. If an account should have quota but is marked
exhausted, its `exhaustedUntil` is stale - it clears automatically once the
recorded time passes.

## Rotation happened when it should not have

Test the exact error text against the classifier:

```powershell
. scripts\quota-classifier.ps1
Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText '<paste it>'
```

`shouldRotate` must be `True` only for `INDIVIDUAL_QUOTA`. If a message is
misclassified, that is a bug worth reporting with the text - redact any token
first.

## Rotation did not happen on a real quota error

Same command, on the error you actually got. If it returns `UNKNOWN_ERROR` or
`RATE_LIMIT_TEMPORARY`, the server's wording has moved outside the patterns.
Also confirm the event was written:

```powershell
Get-ChildItem $env:LOCALAPPDATA\agy-auto-switch\events\processed | Select-Object -Last 3
```

## `Unclaimed events: N pending`

Events nobody consumed, usually left by a supervisor that was killed. They are
inert - each is bound to a session id no live supervisor has - and can be
deleted:

```powershell
Remove-Item $env:LOCALAPPDATA\agy-auto-switch\events\*.json
```

## The handoff session started the work over

Check that the handoff file exists and that its git snapshot is populated:

```powershell
Get-ChildItem $env:LOCALAPPDATA\agy-auto-switch\handoffs | Select-Object -Last 1
```

If `isRepo` is false, the working directory was not a git repository, so the
filesystem was the only evidence available. If the transcript path was not
readable, the handoff says so explicitly rather than pretending.

The `agy-quota-recovery` skill carries the protocol the replacement session
should follow.

## Turning it all off

| Goal | Command |
| :--- | :--- |
| Keep the supervisor, stop rotating | `agy-auto disable` |
| One session without the autonomy flag | `agy --safe ...` |
| Bypass everything, once | `agy-raw ...` |
| Remove the tool | `.\uninstall.ps1` |

Uninstall never touches `gemini:antigravity`; `agy` goes back to the official
executable.

## Filing a useful report

Include:

- `agy-auto doctor --probe` output (it prints no secrets)
- `agy --version`
- the classifier verdict for the error text involved
- the tail of `%LOCALAPPDATA%\agy-auto-switch\logs\<date>.log`

Check anything you paste for live tokens first.
