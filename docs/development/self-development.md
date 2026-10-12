# Develop RE35 through its recipes

The shared [development profile](../../examples/re35-development.json) runs this
checkout's existing tests and native build. It contains logical paths and PATH
executable names. Import preview and profile activation start no programs;
running a recipe is an explicit action.

| Recipe ID | Actual ordered work |
| --- | --- |
| `re35_neovim_tests` | `python tests/run.py` |
| `re35_native_build` | CMake configure, then build all native targets |
| `re35_native_validate` | Validate an already built tree using the native FIFO and C++ fixtures |
| `re35_native_build_validate` | Configure, build, then actual native validation |
| `re35_native_target_build` | Configure, then build only the selected `ce_cpp` or `ce_stdio` |
| `re35_native_target_validate` | Run the selected already built target's actual nonempty fixture |
| `re35_native_target_build_validate` | Configure, build the selected target, then run only its fixture |

Project ID is `re35`, configuration is `Debug` or `Release`, and its logical
target is `all`. Build invokes CMake's default targets rather than assuming a
generator-specific target name. Generated builds go under the ignored
`.artifacts/native-Debug` or `.artifacts/native-Release`. RE35's current
`CMakeLists.txt` registers no CTest tests. These recipes therefore do not treat
an empty `ctest` run as validation.
The original `re35` project and its four recipes retain their `all` behavior.
The additive project `re35_native_targets` exposes the actual CMake targets
`ce_cpp` and `ce_stdio`; its default is Debug/ce_cpp. Select this project to
work with individual native targets. Shared library dependencies are built as
needed, but the opposite executable is not built or validated.

Target recipes call the Python driver with a specific `--native-stage` and
pass configuration and target as ordinary argv. The driver invokes CMake with
direct argv, including `--target ce_cpp` or `--target ce_stdio`, and records
the actual inner invocation in the Task output. Validation runs the C++ host
checks for `ce_cpp`, or `tests/native_stdio.py` FIFO checks for `ce_stdio`.
Neither route substitutes an empty CTest invocation.

Target build trees use `.artifacts/native-<host>-<namespace>-<configuration>`.
Host includes operating system, Linux distribution ID when available, and CPU
architecture, so Windows, Arch and Ubuntu do not share a CMake cache. The
default namespace is `development`; select a fresh `--native-namespace` in
local tool argv when changing generator/compiler. Existing caches belonging to
another checkout, host or configuration, or a changed explicit generator or
compiler, are rejected rather than rewritten. No build directory is deleted.
Legacy `all` paths remain compatible; do not share those old build directories
between operating systems.
The build errorformat accepts GNU `file:line:column` and MSVC
`file(line,column)` / `file(line)` locations. The acceptance checks those syntax
variants through Neovim's actual parser; this is not MSVC compiler execution
evidence.

## Load and run

Use Settings' profile import preview to merge `examples/re35-development.json`
into your profile, then explicitly Apply. Select the checkout root in Project,
choose configuration and recipe, and choose Run. Configuration defaults to
Debug. Modified loaded project files still require the save/run-saved choice.
Reading or importing the JSON never executes repository Lua or build scripts.
Running the declared recipes does execute the checkout's test/build code.

For a separate, in-memory development environment, host setup can read the same
validated profile:

```lua
local re35 = require('re35')
local profile = assert(require('command_tree.profile').read('examples/re35-development.json'))
re35.setup({ profile = { path = false, data = profile } })
re35.run_recipe('re35_neovim_tests', { configuration = 'Debug', target = 'all' })
```

The relative profile path above assumes the checkout is the working directory.
Use an absolute local path when loading it from another directory. Select the
actual checkout root in Project, or supply
`project_overrides = { re35 = { root = localCheckoutDirectory } }` in host setup.
This local root is never written into the portable JSON.
For target recipes, set the local root for `re35_native_targets` as well, or
choose its Root field through Project.

After choosing Run in Project, `\rr` runs its current selection. A quick slot
bound to `project.run_selected_recipe` can shorten that entry. Tasks' Run again
uses the retained invocation instead: retrying a Debug task after choosing
Release still uses Debug, the original root and original argv. The current
Project choice stays Release.

## Installed tools and local overrides

The Neovim recipe needs Python 3.10+ and Neovim 0.11+. A system that names its
interpreter `python3` can set a local executable override:

```lua
tool_overrides = {
  re35_neovim = { command = 'python3' },
  re35_validate = { command = 'python3' },
  re35_target_configure = { command = 'python3' },
  re35_target_build = { command = 'python3' },
  re35_target_validate = { command = 'python3' },
}
```

When Neovim is outside PATH, replace the Neovim tool's complete argv with
`{ 'tests/run.py', '--nvim', localNeovimExecutable }`. Tool argv overrides
replace the original list; they do not append automatically.

Native build needs an already installed C11/C++17 compiler, CMake 3.16+ and a
usable generator. CMake can use its host defaults. To select another generator
or compiler, replace `re35_configure.args` with the profile's configure argv
plus `'-G', 'Ninja'`, `'-DCMAKE_C_COMPILER=' .. localCCompiler`,
`'-DCMAKE_CXX_COMPILER=' .. localCppCompiler`, and/or
`'-DCMAKE_MAKE_PROGRAM=' .. localGeneratorExecutable`. These executable paths
belong in host setup. Change to a fresh local build directory when switching
generators; the recipe does not delete existing builds or repair CMake caches.

