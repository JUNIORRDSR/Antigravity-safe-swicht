# Architecture

Every design decision here traces back to a measurement in
[research.md](research.md). Where documentation and observed behaviour
disagreed, observed behaviour won.

## The constraint everything follows from

**The credential may only be swapped between agy processes.**

`agy` rewrites `gemini:antigravity` while it runs - the `LastWritten` timestamp
moved during a single session, on this machine, with nothing but a couple of
turns executed. It also holds auth state in memory. A `CredWrite` underneath a
live `agy.exe` therefore produces one of three outcomes, none of them good: the
old token stays in use, the new credential is overwritten by a refresh of the
old account, or the session lands in a state neither account explains.

So the switch is a transition between two processes, and the supervisor exists
to own that transition.

## The two pieces

```
   user types: agy [args...]
        |
        v
   agy.cmd  (%LOCALAPPDATA%\agy-auto-switch\bin, first on PATH)
        |  AGY_AUTO_RAWARGS=<verbatim command-line tail>
        v
   agy-auto.ps1  --  supervisor
        |  CommandLineToArgvW -> exact argv
        |  + --dangerously-skip-permissions (unless --safe)
        v
   realAgyPath  (C:\Users\<you>\AppData\Local\agy\bin\agy.exe)
        |
        |  Stop lifecycle hook, from the installed plugin
        v
   stop-hook.ps1 -> events\*.json -> back to the supervisor
```

The **plugin** provides detection and the skills. The **supervisor** provides
process control and the switch. Neither works alone.

### Why a `.cmd` shim and not an alias

`agy install` carries a flag documented as *"Bypasses shell profile alias
purging"* - it purges shell aliases as part of its normal work. Any `Set-Alias`
approach would be silently removed the next time Antigravity updates itself. A
`.cmd` file on a PATH directory ordered ahead of `%LOCALAPPDATA%\agy\bin` is not
something `agy install` touches.

### Why `realAgyPath` is resolved before the shim exists

After installation, `agy` on PATH *is* the wrapper. Resolving `agy` at runtime
would find the wrapper and recurse forever. Setup discovers the real executable
first, records it in `config.json`, and the supervisor only ever launches that
recorded path. `doctor` checks explicitly that `realAgyPath` does not point
inside our own bin directory.

### Why arguments travel through an environment variable

`%*` in a `.cmd` is the verbatim command-line tail. Passing it on as PowerShell
parameters would re-tokenise it twice - once by cmd, once by PowerShell - and a
prompt containing quotes would silently change meaning. Instead the tail goes
into `AGY_AUTO_RAWARGS` and is parsed once by `CommandLineToArgvW`, the same
function Windows itself uses. On the way out, the argument array is re-quoted
with the matching MSVCRT rules and handed to `ProcessStartInfo.Arguments`.

`Start-Process -ArgumentList` is not used: Windows PowerShell 5.1 joins its
entries with plain spaces, which destroys any argument containing one - such as
the entire handoff prompt.

## Detection

The `Stop` hook receives, per the payload captured on this machine:

```
conversationId  workspacePaths  transcriptPath  artifactDirectoryPath
modelName       terminationReason  error  executionNum  fullyIdle
```

The hook is deliberately thin. It reads stdin, classifies, writes one atomic
event file, and answers. It never switches anything - it runs inside the agent
loop, and the switch must happen after that loop is gone.

### The classifier

Six categories; exactly one rotates.

| Category | Rotates | Example |
| :--- | :---: | :--- |
| `INDIVIDUAL_QUOTA` | yes | "Individual quota reached... Resets in 1h4m13s" |
| `RATE_LIMIT_TEMPORARY` | no | bare HTTP 429, bare `RESOURCE_EXHAUSTED` |
| `AUTH_ERROR` | no | `Unauthenticated`, `invalid_grant`, 401/403 |
| `NETWORK_ERROR` | no | `dial tcp`, `deadline exceeded`, TLS timeout |
| `MODEL_ERROR` | no | unsupported model, context length |
| `UNKNOWN_ERROR` | no | anything unmatched |

The exact user-facing quota string is **not** in the agy binary - it is
server-supplied. Matching one literal would break the day the wording changes,
so the classifier matches a family of phrasings and additionally accepts the
word "quota" next to an explicit reset countdown.

Auth errors deliberately do not rotate. A broken credential would break the next
account too, and rotating would hide the real problem behind an account switch.

### Correlating hook and supervisor

`workspacePaths` came back empty in print mode, so the payload alone cannot say
which supervised session a stop belongs to. The supervisor sets
`AGY_AUTO_SESSION` on the child process; the hook reads it back out of its
inherited environment and stamps it on the event. A supervisor only ever picks
up events carrying its own session id, so two supervisors running side by side
never see each other's work.

