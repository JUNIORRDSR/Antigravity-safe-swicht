# agy-auto-switch

Antigravity CLI runs out of individual quota. You switch accounts by hand. This
makes that automatic, on Windows, without ever touching a token.

```
PS C:\Workspace\my-project> agy

[agy-auto] profile: personal
[agy-auto] supervisor active

<Antigravity TUI>

... Individual quota reached. Resets in 1h4m13s.

[agy-auto] quota detected
[agy-auto] checkpoint stored
[agy-auto] personal unavailable until 19:32
[agy-auto] switching personal -> work
[agy-auto] resume original conversation rejected; using handoff
[agy-auto] starting replacement session
[agy-auto] resuming task...
```

You keep typing `agy`. Nothing else changes.

## What it actually does

- Detects individual quota exhaustion through Antigravity's official `Stop`
  lifecycle hook.
- Stores a checkpoint - conversation id, transcript path, git state - before
  anything is touched.
- Closes **only the agy process it started**, verified by PID *and* start time.
- Refreshes the outgoing account's stored credential first, because agy rewrites
  its own credential as tokens refresh.
- Picks the next account, writes its credential, and **verifies the account has
  quota left before committing to it** by asking agy itself.
- Tries to resume the original conversation. When the new account cannot open
  it, writes a handoff and starts a fresh session that reconstructs the real
  state from git and the filesystem.
- Parks the drained account until its real reset time and never rotates in a
  loop.

Credentials never leave Windows Credential Manager. Nothing is written to disk
in plaintext, nothing reaches a log, and the blob is treated as opaque bytes.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows)
- Antigravity CLI (`agy`), signed in
- Two or more accounts you own

No Node, no Python, no npm, no external services, no network calls of its own.

## Install

```powershell
git clone <this repo>
cd agy-auto-switch
.\setup.ps1
```

Setup finds the real `agy.exe` **before** installing anything, installs the
plugin, writes the command shims, puts them first on your user PATH, and runs
the doctor.

Then open a **new terminal** - PATH is read at process start, so the shell you
ran setup in still cannot see `agy`, `agy-auto` or `agy-raw`. Register account A:

```powershell
agy-auto profile save personal   # whichever account is signed in now
agy-auto profile list            # must now list it
```

Sign in as account B once, by hand - this is the only manual step. agy has no
`logout` subcommand, so drop the live credential and let it ask again. Account A
is already safe in its own Credential Manager entry at this point:

```powershell
cmdkey /delete:gemini:antigravity
agy-raw                          # the real agy, unsupervised; sign in as B
agy-auto profile save work
agy-auto profile list            # two profiles, two DIFFERENT fingerprints
```

Two identical fingerprints mean the same account was saved twice and the sign-in
did not take. Changed your mind mid-way? `agy-auto profile switch personal`
puts account A back.

Check everything:

```powershell
agy-auto doctor --probe
```

`--probe` spends one tiny turn to prove the Stop hook really fires. Aim for
`Result: READY`.

From then on:

```powershell
agy
```

## Commands

`agy` is the interface. Everything below is for diagnosis and setup.

| Command | What it does |
| :--- | :--- |
| `agy [args...]` | Normal work, supervised, autonomous by default |
| `agy --safe [args...]` | Supervised, but without `--dangerously-skip-permissions` |
| `agy-raw [args...]` | The real agy. No supervisor, no rotation, no added flags |
| `agy-auto run [args...]` | Supervised headless run for long unattended tasks |
| `agy-auto profile list` | Profiles, quota state, fingerprints |
| `agy-auto profile save <name>` | Store the signed-in account |
| `agy-auto profile adopt <name>` | Re-register a profile from its stored credential |
| `agy-auto profile current` | Which account is signed in |
| `agy-auto profile switch <name>` | Manual switch (refuses while agy is running) |
| `agy-auto profile next` | What rotation would pick next |
| `agy-auto profile delete <name>` | Forget a profile |
| `agy-auto quota` | Live quota for the signed-in account |
| `agy-auto status` | Config and state summary |
| `agy-auto doctor [--probe] [--fix]` | Full diagnosis |
| `agy-auto enable` / `disable` | Turn rotation on or off |

## Autonomy

Sessions started through `agy` get `--dangerously-skip-permissions`
automatically. `agy --safe` opts out for one session; `agy-auto disable` keeps
the supervisor but stops rotating; `agy-raw` bypasses everything.

Setup can also write persistent autonomous defaults into
`~/.gemini/antigravity-cli/settings.json`:

```powershell
.\setup.ps1 -ConfigureAutonomy
```

That sets `toolPermission`, `artifactReviewPolicy` and `agentMode`. It reads the
existing file, changes only those keys, keeps everything else including
`trustedWorkspaces` and any key it does not recognise, backs the file up, writes
atomically, and rolls back if agy rejects the result.

## What gets installed

```
%LOCALAPPDATA%\agy-auto-switch\
    config.json           non-secret settings, including realAgyPath
    state.json            profile metadata: order, exhaustion, fingerprints
    bin\                  agy.cmd, agy-auto.cmd, agy-raw.cmd
    events\               Stop hook -> supervisor messages
    checkpoints\          continuity snapshots
    handoffs\             handoff documents
    logs\                 redacted logs

~\.gemini\config\plugins\agy-auto-switch\    the plugin itself

Windows Credential Manager
    gemini:antigravity                    the live credential (agy's own, untouched)
    agy-auto-switch:profile:<name>        one per registered account
```

Only the user PATH is modified, by prepending one entry.

## Uninstall

```powershell
.\uninstall.ps1
```

Removes the shims, removes **only our** PATH entry, uninstalls the plugin. It
never touches `gemini:antigravity`, and `agy` goes back to the official
executable. Add `-RemoveProfiles` to delete stored account credentials,
`-Purge` for logs and handoffs, `-RestoreSettings` to roll back the autonomy
settings.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

129 checks, no dependencies, no real credentials: the credential store is
substituted in memory and `LOCALAPPDATA` is redirected to a throwaway
directory. Includes end-to-end runs of the whole supervisor loop against a
stand-in agy - real Stop hook, real classifier, real switch transaction, real
handoff.

## Documentation

- [docs/research.md](docs/research.md) - what was measured on this machine, and
  which assumptions turned out wrong
- [docs/architecture.md](docs/architecture.md) - the design and why the switch
  happens between processes
- [docs/security.md](docs/security.md) - threat model and credential handling
- [docs/troubleshooting.md](docs/troubleshooting.md) - when something breaks

## The one rule

The credential is only ever swapped **between** agy processes. agy caches auth
in memory and rewrites its own credential as tokens refresh, so a hot swap under
a running agy.exe produces a session in an undefined state. Everything in this
design follows from that.
