# Optional owned process cancellation

Project tools and recipe steps can use an explicitly configured native process
owner. Neovim and the optional VS Code host reuse this backend, separate from
the portable Lua core and the C bridge. Neovim's normal installation still
needs no helper executable; the VS Code C bridge is separate from this optional
process owner.

## Choose the scope

With `process_helper = false` (the default), RE35 uses `vim.system` directly.
Completion confirms the directly launched process has exited. Descendant
termination remains **unknown**, including when a task is cancelled or its
timeout expires. Parent exit is not evidence that a compiler or build child
has stopped.

To choose ownership, build the optional target using an existing C toolchain:

```sh
cmake -S . -B .artifacts/process-scope-build
cmake --build .artifacts/process-scope-build --target ce_process_scope
```

Then set an absolute local path in the Neovim host configuration:

```lua
require("re35").setup({
  process_helper = "/absolute/path/to/ce_process_scope",
  tool_overrides = {
    build = { cancel_grace_ms = 2000 },
  },
})
```

On Windows, use the built `ce_process_scope.exe` path. Tool overrides and the
helper path are local machine configuration; neither belongs in an exported
portable profile. RE35 does not build, download, install, or discover a helper
automatically. A configured missing helper makes tools unavailable. An invalid
helper protocol fails the task; neither case silently downgrades to direct
execution. Changing the helper path changes the process declaration revision.

In VS Code, use the machine setting `re35.processHelper` instead. Its empty
default selects direct execution; local `re35.toolOverrides` supplies
`timeout_ms` and `cancel_grace_ms`. See the [host guide](../../hosts/vscode/README.md).

## Windows Job ownership

The helper creates a private Job with `KILL_ON_JOB_CLOSE` and uses
`PROC_THREAD_ATTRIBUTE_JOB_LIST` to create the tool **atomically inside that
Job**, suspended, before resuming it. There is no created-but-unassigned interval
if the helper dies. This optional backend requires Windows 10 or Server 2016
and newer; unsupported attributes fail before the tool starts. Descendants inherit
the Job; breakaway is not enabled. Tool stdin is closed, and only its three
explicit standard handles are inherited.

Cancellation stops the Job immediately; it does not promise POSIX-style graceful
signals on Windows. Normal parent exit also stops remaining Job members before
reporting completion. Confirmation requires both original-parent exit and the
Job's observed active process count reaching zero. Helper death closes its Job
handle and triggers OS cleanup, but RE35 reports **unconfirmed** if no valid
completion receipt arrives.

## Linux session group ownership

The supervisor creates a session-group anchor before the tool can execute. The
tool and ordinary descendants remain in that group. Cancellation sends TERM,
waits the configured grace period, then sends KILL if members remain. Automatic
hard escalation is recorded in the result; no second user confirmation is needed
to finish a timed-out owned build. Normal parent exit also cleans remaining
group members.

The anchor remains unreaped until all signalling is finished, pinning its PID
and group ID even if it is unexpectedly killed. No group signal is sent after
that PID is released. A parent-death signal lets the live anchor stop its own
group if the supervisor disappears. The supervisor uses Linux subreaper support
and `/proc` to distinguish live members from zombies; a failed or bounded-out
observation reports **unconfirmed**. Each scan is limited to 65,536 directory
entries and 250 ms; final termination observation has a 2-second deadline.
The census requires unrestricted `/proc` visibility in the helper's own PID
namespace, checked before launch and before every membership scan. Restricted
`hidepid`, inconsistent namespace coordinates, unreadable nontransient proc
entries, or malformed stat data never count as an empty group. Every matching
stacked `/proc` mount must meet the visibility requirement. If nonblocking
control setup fails after launch, the pinned group is stopped before any PID
is reaped, and failure is reported separately from observed cleanup.

An intentional `setsid`/group escape is outside the promise. Adopted detached
children that are still visible are counted, without signalling them. The
number is an observation, not a complete system-wide daemon inventory. Detached
processes do not hold the command UI open through inherited output pipes: the
helper owns and closes the tool-output forwarding pipes after scoped cleanup.
External services and already detached cache servers are also outside the
scope. Windows does not inventory such services and reports their count as
unknown. RE35 is not a process sandbox.

