#!/usr/bin/env python3
"""Explicit RE35 checkout recipes; controlled execution, not human usability."""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / "examples/re35-development.json"
FIXTURE = ROOT / "tests/acceptance/self_development.lua"
EVIDENCE = "controlled RE35 checkout self-development recipes; no human observation or timing"


def command_output(command: list[str], timeout: float = 30) -> tuple[int, str]:
    """Bound output in memory and on disk, using direct argv and no shell."""
    captured = bytearray()
    overflow = threading.Event()
    errors: list[str] = []
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)

    def read() -> None:
        try:
            assert process.stdout is not None
            while chunk := process.stdout.read1(8192):
                remaining = 131072 - len(captured)
                captured.extend(chunk[:max(0, remaining)])
                if len(chunk) > remaining:
                    overflow.set()
                    process.kill()
                    return
        except (OSError, ValueError) as error:
            errors.append(str(error))

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        raise
    finally:
        reader.join(timeout=2)
    if reader.is_alive() or overflow.is_set() or errors:
        raise ValueError("Native fixture exceeded its bounded output or left the output stream open")
    assert process.stdout is not None
    process.stdout.close()
    return process.returncode, captured.decode("utf-8", errors="replace")


def native_cache(build: Path, configuration: str) -> dict[str, str]:
    if not build.is_dir():
        raise ValueError("Native build is missing; run the selected target's configure/build recipe first")
    build = build.resolve(strict=True)
    cache_path = build / "CMakeCache.txt"
    if not cache_path.is_file() or cache_path.stat().st_size > 1048576:
        raise ValueError("Expected this checkout's bounded CMake cache; configure/build first")
    cache = {}
    for line in cache_path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith(("#", "//")) and "=" in line and ":" in line.split("=", 1)[0]:
            key, value = line.split("=", 1)
            cache[key.split(":", 1)[0]] = value
    if Path(cache.get("CMAKE_HOME_DIRECTORY", "")).resolve() != ROOT:
        raise ValueError("Native build does not belong to this RE35 checkout")
    choices = cache.get("CMAKE_CONFIGURATION_TYPES", "")
    if (choices and configuration not in choices.split(";")) or (not choices and cache.get("CMAKE_BUILD_TYPE") != configuration):
        raise ValueError("Native build configuration differs from the declared recipe configuration")
    expected_system = {"win32": "Windows", "linux": "Linux", "darwin": "Darwin"}.get(sys.platform)
    if expected_system and cache.get("CMAKE_SYSTEM_NAME") not in (None, expected_system):
        raise ValueError("Native build belongs to another operating system")
    # CMake normally records CMAKE_SYSTEM_NAME in CMakeSystem.cmake, not the cache.
    systems = list((build / "CMakeFiles").glob("*/CMakeSystem.cmake"))
    if not systems or any(path.stat().st_size > 65536 for path in systems):
        raise ValueError("Expected bounded CMake host-system metadata")
    if expected_system and not all(f'set(CMAKE_HOST_SYSTEM_NAME "{expected_system}")' in path.read_text(encoding="utf-8")
                                   for path in systems):
        raise ValueError("Refusing to reuse another operating system's CMake cache")
    return cache


def native_host() -> str:
    """Separate Windows, Linux distributions and CPU architectures by default."""
    distro = ""
    if sys.platform == "linux":
        os_release = Path("/etc/os-release")
        if os_release.is_file() and os_release.stat().st_size <= 65536:
            for line in os_release.read_text(encoding="utf-8").splitlines():
                if line.startswith("ID="):
                    value = line[3:].strip('"\'')
                    if re.fullmatch(r"[a-zA-Z0-9_-]{1,32}", value):
                        distro = "-" + value
                    break
    machine = re.sub(r"[^a-zA-Z0-9_-]", "_", platform.machine())[:32] or "unknown"
    return sys.platform + distro + "-" + machine


def target_build(configuration: str, namespace: str) -> Path:
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", namespace):
        raise ValueError("Native namespace must contain 1 to 64 letters, digits, underscores or hyphens")
    artifact_root = ROOT / ".artifacts"
    build = artifact_root / f"native-{native_host()}-{namespace}-{configuration}"
    if (artifact_root.resolve() != artifact_root or build.is_symlink()
            or not build.resolve().is_relative_to(artifact_root.resolve())):
        raise ValueError("Native target build must resolve inside this checkout's nonsymlink .artifacts")
    return build


