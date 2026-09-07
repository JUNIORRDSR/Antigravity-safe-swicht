---
name: agy-quota-recovery
description: >-
  Use this skill when a session begins with a handoff message saying the
  previous account hit its quota, when a handoff file under
  agy-auto-switch\handoffs is referenced, or when work must resume after an
  account switch without repeating operations that already completed.
---

# Resuming after a quota switch

You are continuing work that another session started under a different account.
That session is gone and you cannot read its conversation. Your job is to
rebuild the real state, then carry on.

## The one rule that matters

**The filesystem and git are the source of truth for what actually happened.
The transcript is evidence of intent only.**

A transcript can show a plan that was never executed, a command that failed
after being described as successful, or an edit that was later reverted. Never
take "the previous session said it did X" as proof that X happened.

## Recovery protocol

### 1. Read the handoff

The prompt names a file under `%LOCALAPPDATA%\agy-auto-switch\handoffs\`. Read
it first. It carries the previous conversation id, the transcript path, the
model, the working directory, and a git snapshot taken at the moment of
interruption.

### 2. Compare the repository against that snapshot

```
git status
git diff
git log --oneline -10
```

Diff what you see now against the `porcelain` output and `HEAD` recorded in the
handoff. They should match. If they do not, something changed after the
snapshot and you must account for it before writing anything.

### 3. Read the transcript for intent

Open the `transcriptPath` from the handoff. Read it to answer: what was the
goal, what decisions were made, what was the previous session about to do next.
Do not read it to decide what is already done.

If the transcript is unreadable, say so and continue from git alone. That is a
degraded but valid recovery.

### 4. Classify the work

Build two lists before touching anything:

- **Done** - proven by a file on disk, a commit, or a command's persistent
  effect you can observe right now.
- **Pending** - described in the transcript but with no observable trace.

### 5. Verify before repeating anything with side effects

For every pending item that writes, migrates, deploys, installs, or calls a
network API, check first whether it already ran. Cheap checks: does the
migration appear in the schema table, does the file already exist with the
expected content, is the package already in the lockfile, is the branch already
pushed.

Re-running a pure computation is harmless. Re-running a side effect can be
destructive or expensive. Treat those differently.

### 6. Resume and report

Continue from the last consistent point, then tell the user in two or three
lines: where you resumed, what you confirmed was already done, and what you
skipped because it had already happened.

## What not to do

- Do not restart the task from scratch "to be safe" - that is how duplicate
  commits, doubled migrations and repeated deployments happen.
- Do not summarise the transcript back to the user instead of inspecting the
  workspace.
- Do not touch credentials or profiles. The switch already happened and the
  account now in use is the correct one.