## Result evidence

The task retains the original tool argv and cwd. The helper's private control
stdin and bounded temporary status file are transport details, not command
arguments to replay or export. Captured tool output retains the existing 1 MiB
bound. Results include:

| Field | Meaning |
| --- | --- |
| `process_scope` | `direct`, `windows_job`, or `linux_group` |
| `termination_confirmed` | Direct process exit or observed owned-scope termination, according to scope |
| `descendant_termination` | `unknown`, `confirmed` within the owned scope, or `unconfirmed` |
| `detached_observed` | Observed Linux adopted detached children, or `-1` for unknown |
| `detached_exclusion` | Explicit explanation that detached daemons/services are excluded |
| `cancelled`, `forced` | Cancellation and user/automatic hard escalation |
| `exit_code`, `signal` | Original tool outcome when observed; see the forced Linux exception below. Missing receipt becomes a failed/unconfirmed result |

Forced Linux cancellation can kill the session anchor before it forwards the
root process's exit frame. A version-1 receipt with `cancelled`, `forced`,
confirmed termination, no error and code 125/signal 0 then means the original
root exit is unavailable. Group termination can still be confirmed; code 125
is not a separately observed tool failure. VS Code exposes `exitCode: null`
and `exitCodeUnavailable: true` while retaining the raw receipt. Neovim currently
retains raw `exit_code: 125` in its cancelled result. Unsolicited anchor loss
remains an error. Result presentation normalization is follow-up work, not a
change to the native receipt contract.

For the VS Code scoped adapter, `started` records native launcher spawn, not a
separate tool-start acknowledgement; its timeout begins at that boundary.
Cancellation before launcher spawn can finish with confirmed quiescent no-child
evidence. After launcher spawn, confirmation requires actual helper close and
a valid confirmed receipt.

## Explicit integration probe

Use the existing Python and a helper already built for the current platform:

```sh
python tests/acceptance/run_process_scope.py \
  --helper /absolute/path/to/ce_process_scope \
  --report .artifacts/usage/process-scope.json
```

The isolated probe launches real parents and descendants. It checks normal
parent exit cleanup, preserved failure exit, cancellation, timeout, helper
crash cleanup with no false confirmation, source files unchanged, and Linux
intentional detach reporting/explicit fixture cleanup. TERM-ignoring Linux
children verify actual hard escalation. A real two-step recipe is cancelled in
its first running step: the parent waits for scoped child evidence, preserves
scope/forced cleanup in its aggregate result, and never launches the next step.
Default fixtures separately check
direct-scope evidence and missing/broken-helper refusal. The integration probe
does not pretend that a missing executable is a successful skip and does not
install anything. Its report is controlled process evidence, not human usage,
performance, or arbitrary daemon termination evidence.

Additional exceptional-path probes require explicit test-only helper builds.
Normal CMake builds define neither macro, and production helpers expose no
runtime, environment, or argv fault switches:

- Windows: compile `native/process_scope.c` with `CE_PROCESS_TEST_LAUNCH_PAUSE`
  and pass `--launch-failure-helper /absolute/path/to/test-helper.exe`. The
  driver stops only its own supervisor between atomic creation and ResumeThread,
  holds the original child process handle, and verifies that the suspended Job
  member ends without executing the tool.
- Linux: compile with `CE_PROCESS_TEST_NONBLOCK_FAIL` and pass
  `--nonblocking-failure-helper /absolute/path/to/test-helper`. The bounded
  setup fault happens after a real parent and descendant start; the probe
  verifies safe group cleanup and a failed command outcome.

The driver fingerprints production and explicitly supplied fault binaries plus
all probe/native sources before and after the complete run. Typed contradictory
receipts are contract-tested separately; signal/exit values have platform
bounds, and nonempty errors or failed helper transport cannot report success.