def execution_record(phase: str, command: list[str], build: Path, configuration: str,
                     target: str, code: int, **extra: object) -> None:
    record = {"phase": phase, "argv": command, "cwd": str(ROOT), "build": str(build),
              "configuration": configuration, "target": target, "host": native_host(),
              "exit_code": code, **extra}
    print("RE35_NATIVE_EXECUTION:" + json.dumps(record, ensure_ascii=False), flush=True)


def native_validation(build: Path, configuration: str, runtime: str | None,
                      target: str = "all") -> int:
    build = build.resolve()
    native_cache(build, configuration)
    runtime = runtime or os.environ.get("RE35_LUA_RUNTIME")
    if not runtime or "\0" in runtime:
        raise ValueError("Set RE35_LUA_RUNTIME or --lua-runtime to an installed Lua 5.1-compatible library")
    # Shared-library loader names (e.g. libluajit-5.1.so.2) are also valid.
    suffix = ".exe" if os.name == "nt" else ""
    paths = {}
    selected = ("ce_stdio", "ce_cpp") if target == "all" else (target,)
    for name in selected:
        candidates = [build / (name + suffix), build / configuration / (name + suffix)]
        present = [path for path in candidates if path.is_file()]
        if len(present) != 1:
            raise ValueError(f"Expected exactly one built {name}; configure/build the selected configuration first")
        paths[name] = present[0]
    if "ce_stdio" in paths:
        command = [sys.executable, str(ROOT / "tests/native_stdio.py"),
                   str(paths["ce_stdio"]), runtime, str(ROOT / "lua")]
        code, output = command_output(command)
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
        checks = None
        for line in output.splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if (isinstance(value, dict) and value.get("passed") is True
                    and isinstance(value.get("checks"), int) and value["checks"] > 0):
                checks = value["checks"]
        execution_record("validate", command, build, configuration, "ce_stdio", code,
                         executable=str(paths["ce_stdio"]), checks=checks)
        if code != 0:
            return code
        if checks is None:
            raise ValueError("Native FIFO exited without its actual nonempty check result")
    if "ce_cpp" in paths:
        command = [str(paths["ce_cpp"]), runtime, str(ROOT / "lua"), str(ROOT / "examples/command.json")]
        code, output = command_output(command)
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
        match = re.search(r"C\+\+ host: ([1-9][0-9]*) checks PASS; actual counter=3", output)
        execution_record("validate", command, build, configuration, "ce_cpp", code,
                         executable=str(paths["ce_cpp"]), checks=int(match[1]) if match else None)
        if code != 0:
            return code
        if not match:
            raise ValueError("C++ host exited without its actual nonempty check result")
    print("RE35_NATIVE_VALIDATION_PASS: " + ("FIFO and C++ fixtures" if target == "all" else target), flush=True)
    return 0


def native_stage(args: argparse.Namespace, additions: list[str]) -> int:
    if args.target == "all":
        raise ValueError("Native target stages require an actual ce_cpp or ce_stdio target")
    build = target_build(args.configuration, args.native_namespace)
    if args.native_stage == "validate":
        return native_validation(build, args.configuration, args.lua_runtime, args.target)
    cmake = shutil.which(args.cmake)
    if not cmake:
        raise ValueError("Native target stages require already installed CMake")
    if build.exists() and (build / "CMakeCache.txt").exists():
        cache = native_cache(build, args.configuration)
        if args.generator and cache.get("CMAKE_GENERATOR") != args.generator:
            raise ValueError("Generator changed; choose a fresh --native-namespace instead of reusing this cache")
        for addition in additions:
            if addition.startswith(("-DCMAKE_C_COMPILER=", "-DCMAKE_CXX_COMPILER=", "-DCMAKE_MAKE_PROGRAM=")):
                key, value = addition[2:].split("=", 1)
                if cache.get(key) and Path(cache[key]).resolve() != Path(value).resolve():
                    raise ValueError("Compiler or generator executable changed; choose a fresh --native-namespace")
    if args.native_stage == "configure":
        command = [cmake, "-S", str(ROOT), "-B", str(build),
                   f"-DCMAKE_BUILD_TYPE={args.configuration}", *additions]
    else:
        native_cache(build, args.configuration)
        command = [cmake, "--build", str(build), "--config", args.configuration,
                   "--target", args.target, "--parallel", "2"]
    code, output = command_output(command, timeout=60)
    print(output, end="" if output.endswith("\n") else "\n", flush=True)
    execution_record(args.native_stage, command, build, args.configuration, args.target, code)
    return code


