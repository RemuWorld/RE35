# Follow-up proposals v1

`command_environment.core.follow_up.proposal` produces data only. It requires no
editor globals, process services or filesystem. Hosts own navigation and dispatch.

Each proposal has `schema = 1`, a positive integral `task_id`, stable `id`, label,
destination and readiness (`ready`, `unavailable`, `unknown`). Non-ready states
require a reason. IDs are `details`, `results`, `retry`, `recover`, `review`.
Optional original choices contain only project, recipe, configuration and target;
they contain no paths, callbacks or process handles. Reasons are at most 1024
bytes and logical choices at most 256 bytes; control characters are rejected.
Proposal construction copies choices rather than retaining caller tables.

In Neovim, `command_tree.project.follow_up` is an internal host adapter. All
ephemeral receipts bind the original proposal object, exact retained Task and
command ID, and source buffer/window/name. Copies, mutated proposals, reused Task
IDs, changed source identity and already consumed receipts cannot dispatch.

Details and Results are inspection. Their receipts permit Task progress, source
edits and environment replacement when the exact Task remains retained in the
current environment. They do not depend on the currently registered command or
grant execution permission. Results checks each location separately before a jump.

Retry, remedy and original-choice review additionally bind the issuing
environment, Task status, registered command, original arguments, process target
and execution revisions. Changes require fresh proposals. Dispatch refreshes
readiness; existing replay and recipe recovery checks remain the final authority
for definitions, physical paths, original arguments, save choices and execution.

Readiness describes admission to the next action, not guaranteed execution or
diagnosis. A ready remedy can open inspection without establishing the cause of
failure. No dependency is inferred from output text. Deep replay validation can
still refuse a ready retry when source or project state changes.

Project and Tasks use this adapter. Results uses it to open its owning Task;
returning to an existing matching parent frame retains the bounded stack path.
Opening details, Results, Settings or original-choice review does not run or save.
Profiles do not persist proposals or receipts. VS Code has its own host adapter;
neither adapter is a public transport authorization contract.

The Neovim `require('re35').task_followups(task_id)` API issues five proposals
in details/results/retry/recover/review order, including unavailable actions and
their reasons. `run_task_followup(proposal)` dispatches the original live object
in the current environment and source context. Serialized or deep-copied data
is display information only and cannot dispatch. A details action needs an
active command workspace. These APIs do not bypass normal lifecycle admission.
Retained arguments and process revisions belong to the stricter retry, remedy
and original-choice review receipts; inspection alone does not require execution
consent.

The VS Code `WorkflowHost.recoveryService()` issues the same display proposals
through the lazy `follow_up_proposal` bridge operation. Its private live receipts
bind the retained Task, backend, profile/context and local execution revision.
`actions -> select -> dispatch` consumes exact objects; copied data cannot
navigate or prepare execution. The host accepts `unknown` only for remedy
inspection, without claiming a diagnosis. Exact portable choices that exceed
proposal text bounds stay private and visible in native execution review;
incompatible display-only fields are omitted rather than truncating arguments.
See the [VS Code recovery contract](development/task-recovery-contract.md).
