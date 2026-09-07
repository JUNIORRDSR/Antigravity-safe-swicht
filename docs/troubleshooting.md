# Troubleshooting

Start here:

```powershell
agy-auto doctor --probe
```

`--probe` spends one tiny turn and proves the Stop hook actually fires. Almost
everything below shows up in that report.

## `agy-raw` is not recognised as a command

```
agy-raw : El termino 'agy-raw' no se reconoce como nombre de un cmdlet ...
CommandNotFoundException
```

The shims exist; your shell does not know about them yet. PATH is read once, at
process start, so the terminal you ran `setup.ps1` in - and any terminal opened
before it - still carries the old value. This is the single most common first
five minutes of this tool.

Open a new terminal. Or refresh the current one without closing it:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
```

If a brand-new terminal still cannot find it, the persisted PATH is the problem,
not the session:

```powershell
[Environment]::GetEnvironmentVariable('Path','User') -split ';' | Select-String agy-auto-switch
```

Nothing back means `setup.ps1` did not get to the PATH step, or was run with
`-SkipPath`. Re-run `.\setup.ps1`.

## `profile list` says none right after a successful save

`agy-auto profile save work` prints `Saved profile 'work' ...` and the very next
`agy-auto profile list` answers `No profiles registered`.

Profile metadata lives in `%LOCALAPPDATA%\agy-auto-switch\state.json`, separately
from the credential itself. That message means the file the save wrote is not
the file the list read. Check whether it exists at all, **from your own
terminal**:

```powershell
dir $env:LOCALAPPDATA\agy-auto-switch
```

- **No `state.json`, and `config.json` is dated moments ago.** The directory was
  recreated from defaults by the command you just ran. Whatever earlier setup
  wrote never landed here. Save the profiles again from this terminal, verifying
  with `profile list` after each one.
- **`state.json` is present but `profile list` still reports none.** The file is
  unreadable or not valid JSON, and `Read-AgyAutoJson` degrades to an empty state
  rather than crashing. Confirm with:
  ```powershell
  Get-Content $env:LOCALAPPDATA\agy-auto-switch\state.json -Raw | ConvertFrom-Json
  ```
  A parse error here is the answer. Delete the file and re-save the profiles;
  nothing in it is a secret and none of it is unrecoverable.

If an AI agent ran the setup on your behalf, be aware its shell may resolve a
different `%LOCALAPPDATA%` than your console does - a save that succeeded in its
view can be invisible in yours. Onboarding commands belong in your own terminal.
The stored credentials survive either way: they are in Credential Manager under
`agy-auto-switch:profile:<name>`, and only the names and rotation order are lost
with `state.json`.

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
