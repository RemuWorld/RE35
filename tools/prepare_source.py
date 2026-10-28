#!/usr/bin/env python3
"""Prepare a reviewed local source snapshot; never build, install or publish it."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import zipfile

ROOT = Path(__file__).absolute().parents[1]
POLICY = "tools/source-files.json"
ROOT_FILES = {".gitattributes", ".gitignore", "LICENSE", "README.md", "CHANGELOG.md",
              "CONTRIBUTING.md", "CMakeLists.txt"}
SOURCE_TYPES = {"lua": {".lua"}, "native": {".c", ".h", ".def"},
                "doc": {".txt"}, "docs": {".md"},
                "examples": {".json", ".lua", ".cpp", ".cs", ".csproj"},
                "tests": {".lua", ".py", ".js", ".json", ".md"},
                "hosts/vscode": {".js", ".json", ".md"}, "hosts/vscode/runtime": {".lua"},
                "hosts/vscode/test": {".lua"},
                "tools": {".py", ".json"}}
EXCLUDED_DIRS = {".git", ".artifacts", ".validation", "node_modules", "__pycache__",
                 "bin", "obj", "dist", "venv", ".venv", ".idea", ".vscode"}
EXCLUDED_FILES = {".DS_Store", "Thumbs.db", "nvim.log", ".nvimlog"}
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024


def forbidden(part: str) -> bool:
    lower = part.casefold()
    return lower in EXCLUDED_DIRS or lower == "build" or lower.startswith("build-")


def safe_name(name: str) -> str:
    if (not isinstance(name, str) or not name or "\\" in name or
            any(ord(c) < 32 or ord(c) == 127 or c in ':<>"|?*' for c in name)):
        raise ValueError("Invalid source path")
    parts = name.split("/")
    for part in parts:
        stem = part.split(".", 1)[0].upper()
        if (not part or part in {".", ".."} or part.endswith((".", " ")) or forbidden(part)
                or stem in {"CON", "PRN", "AUX", "NUL"}
                or re.fullmatch(r"(?:COM|LPT)[1-9]", stem)):
            raise ValueError(f"Unsafe source path: {name}")
    if name == POLICY:
        return name
    if name not in ROOT_FILES and not any(
            name.startswith(base + "/") and Path(name).suffix in suffixes
            for base, suffixes in SOURCE_TYPES.items()):
        raise ValueError(f"Source path is outside the reviewed types: {name}")
    if any(part.startswith(".") for part in parts) and name not in ROOT_FILES:
        raise ValueError(f"Hidden source path requires a policy change: {name}")
    return name


def guard(path: Path, directory: bool = False) -> os.stat_result:
    for item in reversed((path, *path.parents)):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError(f"Symlink or reparse point refused: {item}")
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode):
        raise ValueError(f"Unexpected filesystem type: {path}")
    return info


def identity(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, getattr(info, "st_file_attributes", 0))


def read_source(path: Path) -> tuple[bytes, tuple]:
    before = identity(guard(path))
    if before[3] > MAX_FILE:
        raise ValueError(f"Source file exceeds packaging limit: {path.name}")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags), "rb") as stream:
        opened = identity(os.fstat(stream.fileno()))
        # Windows can expose different ctime meanings through path/handle stat.
        # Pin their common fields, then compare each API's full identity to itself.
        if opened[:5] != before[:5]:
            raise ValueError(f"Source identity changed before reading: {path.name}")
        content = stream.read(MAX_FILE + 1)
        after = identity(os.fstat(stream.fileno()))
    if len(content) > MAX_FILE or after != opened or identity(guard(path)) != before:
        raise ValueError(f"Source changed while reading: {path.name}")
    return content, before


def inventory() -> list[str]:
    names = set(ROOT_FILES)
    for base in SOURCE_TYPES:
        guard(ROOT / base, True)
        for folder, dirs, files in os.walk(ROOT / base, followlinks=False):
            dirs[:] = sorted(part for part in dirs if not forbidden(part))
            for part in dirs:
                guard(Path(folder) / part, True)
            for part in files:
                name = (Path(folder) / part).relative_to(ROOT).as_posix()
                if (name == POLICY or name == "doc/tags" or part in EXCLUDED_FILES
                        or part.startswith(".env") or part.endswith(("~", ".swp", ".swo", ".pyc", ".pyo"))):
                    continue
                names.add(safe_name(name))
    return sorted(names)


def parse_policy(content: bytes) -> list[str]:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate source policy key")
            result[key] = value
        return result
    data = json.loads(content.decode("utf-8"), object_pairs_hook=unique)
    if (not isinstance(data, dict) or set(data) != {"format", "files"}
            or type(data["format"]) is not int or data["format"] != 1
            or not isinstance(data["files"], list) or not 1 <= len(data["files"]) <= 5000):
        raise ValueError("Expected source policy format 1 and a bounded files list")
    names = [safe_name(name) for name in data["files"]]
    if POLICY in names or names != sorted(names) or len({n.casefold() for n in names}) != len(names):
        raise ValueError("Policy paths must be sorted, unique and omit the policy itself")
    if names != inventory():
        actual = set(inventory())
        raise ValueError(f"Source policy differs: unlisted={sorted(actual-set(names))}; missing={sorted(set(names)-actual)}")
    return names


def validate_sources(contents: dict[str, bytes]) -> str:
    essential = ROOT_FILES | {"native/core_modules.def",
        "hosts/vscode/package.json", "hosts/vscode/extension.js", "tests/run.py",
        "tests/fixtures/presentation-inspection.json", "examples/re35-development.json"}
    if not essential <= contents.keys():
        raise ValueError("Essential source-package files are missing")
    if "lua/re35.lua" in contents and not re.search(r"return\s+require\(['\"]command_tree['\"]\)",
                     contents["lua/re35.lua"].decode("utf-8")):
        raise ValueError("Canonical re35 compatibility entry is missing")
    manifest = contents["native/core_modules.def"].decode("utf-8")
    modules = []
    for line in manifest.splitlines():
        if not line.strip() or re.fullmatch(r"/\*.*\*/", line):
            continue
        match = re.fullmatch(r'CE_CORE_MODULE\("([A-Za-z0-9_.]+)", "([A-Za-z0-9_/]+\.lua)"\)', line)
        if not match or match[1] != match[2][:-4].replace("/", "."):
            raise ValueError("Invalid native core manifest declaration")
        modules.append("lua/" + match[2])
    actual = {name for name in contents if name.startswith("lua/command_environment/core/")}
    if len(modules) != len(set(modules)) or set(modules) != actual or not modules:
        raise ValueError("Native core manifest differs from packaged core sources")
    package = json.loads(contents["hosts/vscode/package.json"].decode("utf-8"))
    # New releases target the VS Code host. Retained Neovim sources keep their
    # own historical version; changing a package must not relabel legacy code.
    version = package.get("version") if isinstance(package, dict) else None
    if not isinstance(package, dict):
        raise ValueError("VS Code package must be an object")
    if package.get("main") != "./extension.js" or package.get("license") != "Apache-2.0":
        raise ValueError("Unexpected VS Code source entry or license")
    catalog = json.loads(contents["tests/fixtures/presentation-inspection.json"].decode("utf-8"))
    if not isinstance(catalog, dict) or catalog.get("version") != 1 or not isinstance(catalog.get("cases"), list):
        raise ValueError("Shared presentation inspection catalog is invalid")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Invalid source version")
    return version


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--list", action="store_true", help="Validate and list reviewed source paths without writing")
    choice.add_argument("--output", type=Path, help="Fresh directory below this checkout's .artifacts/packages")
    args = parser.parse_args()
    destination = None
    try:
        guard(ROOT, True)
        policy, policy_identity = read_source(ROOT / POLICY)
        names = parse_policy(policy)
        contents, identities = {}, {}
        total = len(policy)
        for name in names:
            content, source_identity = read_source(ROOT / name)
            total += len(content)
            if total > MAX_TOTAL:
                raise ValueError("Total source bytes exceed the packaging limit")
            contents[name], identities[name] = content, source_identity
        version = validate_sources(contents)
        copied = dict(contents, **{POLICY: policy})

        def verify_snapshot():
            if inventory() != names:
                raise ValueError("Source inventory changed during preparation")
            for name, content in copied.items():
                current, current_identity = read_source(ROOT / name)
                expected = policy_identity if name == POLICY else identities[name]
                if current_identity != expected or current != content:
                    raise ValueError(f"Source changed during preparation: {name}")
                if destination is not None and read_source(destination / "RE35" / name)[0] != content:
                    raise ValueError(f"Snapshot changed during preparation: {name}")

        if args.list:
            verify_snapshot()
            print("\n".join(names + [POLICY]))
            return 0
        requested = args.output if args.output.is_absolute() else ROOT / args.output
        requested = Path(os.path.abspath(requested))
        parent = ROOT / ".artifacts" / "packages"
        if not requested.is_relative_to(parent) or requested == parent:
            raise ValueError("--output must be a fresh directory below .artifacts/packages")
        # Pin existing ancestors before creating only the missing output parents.
        ancestor = requested.parent
        while not ancestor.exists():
            if ancestor.is_symlink():
                raise ValueError("Dangling output ancestor refused")
            ancestor = ancestor.parent
        guard(ancestor, True)
        requested.parent.mkdir(parents=True, exist_ok=True)
        guard(requested.parent, True)
        requested.mkdir()  # Never replace an existing output.
        destination = requested
        output_identity = identity(guard(destination, True))[:2]
        marker = destination / "INCOMPLETE"
        marker.write_text("Source preparation incomplete; do not install this directory.\n", encoding="utf-8")
        for name, content in sorted(copied.items()):
            target = destination / "RE35" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            guard(target.parent, True)
            with target.open("xb") as stream:
                stream.write(content)
        record = {"format": 1, "kind": "re35-source-preparation", "version": version,
                  "status": "prepared", "runtime_validation": "deferred", "resource_validation": "deferred",
                  "human_acceptance": "unjudged", "policy_sha256": digest(policy),
                  "files": [{"path": name, "bytes": len(content), "sha256": digest(content)}
                            for name, content in sorted(copied.items())]}
        archive = destination / "re35-source.zip"
        with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_STORED) as output:
            entries = {"RE35/" + name: content for name, content in copied.items()}
            for name, content in sorted(entries.items()):
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                output.writestr(info, content)
        archive_before = identity(guard(archive))
        archive_hash = hashlib.sha256()
        with archive.open("rb") as stream:
            archive_opened = identity(os.fstat(stream.fileno()))
            if archive_opened[:5] != archive_before[:5]:
                raise ValueError("Archive identity changed before hashing")
            while block := stream.read(1024 * 1024):
                archive_hash.update(block)
            if identity(os.fstat(stream.fileno())) != archive_opened:
                raise ValueError("Archive changed during hashing")
        if identity(guard(archive)) != archive_before:
            raise ValueError("Archive identity changed during hashing")
        record["archive"] = {"path": "re35-source.zip", "bytes": archive_before[3],
                             "sha256": archive_hash.hexdigest()}
        manifest_bytes = (json.dumps(record, ensure_ascii=True, indent=2) + "\n").encode("utf-8")
        companion = destination / "source-manifest.json"
        with companion.open("xb") as stream:
            stream.write(manifest_bytes)
        verify_snapshot()
        if identity(guard(archive)) != archive_before or read_source(companion)[0] != manifest_bytes:
            raise ValueError("Prepared archive or companion manifest changed")
        if identity(guard(destination, True))[:2] != output_identity:
            raise ValueError("Output directory identity changed")
        marker.unlink()
        print(f"Prepared {version}: {len(copied)} source files; runtime validation remains deferred.")
        print(f"Archive SHA-256: {archive_hash.hexdigest()}")
        return 0
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"Source preparation refused: {error}", file=sys.stderr)
        if destination is not None:
            print(f"Incomplete output retained for inspection: {destination}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
