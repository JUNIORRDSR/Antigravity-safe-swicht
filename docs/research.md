# Research — agy-auto-switch

Empirical findings from **this** machine. Everything below was executed and
observed, not taken from documentation alone. Where the original assumptions
were wrong, the evidence wins.

- Date: 2026-09-06
- Host: Windows 11 Pro 10.0.26200
- Windows PowerShell: 5.1.26100.9168
- Antigravity CLI: **1.1.27**

--------------------------------------------------------------------------------

## 1. Antigravity CLI

| Item | Value |
| :--- | :--- |
| `agy --version` | `1.1.27` |
| Real executable | `C:\Users\Jorge\AppData\Local\agy\bin\agy.exe` (189 MB, single Go binary) |
| `Get-Command agy -All` | exactly one hit, the `.exe` above — no `.cmd`/`.ps1` shim exists today |
| User PATH position | `%LOCALAPPDATA%\agy\bin` is entry **#2** of the user PATH |

### Flags that exist in 1.1.27 (verified against `agy --help`)

`--add-dir`, `--agent`, `-c`, `--continue`, `--conversation`,
`--dangerously-skip-permissions`, `--disable-slash-commands`, `--effort`, `-i`,
`--input-format`, `--json-schema`, `--log-file`, `--mode`, `--model`,
`--new-project`, `--output-format`, `-p`, `--print`, `--print-timeout`,
`--project`, `--prompt`, `--prompt-interactive`, `--sandbox`.

Subcommands: `agent(s)`, `changelog`, `help`, `install`, `mcp`, `mic-serve`,
`models`, `plugin(s)`, `remote-control`, `update`.

- `--dangerously-skip-permissions` **exists** → the auto-autonomy requirement is
  supported.
- `--safe` does **not** exist → safe to claim as a wrapper-private flag, no
  collision.
- `agy install` is described as "Configure environment paths and shell settings"
  and carries `--skip-aliases`, *"Bypasses shell profile alias purging"*.
  **`agy install` actively purges shell aliases.** That kills any `Set-Alias`
  based approach and confirms the `.cmd` shim design. It *appends* to PATH, so a
  prepended shim directory keeps precedence — but `doctor` must verify it.

--------------------------------------------------------------------------------

## 2. Customization system (authoritative for 1.1.27)

The CLI ships its own documentation as a built-in skill at
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/{hooks,plugins,skills,json_configs}.md`.
That is the contract this project targets.

### Plugin location — **corrected assumption**

Plugins live under a *customization root*, **not** under `antigravity-cli/`:

```
~/.gemini/config/plugins/<name>/
    plugin.json        # required marker
    hooks.json         # optional, plugin root — NOT hooks/hooks.json
    mcp_config.json    # optional
    rules/AGENTS.md    # optional
    skills/<name>/SKILL.md
```

Verified: `~/.gemini/config/plugins/ponytail/` is where `plugin install` staged
an already-installed plugin.

### `plugin.json` schema — **corrected assumption**

```json
{ "name": "agy-auto-switch" }
```

`name` is the **only** field (optional; defaults to the directory name), plus
`"disabled": true` to ship switched off. There is **no `$schema` field and no
`description` field** in this version — that shape belongs to Claude Code's
plugin format. Adding them is inert at best.

Enablement is recorded in `~/.gemini/config/config.json` under a `plugins` map
keyed by **directory** name, written by `agy plugin enable|disable`.

### `agy plugin validate` reports a broken `hooks.json` as "not found"

```
$ agy plugin validate <plugin with a malformed hooks.json>
      - hooks : skipped (not found)

$ agy plugin validate <same plugin, JSON fixed>
      - hooks : 1 processed
```

The file was present in both runs. A JSON parse failure is reported with the
same wording as a missing file, which makes `validate` alone a poor signal.
`cli.log` names the real cause:

```
hooks.go:87] Failed to parse hooks for plugin <name>: failed to parse hooks.json:
             invalid escape sequence `\s` in string
```

Treat `hooks: skipped (not found)` as "check whether the JSON parses" and
confirm against `cli.log`.

### `agy plugin install .` — verified behaviour

```
$ agy plugin install .
  [ok]  agy-auto-switch
      - skills     : skipped (not found)
      - agents     : skipped (not found)
      - commands   : skipped (not found)
      - mcpServers : skipped (not found)
      hooks        : 1 processed
