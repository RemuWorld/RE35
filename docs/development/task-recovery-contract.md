# VS Code original-task recovery

Audience: maintainers. This describes the live host contract. User instructions
are in the [host guide](../../hosts/vscode/README.md). See
[compatibility](../compatibility.md) for host support and limitations.

## Data and authority

`follow_up_proposal {task_id,action,readiness,reason?,original?}` validates the
existing pure Follow-up v1 data through the lazily loaded bridge. Five actions
are `details`, `results`, `recover`, `retry` and `review`. It creates no operation,
claims no resource and carries no execution permission. Protocol 1, Document
v1/v2 and C ABI 1 are unchanged. The native source manifest lists the portable
core modules loaded by the helper.

`task-recovery.js` owns private proposal and selection WeakMaps. A menu binds
the live host/backend, exact retained Task, applied profile object,
context generation and local execution revision. Opening another menu retires
the previous menu. Selection and dispatch each recheck their owner; both consume
exact objects once, including refused actions. JSON copies and another host
cannot adopt authority. Task eviction, profile/context replacement, local
execution changes, helper loss and disposal retire old receipts.

Details and Results are read-only navigation. Results' independent location
owner still rechecks source/editor revisions and physical containment on each
jump. Remedy routing requires an originally captured navigable diagnostic from the actual failed
step before suggesting Results. A warning from an earlier successful step is
not a remedy for an unrelated later failure. Otherwise the declared failed step
and tool lead to local Settings with `unknown` cause. No output substring or
exit code infers missing tools, dependencies or configuration.

The shared proposal text bounds are tighter than portable choice bounds. Values
that do not fit are omitted only from optional proposal display fields. The
exact original choices remain private and appear in Task provenance and the
host's original-choice review. Execution arguments are never shortened.

## Original execution

`task-service.js` retains one private original selection/profile/backend/context
and resolved plan per Task, with the existing four-Task output bound. It does
not retain another document text snapshot. `prepareOriginal(taskId, mode)` uses
the retained project/recipe/configuration/target, not the current selection.
It requires recorded original completion, the same profile/core owner and the
same physical root/source identity. Source text repairs can become fresh inputs;
replacing the physical project/source requires new selection.

Strict `retry` resolves current tools and cwd, then compares argv, step identity,
parser, timeout, cancellation grace and configured process-helper path to the
original admitted semantics. A change refuses retry and offers `review`, which
retains the original logical choices but exposes the current exact plan and a
change notice. Neither action launches until the caller explicitly starts its
one-use admission. The normal Run command continues to use current selection.

Each fresh admission captures current saved file stamps and exact live editor
owners/versions. Relevant dirty documents use the shared Save selected / Run
saved / Cancel boundary. A repaired editor is not implicitly saved. A change
after preparation consumes/refuses admission without launching. Successful
execution records `originTaskId` and `recoveryMode` in its own provenance.

Once admitted, the new Task owns its pinned authority and may finish even if its
parent is evicted by the four-Task retention limit. Retention is checked before
admission; profile/core/context/local settings and inputs remain checked before
every child. No recovery route automatically installs, edits, saves or reruns.

## Settings and native return

Changing only `toolOverrides` or `processHelper` replaces copied host options,
advances the execution revision, invalidates pending admissions/menus and
requests cancellation of active work. It preserves the profile, local project
selection and retained Tasks. Resetting an unset override uses `{}` / `false`;
caller-owned option objects are not mutated. Backend/core, root mappings, base
paths or project-search changes still dispose the host and its reviews.

The native recovery controls return to the same Task ID. Opening local Settings
uses a nonmodal Return notification, allowing a repair before returning. The
original-choice review displays literal argv/cwd and execution limits; Run is
explicit, Return discards its admission. A single view loop handles Task,
Results, Recovery and Return routes without retaining nested menus. A rejected
stale source jump shows its reason and preserves return to the same Task; owner
loss refuses further navigation. Native task/retry controls share
`task-ui.js`; Results controls use injected callbacks rather than cyclic module
imports. Closing a view does not change process ownership.

Actual Windows Extension Host and Linux filesystem/process checks are distinct
from physical QuickPick gestures, Linux desktop rendering and user acceptance.
The latter gates remain unjudged.
