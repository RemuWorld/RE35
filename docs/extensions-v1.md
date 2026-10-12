# Neovim extension API 1

Extensions are explicit setup entries: `extensions = { require('command_tree.extensions.git').new() }`. The default does not load Git or install a tool. Existing `register`, `register_workspace`, adapters and profile schema 1 remain supported.

A specification has `api_version=1`, a unique `id` and `build(api)`. Build declares commands, Workspaces and cleanup callbacks; it must not start external work. Commands use the central executor's existing original-context, completion and cancellation contract. Extensions cannot replace existing IDs. Unsupported versions or invalid registration leave the active setup intact and clean up the failed candidate once.

`api.register_command(spec)` and `api.register_workspace(spec)` declare owned IDs. A Workspace supplies `initial_state`, `render(req)`, optional enter/resume/suspend/leave hooks, actions and key bindings. `render` returns ordinary View model data. Actions return `{state=patch, message=text, execute={id,args}}` as needed. Runtime Frame, Session and view handles stay private.

Requests contain copied `state`, copied original `context`, `owner_id` and `revision`. `api.execute(id,args,req,done)` permits only the extension's owned command IDs and executes against the host's privately retained original context. `api.publish(req,patch)` rejects a closed, covered, replaced or newer owner. A successful publication advances its own request revision; another user action invalidates older callbacks. `api.refresh(req)` redraws only that matching active Workspace. Completion is still recorded in Tasks when a late UI update is rejected.

`api.project_root(ctx)` uses the selected declarative Project root or the current-document project boundary. `api.on_dispose(cleanup)` runs once on setup replacement, disable or failed preparation. Closing the UI does not dispose the extension or imply cancellation. Cleanup failures are contained; external resource owners must report actual completion through the executor.

State is copied bounded data: no function, userdata, thread, cycle or arbitrary metatable. State is limited to 2 MiB, rows to 5000 and diff to 1 MiB. Remembered state uses the existing Workspace primitive-field whitelist; rows, diff and backend resources are not persisted. `register_extension`, `unregister_extension` and `extensions()` provide validated runtime registration/removal/status. Portable layout references survive missing optional extensions.

The optional Git Workspace supplies status, read-only diff and reviewed whole-file stage/unstage. It uses argv, literal pathspecs and a clean Git environment. It revalidates source context, canonical root, file state, HEAD and index before a write, and rereads actual status after a failed/cancelled write. Conflicts, submodules, rename records and configured clean filters are explicitly unavailable for file actions. It never edits the worktree and does not promise rollback after Git has changed the index.