```

- It **copies** the source tree to `~/.gemini/config/plugins/<name>/` -
  everything, `.git` included. The installed plugin is a snapshot, so editing
  the repo does not change the running plugin until it is reinstalled.
- It appends an entry to `~/.gemini/config/import_manifest.json` with
  `"components": ["hooks"]`.
- It does **not** modify `~/.gemini/config/config.json`.

Because the installed copy is what actually runs, the hook resolves its own
scripts relative to the installed directory, and the shims must point there too.

--------------------------------------------------------------------------------

## 3. Stop hook on Windows — **WORKS** (probe passed)

A minimal probe plugin was installed and real `agy` turns were executed.

### Evidence chain from `~/.gemini/antigravity-cli/cli.log`

```
hooks_manager.go:53]  loaded 0 named hooks from 0 hooks.json file(s)   <- global roots
hooks.go:87]          Failed to parse hooks for plugin agy-probe: ...  <- plugin hooks ARE read
command_hook_executor.go:75] JSON hook command stderr: ...             <- plugin hooks ARE executed
stophooks.go:62]      failed to call custom stop hook jsonhook__agy-probe-stop_Stop_0_0
```

The two failures above were **my own bugs** (a JSON escape, then a PowerShell
5.1 syntax error), not CLI defects. Once fixed, the hook ran and wrote its
payload. Hook handler id format: `jsonhook__<hookName>_<Event>_<i>_<j>`.

A third self-inflicted trap worth recording: PowerShell 5.1 reads `.ps1` files
as the system ANSI codepage unless they carry a UTF-8 BOM. A UTF-8 em dash in a
comment was enough to produce a parser error. **Every `.ps1` in this project is
ASCII-only** so encoding can never break the hook.

### Real `Stop` payload captured (sanitized dump; 447 bytes on stdin)

```json
{
  "artifactDirectoryPath": "C:/Users/Jorge/.gemini/antigravity-cli/brain/<conversationId>",
  "conversationId": "2fa2595e-ef8b-4a54-801d-b17299926734",
  "error": "",
  "executionNum": 0,
  "fullyIdle": true,
  "modelName": "gemini-3.8-flash-high",
  "terminationReason": "NO_TOOL_CALL",
  "transcriptPath": "C:/Users/Jorge/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript_full.jsonl",
  "workspacePaths": {}
}
```

### Hook execution environment (measured, not assumed)

| Fact | Value | Consequence |
| :--- | :--- | :--- |
| Shell | `cmd /c` (`ComSpec=C:\WINDOWS\system32\cmd.exe`) | command must be cmd-safe |
| Working directory | the **plugin directory** | relative script paths work |
| Path separators in `command` | use `/`; a `\` yields `invalid escape sequence` | `scripts/stop-hook.ps1` |
| Env vars | **inherited from the `agy` process** | see below |
| `ANTIGRAVITY_CONVERSATION_ID` | set by agy | conversation id for free |
| Timeout | default 30 s, configurable | keep the hook far below it |

### Supervisor → hook channel — **verified**

The supervisor sets env vars before spawning the child; the hook receives them:

```
envAgyKeys: AGY_AUTO_SESSION, AGY_AUTO_SUPERVISOR_PID, ANTIGRAVITY_CONVERSATION_ID
```

This is how the hook knows *which* supervised session it belongs to — no PID
heuristics, no guessing. **`workspacePaths` came back empty `{}` in print
mode**, so the workspace cannot be read from the payload; the supervisor must
supply its own CWD through this same channel.

### `terminationReason` — full enum (extracted from the binary)

```
UNSPECIFIED  NO_TOOL_CALL  ERROR  HALTED_STEP  USER_CANCELED
MAX_INVOCATIONS  MAX_FORCED_INVOCATIONS  MAX_TOKEN_BUDGET_EXCEEDED
EARLY_CONTINUE  INJECTED_RESPONSE  TERMINAL_STEP_TYPE  TERMINAL_CUSTOM_HOOK
```

The hook receives the value with the `TERMINATION_REASON_` prefix stripped.
The docs claim `"model_stop"`; the real value is `"NO_TOOL_CALL"` — **the
documentation is stale, the wire format is what counts.** Quota exhaustion
arrives as `ERROR` with the `error` field populated, so the classifier keys on
the `error` text and treats `terminationReason` as a coarse gate.

--------------------------------------------------------------------------------

## 4. `/quota` in print mode — the most important finding

The 1.1.27 changelog embedded in the binary states that read-only slash commands
answer in print mode *"without starting an agent turn, spending quota, or
leaving a conversation behind."* Verified:

```
$ agy -p "/quota" --output-format json
{"conversation_id":"","status":"SUCCESS",
 "usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},
 "command":{"name":"usage","data":{"groups":[
   {"name":"Gemini Models","buckets":[
     {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.370,"reset_time":"2026-09-10T23:59:45Z"},
     {"id":"gemini-5h",    "window":"5h",    "remaining_fraction":0.989,"reset_time":"2026-09-07T03:36:17Z"}]},
   {"name":"Claude and GPT models","buckets":[
     {"id":"3p-weekly","window":"weekly","remaining_fraction":0.116,"reset_time":"2026-09-08T20:30:17Z"},
     {"id":"3p-5h",    "window":"5h",    "remaining_fraction":1,    "reset_time":"2026-09-07T03:44:01Z"}]}]}}}
