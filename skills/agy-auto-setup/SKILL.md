---
name: agy-auto-setup
description: >-
  Use this skill when the user is installing, configuring, or first-time
  onboarding agy-auto-switch: registering account profiles, verifying that the
  Stop hook fires, checking the command shims, or running a dry-run rehearsal of
  a quota switch without touching real credentials.
---

# agy-auto-switch setup

Guide the user through onboarding. Never print, echo, or ask for credential
material at any point - the whole design exists so that nobody, including you,
has to look at a token.

## Run the commands in the user's own terminal

Ask the user to run each command and paste the output. Do not substitute your
own tool calls for theirs and do not report a step as done on the strength of a
file you read yourself.

Two reasons, both real. Sign-in is interactive and cannot happen inside a tool
call at all. And an agent shell may be sandboxed or otherwise resolve a
different view of `%LOCALAPPDATA%` than the user's console, in which case a
`profile save` you ran "succeeds" against a `state.json` the user's `agy` will
never read. Every step below therefore has a verification command whose output
comes from the user.

If your reading of the filesystem ever contradicts what the user's terminal
prints, the terminal is right.

## Step 1 - diagnose before changing anything

```
agy-auto doctor
```

Read the output section by section. The likely first-run findings:

| Finding | What to do |
| :--- | :--- |
| `realAgyPath NOT FOUND` | Antigravity CLI is not installed or not on PATH. Stop and tell the user. |
| `agy ... (supervisor NOT in front)` | Shims are missing or PATH order is wrong. Run `.\setup.ps1`. |
| `Profiles: none` | Expected on a first run. Continue to step 2. |
| `Target gemini:antigravity MISSING` | The user is not signed in. They must run `agy-raw` and sign in first. |

## Step 2 - register the first account

Confirm which account is signed in before saving, because the profile name is
just a label the user chooses:

```
agy-auto quota
agy-auto profile save personal
agy-auto profile list
```

`profile save` copies the live Credential Manager entry to
`agy-auto-switch:profile:personal` and verifies the copy by SHA-256. It reports
a byte count and a truncated fingerprint - that is all the visibility that
exists by design.

`profile list` is not optional. If it still says `No profiles registered` after
a save that reported success, stop: `state.json` is not persisting where the
user's `agy` reads it, and nothing downstream will work. See "profile list says
none right after a successful save" in `docs/troubleshooting.md`.

## Step 3 - register the second account

This is the one manual step in the whole system, and the user has to do the
sign-in themselves.

agy has no `logout` subcommand - `agy --help` lists none - so the way to make it
ask again is to remove the live credential. This is safe only *after* step 2
verified account A is stored under its own profile:

```
cmdkey /delete:gemini:antigravity
agy-raw
```

`agy-raw` is the unsupervised passthrough, so no rotation logic interferes with
the sign-in. Have the user sign in as account B and leave the TUI, then:

```
agy-auto profile save work
agy-auto profile list
```

Both profiles must appear with **different** fingerprints. Identical
fingerprints mean the same account was saved under two names because the
sign-in did not take - delete the second profile and redo the sign-in rather
than leaving a rotation that switches to the account it just left.

If the sign-in fails or the user changes their mind, `agy-auto profile switch
personal` rewrites the live credential from the stored copy. Nothing was lost by
the `cmdkey /delete`.

Repeat for any further accounts. Order of registration is the rotation order.

## Step 4 - verify the hook actually fires

The Stop hook is the detector. On Windows it must be proven, not assumed:

```
agy-auto doctor --probe
```

This spends one tiny turn. `Stop probe: PASS` means the hook ran. If it does
not pass, look at `~/.gemini/antigravity-cli/cli.log` for lines containing
`hooks.go` or `stophooks.go` - a malformed `hooks.json` is reported there as a
parse failure, while `agy plugin validate` merely says "not found".

## Step 5 - rehearse without touching real credentials

Run the test suite. It uses an in-memory credential store and a throwaway
`LOCALAPPDATA`, so it never reads or writes a real credential:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

To rehearse the classifier against the user's own error text:

```powershell
. scripts\quota-classifier.ps1
Get-AgyQuotaClassification -TerminationReason 'ERROR' -ErrorText '<paste the error>'
```

`shouldRotate = True` means that message would trigger a switch.

## Step 6 - confirm the finished state

```
agy-auto doctor
```

Target output: `Command routing` all OK, at least two profiles `OK`, and
`Result: READY`. From then on the user just types `agy`.

## Things to tell the user

- `agy` is now the supervisor. `agy-raw` is the escape hatch.
- Sessions get `--dangerously-skip-permissions` automatically; `agy --safe`
  opts out for one session.
- Rotation only happens on individual quota exhaustion - never on a network
  error, a plain 429, or an auth failure.
