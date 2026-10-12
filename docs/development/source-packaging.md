# Preparing a reviewed source package

The source preparer makes a local snapshot of the reviewed working-tree bytes.
It does not create a release, publish a repository, install the plugin, build a
helper or download dependencies. Its manifest records preparation separately
from runtime checks.

Use Python 3.10 or later from the repository's current source checkout:

```sh
python tools/prepare_source.py --list
python tools/prepare_source.py --output .artifacts/packages/re35-candidate
```

`--list` performs read-only policy, source and essential-file checks. `--output`
must name a new directory below this checkout's `.artifacts/packages`. Existing
output is refused. Preparation produces an unpacked `RE35/` source directory,
`source-manifest.json` and `re35-source.zip`. Inspect the manifest and archive
identity before using that snapshot. The directory starts with an `INCOMPLETE`
marker; only successful preparation removes it. On failure, retain the partial
directory for inspection and choose a new destination for a later attempt.

The ZIP contains only the `RE35/` source files and reviewed policy. The companion
manifest stays beside the ZIP and records its relative name, byte size and
SHA-256 in `archive`; it is not embedded inside the ZIP, avoiding a circular
archive identity. Keep the companion manifest with the archive when reviewing
or transferring a candidate.

The package keeps the complete repository source layout. Neovim needs the Lua
host and core; the optional VS Code desktop host locates the core outside
its own directory. Native builds need the core manifest, CMake and example
sources. Test data includes the shared presentation inspection catalog. A
VS Code folder by itself is not an installable substitute for this layout.

## Maintain the closed source list

`tools/source-files.json` is a reviewed list with the exact shape
`{"format": 1, "files": [...]}`. Its relative paths must be sorted and unique,
including under case-insensitive comparison. The policy itself is copied and
hashed separately, so do not put it in its own `files` list. The list includes
intentional untracked source files as well as tracked files; a Git archive of an
older commit does not represent current working-tree development.

Review a new source file, add its path explicitly and check the list again. The
preparer refuses missing files, unlisted candidates and unsupported source file
types. A new root or asset type requires reviewing the tool's accepted roots and
types too. Do not automatically turn an inventory into an approved policy.

The source inventory excludes Git history, local artifacts/validation reports,
builds, dependency caches, downloaded binaries, editor folders, generated help
tags, logs, environment files and backup files. Keep actual user profiles,
history, credentials, machine-specific paths and usage records outside the
approved source roots. Synthetic paths and secret values used by regression
fixtures are reviewed test data; the allowlist is not a universal secret scanner.
Review source contents before a public release.

Symlinks, Windows reparse points, path traversal, alternate data streams,
unsafe Windows names and case collisions are refused. Sources must remain
regular files, with unchanged identity and bytes while the snapshot is prepared.
The native module manifest must exactly cover the included portable core; the
Neovim and VS Code literal source versions must agree. Packaging limits are
8 MiB per source file and 64 MiB total, separate from product document limits.

## Reproducibility and checks

The archive contains sorted relative names, fixed timestamps and file modes,
and uncompressed entries. It includes no Git authors, commit messages, filesystem
timestamps or absolute source paths. Identical source and policy bytes yield
identical archive bytes. Raw source bytes are preserved; different checkout line
endings produce different identities. `.gitattributes` declares LF for text.

Run applicable [tests](../../tests/README.md) against a prepared source snapshot
and check the loaded version, source path and installed help. Rebuild optional
helpers when their sources or core manifest change. Packaging verifies source
identity; it does not establish runtime behavior or approve publication.
See [installation](../install.md) for supported installation methods.
