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
```

`profile save` copies the live Credential Manager entry to
`agy-auto-switch:profile:personal` and verifies the copy by SHA-256. It reports
a byte count and a truncated fingerprint - that is all the visibility that
exists by design.

## Step 3 - register the second account

This is the one manual step in the whole system. The user must sign in as the
second account themselves:

1. Ask them to sign out / sign in to account B using `agy-raw` (the unsupervised
   passthrough, so no rotation logic interferes).
2. Confirm the switch worked: `agy-auto profile current` should now report
   `unknown`, and `agy-auto quota` should show account B's numbers.
3. Save it:

```
agy-auto profile save work
```

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