Native validation needs a compatible **Lua 5.1 ABI** runtime library. Lua 5.4
does not qualify. Pin it in the local `re35_validate.args` by copying the profile
argv and appending `--lua-runtime`, followed by the installed library path or
loader name. This records the chosen library in the retained invocation. The
driver also accepts host environment `RE35_LUA_RUNTIME` for direct use; an
environment-based choice is not frozen in recipe argv and must be kept stable
when comparing or retrying a task.

For target recipes, append `--cmake`, `--generator`, `--c-compiler`,
`--cxx-compiler`, `--make-program` and/or `--native-namespace` to a copy of the
corresponding target tool's complete argv. Pin `--lua-runtime` in
`re35_target_validate.args`. These flags are local overrides; portable profile
data contains no machine-specific executable or library paths. For example:

```lua
local configure = vim.deepcopy(profile.tools.re35_target_configure.args)
vim.list_extend(configure, { '--generator', 'Ninja', '--native-namespace', 'ninja-development' })
local build = vim.deepcopy(profile.tools.re35_target_build.args)
vim.list_extend(build, { '--native-namespace', 'ninja-development' })
local validate = vim.deepcopy(profile.tools.re35_target_validate.args)
vim.list_extend(validate, { '--native-namespace', 'ninja-development', '--lua-runtime', localLuaRuntime })
local overrides = {
  re35_target_configure = { args = configure },
  re35_target_build = { args = build },
  re35_target_validate = { args = validate },
}
-- Pass overrides as setup's tool_overrides, alongside the validated profile
-- and local project root. Add command = 'python3' to each entry on those hosts.
```

The actual validation calls `tests/native_stdio.py` with the built `ce_stdio`,
runtime and core directory, then calls built `ce_cpp` with the runtime, core
directory and `examples/command.json`. Both must report nonzero completed
checks. Missing binaries, an incompatible runtime, failed checks, incomplete
results, timeout or excessive output fail validation. There are no prerequisite
downloads, shell-assembled commands, network requests, installation or publishing
steps.

## Opt-in controlled checkout check

This acceptance command creates an isolated Neovim environment, loads the shared
profile, and executes the actual checkout's complete Neovim suite through
`re35.run_recipe`. It then chooses Release through the real Project picker and
retries the original Debug invocation through its retained Task. The full suite
runs twice; the runner verifies exact argv/cwd, completed Tasks, Results identity,
unchanged profile/source, and the independent native quickfix list.

```sh
python tests/acceptance/run_self_development.py
```

`--smoke` selects only `test_core_manifest` while debugging the acceptance
driver. A smoke result is explicitly partial and cannot count as full regression
evidence. The default test runner never discovers `self_development.lua`, so
this acceptance cannot recursively launch itself.

Add `--with-native` to run the actual configure/build/validate recipe as well.
For example, with already installed tools:

```sh
python tests/acceptance/run_self_development.py --with-native --generator Ninja --c-compiler gcc --cxx-compiler g++ --make-program ninja --lua-runtime /path/to/libluajit-5.1.so.2
```

Those flags become explicit local overrides, and the runtime choice is pinned
in the native validation child's argv. Use `--nvim` or `--cmake` for executables
outside PATH. They accept Windows paths with spaces as ordinary argv elements.
`--native-build .artifacts/native-Debug --configuration Debug --lua-runtime ...`
runs just the existing native fixtures on a previously built tree; it does not
configure, build, import a profile or start Neovim.

Add `--with-targets` for an additional actual multi-target prerequisite recovery
check. Each run creates a fresh ignored namespace, attempts Debug/ce_cpp
validation before the cache/binary exists, explicitly configures and builds
that original target, then selects Release/ce_stdio through the Project picker.
Retrying the retained failed validation must run the original Debug/ce_cpp
binary with the identical Python argv, pinned runtime and cwd while leaving
the current Release/ce_stdio selection intact. The normal selected-recipe
command then uses that current selection for its configure/build/FIFO
validation pipeline. Both routes record actual
CMake argv, host, cache, executable and nonzero fixture counts; neither builds
or runs the other target's executable.

```sh
python tests/acceptance/run_self_development.py --with-targets --generator Ninja --c-compiler gcc --cxx-compiler g++ --make-program ninja --lua-runtime /path/to/libluajit-5.1.so.2
```

This is **missing-build prerequisite recovery**, not compiler source-error
recovery. The separate compiler-recovery acceptance covers compiler locations,
source edits and the original-target retry. `--with-targets --smoke` is useful
for developing the driver but remains partial Neovim regression evidence.
Native stages can also run directly, for example
`--native-stage build --configuration Debug --target ce_cpp`; configure the
same namespace first. `--native-build ... --target ce_cpp` validates only that
already built target. No mode installs missing tools.

The acceptance timeout defaults to 240 seconds and is limited to 300 seconds.
Native fixture output is bounded to 128 KiB per program and 30 seconds per
program; target CMake configure/build programs have a 60-second bound. Existing native FIFO subprocess calls also have individual 10-second
limits. These bounds cover the owned direct processes; killing a parent does
not confirm that arbitrary descendants or deliberately detached processes have
terminated. This driver adds no process-tree cancellation promise.
Reports default to `.artifacts/usage/self-development.json`; a report
must resolve inside this checkout's ignored `.artifacts`. An existing unrelated
file is refused. Local reports contain machine paths and actual invocation
details and should not be published as portable profile data.

These executions prove controlled self-use of real repository work. They do
not measure physical interaction, human timing, five days of actual development,
an independent reader's experience, or superiority over native tools. Those
acceptance rows remain pending until the corresponding human work is observed.