def owned_report(path: Path) -> None:
    if path.is_symlink():
        raise ValueError("Report destination must not be a symlink")
    if path.exists():
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or value.get("evidence") != EVIDENCE:
            raise ValueError("Refusing to replace an existing file that is not a self-development probe record")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--report", type=Path, default=Path(".artifacts/usage/self-development.json"))
    parser.add_argument("--with-native", action="store_true",
                        help="Also execute configure/build/actual native validation through RE35")
    parser.add_argument("--with-targets", action="store_true",
                        help="Also run actual Debug/ce_cpp prerequisite recovery and Release/ce_stdio target routes")
    parser.add_argument("--smoke", action="store_true",
                        help="Debug the recipe driver with only test_core_manifest; not full regression evidence")
    parser.add_argument("--native-build", type=Path,
                        help="Run actual native fixtures on an already built tree; no Neovim recipe probe")
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Debug",
                        help="Native stage/build configuration; recipe acceptance exercises Debug then Release")
    parser.add_argument("--native-stage", choices=("configure", "build", "validate"),
                        help="Explicit selected-target stage; uses a host/configuration-isolated build cache")
    parser.add_argument("--target", choices=("all", "ce_cpp", "ce_stdio"), default="all")
    parser.add_argument("--native-namespace", default="development",
                        help="Local build namespace; changing generator/compiler requires a fresh namespace")
    parser.add_argument("--lua-runtime", help="Installed Lua 5.1-compatible runtime library; host-only")
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--generator", help="Explicit installed CMake generator, e.g. Ninja")
    parser.add_argument("--c-compiler", help="Explicit already installed C compiler")
    parser.add_argument("--cxx-compiler", help="Explicit already installed C++ compiler")
    parser.add_argument("--make-program", help="Explicit already installed generator executable")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 300:
        parser.error("timeout must be in (0, 300]")
    if args.native_build:
        if args.with_native or args.with_targets or args.native_stage:
            parser.error("--native-build, --native-stage and recipe acceptance are separate modes")
        if args.native_namespace != "development":
            parser.error("--native-namespace applies to --native-stage; --native-build already selects an explicit tree")
        return native_validation(args.native_build, args.configuration, args.lua_runtime, args.target)
    additions = []
    if args.generator:
        additions += ["-G", args.generator]
    for flag, value in (("CMAKE_C_COMPILER", args.c_compiler),
                        ("CMAKE_CXX_COMPILER", args.cxx_compiler),
                        ("CMAKE_MAKE_PROGRAM", args.make_program)):
        if value:
            installed = shutil.which(value)
            if not installed:
                parser.error(f"{flag} executable was not found; no prerequisite is installed automatically")
            additions.append(f"-D{flag}={installed}")
    if args.native_stage:
        if args.with_native or args.with_targets or args.smoke:
            parser.error("--native-stage and recipe acceptance are separate modes")
        return native_stage(args, additions)
    if args.target != "all":
        parser.error("--target applies only to --native-stage/--native-build; --with-targets exercises both actual targets")
    if args.native_namespace != "development":
        parser.error("--native-namespace applies only to --native-stage; target acceptance uses a fresh namespace")
    if args.configuration != "Debug":
        parser.error("--configuration applies only to --native-build; checkout acceptance tests Debug then selects Release")
    nvim = shutil.which(args.nvim)
    if not nvim:
        parser.error("Neovim was not found; select an already installed executable with --nvim")
    original = args.report if args.report.is_absolute() else ROOT / args.report
    destination = original.resolve()
    artifact_root = (ROOT / ".artifacts").resolve()
    if (original.is_symlink() or artifact_root != ROOT / ".artifacts"
            or not destination.is_relative_to(artifact_root) or destination.suffix != ".json"):
        parser.error("--report must be a nonsymlink JSON file inside this repository's .artifacts")
    owned_report(destination)
    cmake = shutil.which(args.cmake) if args.with_native or args.with_targets else ""
    runtime = args.lua_runtime or os.environ.get("RE35_LUA_RUNTIME", "")
    if (args.with_native or args.with_targets) and (not cmake or not runtime):
        parser.error("Native recipe acceptance needs already installed CMake and RE35_LUA_RUNTIME/--lua-runtime")
    if args.with_native:
        build = ROOT / ".artifacts/native-Debug"
        if build.is_symlink() or not build.resolve().is_relative_to(artifact_root):
            parser.error("The self-development build directory must resolve inside this repository's .artifacts")
    spec = importlib.util.spec_from_file_location("re35_self_fixture_runner", ROOT / "tests/run.py")
    assert spec and spec.loader
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    before = runner.runtime_manifest()
    source_paths = [PROFILE, FIXTURE, Path(__file__), ROOT / "tests/run.py", ROOT / "CMakeLists.txt",
                    ROOT / "tests/native_stdio.py", ROOT / "examples/cpp/main.cpp",
                    ROOT / "tests/helpers.lua", ROOT / "native/ce.c", ROOT / "native/ce.h",
                    ROOT / "native/core_modules.def", ROOT / "native/stdio.c"]
    driver_sources = {path.relative_to(ROOT).as_posix(): runner.digest(path) for path in source_paths}
    target_options = ["--cmake", cmake or "", "--native-namespace", "acceptance-" + uuid.uuid4().hex]
    for flag, value in (("--generator", args.generator), ("--c-compiler", args.c_compiler),
                        ("--cxx-compiler", args.cxx_compiler), ("--make-program", args.make_program)):
        if value:
            target_options += [flag, value]
    environment = {"RE35_SELF_PYTHON": sys.executable, "RE35_SELF_NVIM": nvim,
                   "RE35_SELF_SMOKE": "1" if args.smoke else "0",
                   "RE35_SELF_NATIVE": "1" if args.with_native else "0",
                   "RE35_SELF_TARGETS": "1" if args.with_targets else "0",
                   "RE35_SELF_TARGET_OPTIONS": json.dumps(target_options),
                   "RE35_SELF_CMAKE": cmake or "",
                   "RE35_SELF_CONFIGURE_ARGS": json.dumps(additions),
                   "RE35_LUA_RUNTIME": runtime}
    previous = {key: os.environ.get(key) for key in environment}
    os.environ.update(environment)
    try:
        result = runner.run_fixture(nvim, FIXTURE, args.timeout, 131072)
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    observation = None
    for line in result["output"].splitlines():
        if line.startswith("RE35_SELF_OBSERVATION:"):
            observation = json.loads(line[len("RE35_SELF_OBSERVATION:"):])
    unchanged = before == runner.runtime_manifest()
    driver_unchanged = all(runner.digest(ROOT / name) == value for name, value in driver_sources.items())
    if result["status"] == "passed" and observation is None:
        result.update(status="failed", reason="Missing actual recipe observation")
    if not unchanged or not driver_unchanged:
        result.update(status="failed", reason="Runtime, profile or driver sources changed during this acceptance")
    report = {"format": 1, "evidence": EVIDENCE, "human_times_measured": False,
              "runtime_source_sha256": before, "runtime_source_unchanged": unchanged,
              "driver_source_sha256": driver_sources, "driver_source_unchanged": driver_unchanged,
              "profile_sha256": runner.digest(PROFILE), "runner_sha256": runner.digest(Path(__file__)),
              "shared_runner_sha256": runner.digest(ROOT / "tests/run.py"),
              "observation": observation, "result": result}
    destination.parent.mkdir(parents=True, exist_ok=True)
    owned_report(destination)
    # Write a complete record atomically; a failed rerun cannot retain a prior pass.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                     prefix=".self-development-", suffix=".json", dir=destination.parent,
                                     delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    try:
        owned_report(destination)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"{result['status'].upper()}: checkout recipes; runtime unchanged: {unchanged}; driver unchanged: {driver_unchanged}")
    if result["status"] != "passed":
        print(result["reason"])
        print(result["output"])
    return 0 if result["status"] == "passed" and unchanged and driver_unchanged else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Self-development probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