```

`conversation_id` empty, every token counter zero. Confirmed free.

**This changes the design in four ways:**

1. `resetAt` no longer has to be scraped from `"Resets in 1h4m13s"` — an
   authoritative absolute `reset_time` is available per bucket. String parsing
   stays only as the hook's fast-path fallback.
2. Profile selection becomes **verified instead of blind**: after writing
   profile B's credential, query `/quota` and confirm B actually has headroom
   *before* starting a session. No more rotating into an equally-exhausted
   account.
3. `exhaustedUntil` can be refreshed and expired from ground truth instead of a
   trusted-but-stale local timestamp.
4. `doctor` can show live per-profile quota.

Related literals in the binary: `You have exhausted your quota on this model.`,
`this account is used up; it resets in %s`, `Quota exhausted`, `Quota available`.
The user-facing `"Individual quota reached. Please upgrade your subscription…"`
string is **not** in the binary — it is server-supplied, which is precisely why
the classifier must be tolerant rather than matching one literal.

--------------------------------------------------------------------------------

## 5. Credential storage — verified via P/Invoke

`cmdkey /list` shows `LegacyGeneric:target=gemini:antigravity`, type Generic.

`CredReadW` on `gemini:antigravity`, `CRED_TYPE_GENERIC` (1):

| Field | Value |
| :--- | :--- |
| `CredentialBlobSize` | 503 bytes |
| `Persist` | 2 (`CRED_PERSIST_LOCAL_MACHINE`) |
| `UserName` | `antigravity` |
| `AttributeCount` | 0 |
| SHA-256 (first 8 bytes) | `<fp-A1>` (redacted: a real fingerprint of a live credential) |
| `LastWritten` | 2026-09-06T22:35:21Z |

Contents were never read, decoded, logged, or printed — only length, persist
class, username and a truncated hash.

### Round-trip test on a throwaway target `agy-auto-switch:selftest`

```
write/read roundtrip : PASS   (503-byte random blob, byte-identical back)
size preserved       : 503 -> 503
persist preserved    : 2
username preserved   : antigravity
overwrite detected   : PASS   (hash changes on rewrite)
delete + gone        : PASS
real target intact   : 503 bytes fp=<fp-A1>  (untouched)
```

`CredRead` / `CredWrite` / `CredDelete` / `CredFree` all behave. Storing profiles
as sibling Credential Manager targets is viable — **no DPAPI file fallback is
needed.**

### Credential drift is real

`LastWritten` moved during the session while `agy` was running. This confirms
requirement **G**: profile A's stored snapshot must be refreshed from the live
credential immediately before abandoning A, or the saved copy goes stale.

--------------------------------------------------------------------------------

## 6. Local state — what is actually account-bound

`~/.gemini/antigravity-cli/`:

```
annotations/  bin/  brain/  builtin/  cache/  conversations/  crashes/
implicit/  knowledge/  log/  mcp/  presence/  updater/
cli.log  conversation_summaries.db  history.jsonl  installation_id
jetski_state.pbtxt  mcp_config.json  settings.json
```

**`cache/default_project_id.txt` contains `default-cli-project`** — a *local
project name*, matching `~/.gemini/config/projects/default-cli-project.json`.
The historical assumption that this file is account-bound **no longer holds in
1.1.27.** It must **not** be swapped per profile.

Nothing in this tree needs to be swapped per profile. Conversations, brain,
knowledge, skills and settings stay shared; only the Credential Manager entry is
account-bound. `cache/last_conversations.json` maps workspace → conversation id
and is useful *read-only* for continuity.

Transcripts live at
`brain/<conversationId>/.system_generated/logs/transcript_full.jsonl` — but the
hook hands this path over directly, so it is never reconstructed.

--------------------------------------------------------------------------------

## 7. Autonomy settings — real schema

Current `~/.gemini/antigravity-cli/settings.json`:

```json
{
  "colorScheme": "tokyo night",
  "dangerouslySkipPermissions": true,
  "enableTerminalSandbox": true,
  "model": "Gemini 3.8 Flash (High)",
  "statusLine": { "type": "", "command": "", "enabled": true },
  "toolPermission": "proceed-in-sandbox",
  "trustedWorkspaces": ["C:\\Users\\Jorge", "C:\\Workspace\\cuadra-mobile"]
}
```

Enum values extracted from the binary:

| Key | Accepted values |
| :--- | :--- |
| `toolPermission` | `always-proceed`, `agent-decides`, `asks-for-review`, `proceed-in-sandbox` |
| `artifactReviewPolicy` | `always-proceed`, `request-review`, `strict` |
| `agentMode` | `default`, `accept-edits`, `plan` |

The real key is **`artifactReviewPolicy`**, not `artifactReview`. The machine
already runs `dangerouslySkipPermissions: true` with `proceed-in-sandbox`, so
setup must merge, never overwrite, preserving `trustedWorkspaces` and every
unknown key.

--------------------------------------------------------------------------------

## 8. Consequences for the architecture

1. The plugin ships to `~/.gemini/config/plugins/agy-auto-switch/`, with
   `plugin.json` carrying only `name`, `hooks.json` at the plugin root, and hook
   commands using forward slashes.
2. The Stop hook is viable as the fast-path detector — no fallback architecture
   is needed, though `/quota` gives an independent second opinion.
3. Supervisor ↔ hook correlation rides on inherited env vars, so the supervisor
   only ever manages the child it spawned.
4. `/quota --output-format json` is ground truth for `exhaustedUntil` and for
   verifying a candidate profile before committing to it.
5. Credential Manager holds both the live credential and the profile copies; no
   plaintext, no DPAPI files.
6. No per-profile swapping of anything under `~/.gemini/antigravity-cli/`.
7. `.cmd` shims in a PATH directory ordered ahead of `%LOCALAPPDATA%\agy\bin`;
   aliases are unusable because `agy install` purges them.

--------------------------------------------------------------------------------

## 9. Post-implementation verification on this machine

Run after the finished tool was installed, against the real CLI and the real
credential.

```
agy-auto doctor --probe

