# Project recipes

Recipes join ordered tool invocations, their results and original-task retry.
Define a workflow once, then supply the executable paths and project roots on
each machine. This guide describes creating, running and retrying recipes in
Neovim. The portable declarations are also used by the optional VS Code host; its
[recipe controls](../hosts/vscode/README.md#run-a-recipe) use native command and
selection surfaces. Recipe IDs and declared choices use the same model; live
Tasks and Results stay with the host that created them. Not every Settings
screen or workspace binding is supported in both hosts.

Project recipes use optional schema-1 profile maps. Reading/importing the data never loads repository Lua or starts a program.

Open Settings / Projects to create a stable project ID, choose its logical root/source, edit configuration and target choices, and choose their defaults. Settings / Recipes creates a recipe from an existing project and tool profile. Each ordered step has a stable ID, name, tool, optional directory and individually editable arguments; an empty argument remains an exact empty argv element. `K`/`J` move a choice, step or argument and `d` removes an existing item. A project must retain a configuration and target choice, and a recipe must retain a step. Directory and argv inheritance can be restored explicitly.

All edits use the same Settings draft: review the before/after values, explicitly Apply, discard, or Undo an applied change. Creation, inspection, editing, Apply and Undo never start a tool. Deleting a project or recipe declaration retains its external ID references as unavailable. Export/import uses the same portable schema; JSON authoring is optional.

The bundled [CMake recipe profile](../examples/cpp-cmake-recipe.json) declares
tools and a recipe for an existing CMake project. CMake, CTest and the
compiler/generator must already be usable on the host. Change `app` to a target
declared by your `CMakeLists.txt`; CTest runs tests registered by that project.
The example has no machine path, source-file assumption or installation step.
Import it through Settings' profile preview, then select Project, root,
configuration, target and Recipe before choosing Run recipe. Local setup
`project_overrides = { cpp = { root = chosenLocalDirectory } }` can choose a
starting root without exporting that machine path.

`require('re35').run_recipe('cpp_build_test', { configuration = 'Debug', target = 'app' })` uses the same launch checks. Clean loaded project files start from saved inputs; modified files open the explicit save/run-saved choice. Pass `{ force_review = true }` as the third argument to request that choice even for clean inputs. The compatible `require('command_tree')` entry point is the same API object. Semantic `recipe.cpp_build_test` commands support ordinary argument forms and presets. The UI's Project selections apply to recipe steps; original `tool.*` and Build/run rows are labelled Current document and retain their original document behavior.

After selecting and running a recipe in Project, press `\rr` to run that window's
current project, configuration, target and recipe without reopening their forms.
Assign `project.run_selected_recipe` to a quick slot in Settings to use `\1`, for
example. A slot stores the command ID, not a frozen target. If the current choice
changes to Release/B, this command runs Release/B. To retry the original Debug/A
invocation, select its retained Task and choose Run again instead. A window with
no complete selection refuses to guess; open Project and choose Run first.

## Portable declarations

The following profile fields illustrate the same ordered recipe. Include the
`cmake` and `ctest` tool declarations from the bundled profile; this fragment
alone is not a complete setup call. The optional `source` pins a declared file;
omit it for a root-level recipe, as the bundled profile does.

```lua
projects = {
  cpp = {
    name = 'C++ application',
    root = { base = 'project', path = '.' },
    source = 'main.cpp',
    configurations = { 'Debug', 'Release' },
    targets = { 'app', 'tests' },
    default_configuration = 'Debug', default_target = 'app',
  },
},
recipes = {
  build_test = {
    name = 'Build and test', project = 'cpp',
    steps = {
      { id = 'configure', name = 'Configure', tool = 'cmake', args = { '-S', '{root}', '-B', '{root}/build', '-DCMAKE_BUILD_TYPE={configuration}' } },
      { id = 'build', name = 'Build', tool = 'cmake', args = { '--build', '{root}/build', '--target', '{target}', '--config', '{configuration}' } },
      { id = 'test', name = 'Test', tool = 'ctest', args = { '--test-dir', '{root}/build', '--output-on-failure', '-C', '{configuration}' } },
    },
  },
},
```

`tools` retains the existing portable PATH executable, argv, logical cwd and errorformat declarations. A step inherits that tool; its optional argv list and logical cwd replace the corresponding field atomically. Supported argv placeholders are `{file}`, `{root}`, `{configuration}` and `{target}`. They substitute individual argv strings directly, without a shell. Unknown placeholders, absolute machine paths and escaping logical directories reject. Source may be absent for a root-level tool.

`project_overrides.cpp.root` is host setup data, separate from the portable profile. Selecting another root in Project changes memory only; it cannot rewrite or export an absolute machine path. Project/configuration/target/recipe workspace state remembers selected logical IDs only. Recipe IDs and step IDs are stable; semantic ID collisions reject. Limits are 64 projects, 128 recipes, 16 finite steps per recipe and 64 choices per configuration/target.

The Project workspace lists current selections, every ordered step and its
actual executable, argv and working directory. It retains the original Build/run,
Tasks and `tool.*` actions. Both recipe commands and Project's Review/run use
the same checked file-save flow; individual steps cannot be launched through
the hidden internal commands.

When modified loaded project files exist, choose existing saved files, explicitly
save selected files from the original project, or cancel. No file is implicitly
selected or saved. The full selected set is checked before the first write. A
file is checked again immediately before its write, including changes made by
earlier write hooks. Unselected buffers may change. A partial write failure
retains the names already saved and starts no task. Native
write hooks and readonly protection retain their normal behavior. Nested project
files are excluded. Run saved files leaves unsaved edits untouched, even if they
change during the choice. Source disk identity, target, referenced execution
declarations and the current source window are still checked.

After launch validation, a recipe runs one process step at a time. Successful
exit starts the next step. Failure, cancellation, timeout or invalidated original
source disk identity, project or referenced execution declarations stop later
steps. Unrelated buffer edits, appearance, aliases and unreferenced tools do not
stop it. Changing the current Project selection does not retarget it. The working directory
is checked before each launch, so
Configure may create a later step's directory. Cancellation stays pending until
the current execution scope completes. The default confirms only the direct
process. An explicitly configured [process owner](development/process-ownership.md)
can include ordinary descendants through a Windows Job or Linux session group;
intentional detached daemons and services are excluded. Missing configured
helpers refuse execution rather than falling back. This is host configuration,
not a new executable dependency for the ordinary plugin installation.

Saved-input execution is not an immutable filesystem snapshot. RE35 checks the
declared source and execution plan; it does not discover or freeze every file a
compiler may read. A completed final child reports its actual outcome without
retroactively failing because settings changed afterward.

Project shows the latest recipe run for its selected project, root and recipe
in that source window. It displays observed stage statuses, not inferred build
prerequisites. A Ready label means declared tools are available; it does not
mean Configure or Build has already succeeded. The original configuration and
target appear alongside the outcome even after you change the current choice.
Choose its Task, Source results, Retry original or failed-recipe remedy row.
New progress preserves stable selection; if the selected task action disappears,
move deliberately before executing a new action. Results `t` returns to its
owning Task. Progress refresh stops while Project is covered or closed.

Results retains the originating step for each location. A rerun from another
header or project keeps the original source, root, configuration, target and
arguments. If the project identity, declaration or original target no longer
validates, retry is refused. Source repairs made before retry are supported;
disk changes during its save decision require a fresh review. Selecting files
to save binds consent to their reviewed buffer revisions. The original task is never
redirected to your later selection. Presets can
store logical configuration/target choices, not live executions or machine roots.

## Failure remedies and reviewed changes

In Tasks, `c` opens the failed recipe's owned Results when it has source
locations. Otherwise it opens the unavailable tool's Settings route, or the
failed step's declaration for inspecting argv and directory. An unclassified
process error is not treated as proof that a particular setting is wrong.
Project also offers relevant Settings when a tool declaration or executable
is missing. A host `tool_overrides` executable must be corrected in host setup;
editing the portable command cannot replace that override.

Tasks `r` retries the original validated argv. After changing a tool, use `v`
to review a fresh plan with the task's original recipe, configuration and target.
It shows current step argv/directories and requires an explicit launch decision,
even with clean files. Its context choices are read-only; ordinary Project
remains the place to change them. Opening, cancelling or launching this review
does not replace the current Project selection or its remembered workspace.
The original task remains unchanged.

Return to the original source window before `v`. Changed recipe/project
declarations, source identity or physical root require a new ordinary Project
selection. Replacing a directory or retargeting a source alias during the final
save decision is refused before saving or launching. Existing source-content
repairs remain supported.

## Navigation APIs and references

The public Neovim navigation APIs are `re35.recover_recipe(task_id, { interactive = false })`
and `re35.review_task_recipe(task_id, { interactive = false })`. They start no
command. The only optional argument is the boolean `interactive`; active input,
review or running-command contexts are refused. The saved receipt is local to
the retained task, not part of portable profiles or imported data.

Use the [RE35 development profile](development/self-development.md) to run this
repository's tests and native build through the same workflow.

Follow [recipe recovery](recovery-workflow.md) for the failure → source repair →
original-task retry flow. Host-specific Results and retry details are in the
[VS Code recovery guide](../hosts/vscode/README.md#recover-the-original-task).
See [compatibility](compatibility.md) for host scope and limitations.
