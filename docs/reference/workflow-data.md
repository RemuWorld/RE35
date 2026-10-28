# Workflow data

Portable version-1 profiles declare projects, tools, recipes and preferences.
They contain data, not repository code to load. **RE35: Load Portable Profile**
reviews replacement of the active profile; Apply runs no tool and installs
nothing. Valid unsupported fields can remain stored with support feedback.
The active workflow profile belongs to the current host session.

## Projects and recipes

This complete example declares an existing CMake project's configure/build
recipe. CMake, its generator and compiler must already be usable. Replace `app`
with a target in your project.

```json
{
  "version": 1,
  "tools": {
    "cmake": { "command": "cmake", "args": [], "cwd": { "base": "project", "path": "." } }
  },
  "projects": {
    "cpp": {
      "name": "C++ project",
      "root": { "base": "project", "path": "." },
      "configurations": ["Debug", "Release"],
      "targets": ["app"]
    }
  },
  "recipes": {
    "build": {
      "project": "cpp",
      "steps": [
        { "id": "configure", "tool": "cmake", "args": ["-S", "{root}", "-B", "{root}/build", "-DCMAKE_BUILD_TYPE={configuration}"] },
        { "id": "build", "tool": "cmake", "args": ["--build", "{root}/build", "--config", "{configuration}", "--target", "{target}"] }
      ]
    }
  }
}
```

Each step has a stable ID and tool reference. Optional step argv/cwd replaces
that tool field as a whole. Placeholders are `{file}`, `{root}`,
`{configuration}` and `{target}`; substitution preserves argv boundaries and does
not insert a shell. An empty recipe argument remains an empty argv element.
Projects can omit `source` for root-level tools.

The schema accepts up to 64 projects, 128 recipes, 16 steps per recipe and 64
configuration/target choices. Profiles are bounded to 1 MiB, 24 levels and
20,000 value nodes. The exact escaped transport envelope may impose a smaller
effective limit. Absolute machine paths and escaping logical project/step
directories are refused in portable declarations.

## Local mapping and executable overrides

A single workspace folder supplies the `project` base by default. With several
folders, map each project ID to an exact folder URI in local VS Code settings:

```json
{
  "re35.projectRoots": {
    "cpp": "file:///C:/work/cpp-project"
  },
  "re35.toolOverrides": {
    "cmake": {
      "command": "C:/Tools/CMake/bin/cmake.exe",
      "timeout_ms": 120000,
      "cancel_grace_ms": 2000
    }
  }
}
```

Use your folder's actual URI and installed executable. These values are local
setup, not profile exports. `config` and `home` bases require explicit absolute
`re35.configBase` / `re35.homeBase`; empty settings leave those bases unavailable.
Physical root/source escapes are refused. Workspace changes invalidate the
selection instead of redirecting an old task.

RE35 starts existing executables with argv, not an implicit shell. Batch scripts
need a declared interpreter. Source paths and execution declarations are checked
before launch; saved-input execution is not a snapshot of every file a compiler
may read. One recipe executes one step at a time and stops after failure,
cancellation or timeout.

## Project search

Builtin search needs no executable and supports literal, case-sensitive saved
UTF-8 text. It is bounded to 3,000 files, 500 directories, 20,000 entries and depth
24; it does not read ignore files.

To select existing ripgrep, add this field to a full version-1 profile:

```json
{ "adapters": { "project_search": "ripgrep" } }
```

The fragment alone is not a complete profile. Install ripgrep separately. A
selected unavailable provider is refused, without automatic fallback. Ripgrep
supports single-line literal/regex queries and sensitive/insensitive case
options. Regex uses its default engine; RE35 does not request PCRE2 or multiline
matching. Project ignore files apply; parent/global ignore configuration and
external ripgrep configuration are disabled for this invocation.

Local `re35.projectSearch` accepts `command` and bounded `limits` for results,
file bytes, verification reads, output and processing time. Maximum ripgrep
limits are 5,000 results, 4 MiB per file, 64 MiB reads, 16 MiB output and 15
seconds. Defaults and builtin limits are smaller. A limit-triggered stop remains
explicitly partial. Hidden/symlink/generated, binary and unverifiable files are
excluded within the declared provider policy.

Results retain provider, query options, limits and original root. Navigation
rechecks saved file identity/content and refuses stale or unsaved targets.
Project-search coordinates are one-based UTF-8 byte columns and are verified
and converted to VS Code's UTF-16 positions. They are distinct from the shared
Document coordinates described in [core contracts](core-contracts.md#coordinates).

## Tasks, results and retry

Tasks retain original argv, cwd, project, configuration and target. Captured
output is bounded to 1 MiB across the recipe; four task outcomes are retained.
Declared supported compiler `errorformat` patterns can produce source locations.
Unsupported/unconfigured formats expose captured output without guessed ranges.

An original-task retry revalidates the original choices, not the current Project
selection. Changed declarations or expired ownership require a new run. Use
`re35.processHelper` only for an available scope helper and inspect the reported
scope; direct-child and owned-group cancellation have different guarantees.
See [process ownership](core-contracts.md#process-ownership).

## Presentation data

Version-1 `presentation` collections can declare named presets and per-scene
preferences. A saved authored override takes precedence over an applied profile,
which takes precedence over local `re35.presentation`. Clearing an override
reveals the next source. Appearance authoring/import uses explicit Apply/Discard
and starts no command.

Native controls apply supported optional information preferences and report
fallbacks for geometry, spacing, icons and color roles. Required review, task,
stale/partial and unavailable facts remain visible in every density. Appearance
does not alter execution authority or implement the deferred custom renderer.