The session id identifies the supervisor, not the child - and that is not enough
on its own. One agy emits a `Stop` event per conversation, its own plus every
sub-agent's, so a session drained by quota writes a burst of them across the
seconds it takes to shut down. Read back after the switch they all still carry
the live session id, and the first leftover looks exactly like a fresh quota hit
on the account that just took over: the supervisor kills a healthy session,
marks the new profile exhausted with the old one's reset time, and runs out of
profiles. So the supervisor also gives every child its own token in
`AGY_AUTO_CHILD`, which the hook stamps on the event: an event names its author
outright, and anything carrying someone else's token is archived unread.

A timestamp is not enough on its own. A hook is a separate process that agy
launches and waits on, and it can outlive the agy that spawned it - terminating
the child does not stop a hook already running, so its event can land seconds
later, after the replacement session has started. Verified by replaying the
incident: the spawn instant caught three leftovers and missed the two written
after the switch. The spawn instant remains the fallback for an event with no
token.

Events whose supervisor never came back - a crash, a Ctrl+C, a rotation that
gave up - carry a session id that can never match again. A sweep at startup
archives anything older than an hour, which no live supervisor can still be
waiting on.

## The supervisor state machine

```
IDLE -> STARTING -> RUNNING
                      |
                      +-- child exits, no event ------------> COMPLETED
                      |
                      +-- QUOTA_EXHAUSTED event
                             |
                             v
                      QUOTA_DETECTED
                             v
                      CHECKPOINTING            git + conversation + transcript
                             v
                      STOPPING_CHILD           clean first, terminate only after
                             v                 the checkpoint is on disk
                      SAVING_CURRENT_PROFILE   park A until its real reset time
                             v
                      SWITCHING_PROFILE        transactional, verified, rollback
                             v
                      STARTING_REPLACEMENT
                             |
                    +--------+--------+
                    v                 v
                 RESUMING          HANDOFF
                    |                 |
                    +--------+--------+
                             v
                          RUNNING ...
```

Failure paths lead to `FAILED` with a non-zero exit code; nothing is left in a
half-switched state.

### Stopping the child safely

Termination is gated on four conditions, all of which must hold:

1. the `Stop` hook has already fired (we have its event),
2. the transcript path it reported has been recorded,
3. the checkpoint is written to disk,
4. the process still matches the child we started - **PID and start time**.

A clean shutdown is attempted first. A console child sharing our console has no
window to close and cannot be sent Ctrl+C without hitting the supervisor too, so
in practice the clean attempt times out and termination follows - which is
acceptable precisely because the four conditions above are already satisfied.

An unrelated `agy.exe` started by the user in another terminal fails the
identity check and is never touched.

## The switch transaction

```
acquire lock (named mutex, per user, Global with Local fallback)
    |
    v  snapshot the live credential          <- for rollback
    v  refresh the outgoing profile's copy   <- agy may have rotated its token
    v  write the incoming profile
    v  read it back and compare SHA-256
    v  commit metadata
    |
release lock
```

Any failure restores the snapshot. The failure is logged, redacted, and the
supervisor refuses to start a session with an uncertain credential.

The refresh step is not optional. Between the moment a profile is saved and the
moment it is abandoned, agy will have refreshed its token; without the refresh
the stored copy goes stale and that account eventually stops working.

## Verified profile selection

`agy -p "/quota" --output-format json` answers with `remaining_fraction` and an
absolute `reset_time` per bucket, with `conversation_id` empty and every token
counter at zero - it costs nothing.

So after writing profile B's credential the supervisor asks agy whether B
actually has headroom. If not, B is parked with its real reset time and the next
candidate is tried. Rotation is verified rather than hopeful, and
`exhaustedUntil` comes from ground truth rather than from parsing a countdown
string. The string parser survives only as the hook's fast-path fallback.

When no candidate remains, the supervisor prints which accounts are exhausted
and when the first one returns, then exits with code 75. It does not loop and it
does not hang.

## Continuity

A `conversationId` is bound to the account that created it, so the supervisor
cannot assume account B can open account A's conversation. It tries, and treats
a fast non-zero exit as a rejection.

On rejection it writes a handoff carrying the conversation id, the transcript
path **exactly as the hook reported it** (never reconstructed), the artifact
directory, the model, the working directory, the reset time, and a git snapshot:
branch, HEAD, `status --porcelain`, `diff --stat`, recent commits.

The replacement session starts with a prompt whose central instruction is that
**git and the filesystem are the source of truth for what actually ran**, and
the transcript is evidence of intent only. A transcript can describe a command
that failed after being reported as successful; a commit cannot.

## What is deliberately not done

- No parsing of the credential blob, no OAuth calls, no network calls at all.
- No swapping of anything under `~\.gemini\antigravity-cli\`. Conversations,
  brain, knowledge, skills and settings stay shared. `cache/default_project_id.txt`
  holds a local project name in 1.1.27 and is **not** account-bound.
- No modification of `agy.exe`, and no automatic updates or `git pull`.
- No proactive rotation before quota is actually hit. `/quota` makes it possible,
  but reacting to the real error keeps the behaviour predictable and adds no
  per-turn cost.