Command routing
  agy       ...\agy-auto-switch\bin\agy.cmd     -> AGY Auto Supervisor
  agy-auto  ...\agy-auto-switch\bin\agy-auto.cmd -> AGY Auto Supervisor
  agy-raw   ...\agy-auto-switch\bin\agy-raw.cmd  -> ...\agy\bin\agy.exe
  PATH precedence                    supervisor first
  agy-raw target                     real agy

Plugin
  hooks.json                         present, valid JSON
  Stop probe                         PASS - the hook ran and classified the stop

Result:
  READY
```

- `where agy` returns the shim first and the official executable second; the
  official one is untouched and still reachable as `agy-raw`.
- A supervised turn (`agy -p "Reply with exactly: SUPERVISED-OK"`) produced the
  expected answer, with the prompt surviving quoting intact through
  cmd -> `AGY_AUTO_RAWARGS` -> `CommandLineToArgvW` -> `ProcessStartInfo`.
- **Credential drift was observed live.** After a handful of turns, the doctor
  reported a live fingerprint of `<fp-A2>` against a stored profile
  fingerprint of `<fp-A1>`, and correctly classified the active profile as
  `matched by state-drifted`. agy had refreshed its own credential mid-session,
  exactly as requirement G anticipated. Without the refresh-before-abandon step
  the saved copy of that account would already be stale.

### A trap worth recording: `plugin install` copies, it does not link

`agy plugin install .` snapshots the source tree into
`~/.gemini/config/plugins/agy-auto-switch/`. Editing the repository does not
change the running plugin, so `setup.ps1` must be re-run after any change to the
hook or the scripts. The shims therefore point at the *installed* copy, keeping
one consistent tree at runtime.

### Test suite

129 checks pass, covering acceptance scenarios A through N, with the credential
store substituted in memory and `LOCALAPPDATA` redirected to a throwaway
directory. Six of them drive the entire supervisor loop end to end against a
stand-in agy - real Stop hook, real classifier, real switch transaction, real
handoff - including the all-accounts-exhausted case, which exits 75 rather than
looping.
