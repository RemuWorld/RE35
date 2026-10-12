#!/usr/bin/env python3
"""Opt-in actual Neovim -> Node VS Code services/native core -> Neovim file round trip.

This verifies appearance declarations and renderer projections, not physical
interaction, Extension Host activation, Memento storage or release acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
LIMIT = 131072
EVIDENCE = "actual-neovim-node-services-appearance-file-roundtrip"


def digest(file: Path) -> str:
    value = hashlib.sha256()
    with file.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def manifest() -> dict[str, str]:
    files = [*ROOT.joinpath("lua").rglob("*.lua"),
             *ROOT.joinpath("hosts/vscode").glob("*.js"),
             ROOT / "tests/acceptance/presentation_roundtrip.lua",
             ROOT / "tests/acceptance/presentation_roundtrip.js", Path(__file__)]
    return {file.relative_to(ROOT).as_posix(): digest(file) for file in sorted(files)}


def executable(value: str, parser: argparse.ArgumentParser) -> Path:
    selected = shutil.which(value)
    path = Path(selected or value).resolve()
    if not path.is_file():
        parser.error(f"Executable was not found: {value}")
    return path


def stop(process: subprocess.Popen[bytes]) -> dict:
    if process.poll() is not None:
        return {"requested": False, "observed_exit": True}
    if os.name == "posix":
        # Only this runner-created process group, never a name-wide match.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        method = "owned-process-group"
    elif os.name == "nt":
        # Node owns one helper child. Terminate the runner-created PID tree if
        # its inner deadline/disposal cannot settle; detached programs excluded.
        system = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/taskkill.exe"
        try:
            subprocess.run([str(system), "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=5, check=False, creationflags=subprocess.CREATE_NO_WINDOW)
        except (OSError, subprocess.SubprocessError):
            process.kill()
        method = "owned-pid-tree"
    else:
        process.kill()
        method = "direct-process-only"
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        return {"requested": True, "method": method, "observed_exit": False}
    return {"requested": True, "method": method, "observed_exit": True,
            "descendant_exit": "not independently observed after emergency termination"}


def run_step(command: list[str], folder: Path, env: dict[str, str], timeout: float) -> dict:
    start = time.monotonic()
    process = subprocess.Popen(command, cwd=folder, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=os.name == "posix",
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    captured, overflow = bytearray(), threading.Event()
    read_errors: list[str] = []
    termination = {"requested": False}

    def consume() -> None:
        try:
            assert process.stdout is not None
            while chunk := process.stdout.read1(8192):
                remaining = LIMIT - len(captured)
                captured.extend(chunk[:max(remaining, 0)])
                if len(chunk) > remaining:
                    overflow.set()
                    stop(process)
                    break
        except (OSError, ValueError) as error:
            read_errors.append(str(error))

    reader = threading.Thread(target=consume, daemon=True)
    reader.start()
    expired = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        expired = True
        termination = stop(process)
    reader.join(timeout=2)
    if reader.is_alive():
        termination = stop(process)
        assert process.stdout is not None
        process.stdout.close()
        reader.join(timeout=2)
    output = captured.decode("utf-8", errors="replace")
    reason = ("deadline exceeded" if expired else "bounded log overflow" if overflow.is_set()
              else "output pipe did not settle" if reader.is_alive() or read_errors
              else f"exit code {process.returncode}" if process.returncode != 0 else None)
    observation = None
    decoder = json.JSONDecoder()
    for line in output.splitlines():
        for index, character in enumerate(line):
            if character != "{":
                continue
            try:
                candidate, _ = decoder.raw_decode(line, index)
            except ValueError:
                continue
            if isinstance(candidate, dict) and candidate.get("passed") is True:
                observation = candidate
    return {"command": command, "status": "passed" if reason is None else "failed",
            "reason": reason, "exit_code": process.returncode,
            "duration_seconds": round(time.monotonic() - start, 6),
            "output": output, "output_bytes": len(captured), "output_limit": LIMIT,
            "observation": observation, "emergency_termination": termination}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--node", default="node")
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--core", required=True, type=Path,
                        help="Existing installed/source Lua directory supplied to the native helper")
    parser.add_argument("--output", required=True, type=Path,
                        help="New JSON report inside the repository .artifacts directory")
    parser.add_argument("--timeout", type=float, default=60, help="Per-phase deadline, from 20 to 300 seconds")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 20 <= args.timeout <= 300:
        parser.error("--timeout must be from 20 to 300 seconds")
    nvim, node = executable(args.nvim, parser), executable(args.node, parser)
    helper, runtime, core = args.helper.resolve(), args.runtime.resolve(), args.core.resolve()
    if not helper.is_file() or not runtime.is_file() or not core.is_dir():
        parser.error("--helper/--runtime must be existing files and --core an existing Lua directory")
    artifact = (ROOT / ".artifacts").resolve()
    output = (args.output if args.output.is_absolute() else ROOT / args.output).resolve()
    if not artifact.is_relative_to(ROOT.resolve()) or not output.is_relative_to(artifact) or output.suffix != ".json":
        parser.error("--output must be a new JSON report inside this repository's .artifacts")
    if output.exists():
        parser.error("--output already exists; prior evidence is never replaced")
    artifact.mkdir(exist_ok=True)
    folder = (artifact / ("presentation-roundtrip-" + uuid.uuid4().hex)).resolve()
    if not folder.is_relative_to(artifact):
        parser.error("Resolved isolated workspace escaped the repository artifact root")
    folder.mkdir(mode=0o700)
    before = manifest()
    binaries = {name: {"path": str(file), "sha256": digest(file)}
                for name, file in (("nvim", nvim), ("node", node), ("helper", helper), ("runtime", runtime))}
    core_sources = {file.relative_to(core).as_posix(): digest(file) for file in sorted(core.rglob("*.lua"))}
    if not core_sources:
        parser.error("--core contains no Lua source files")
    env = os.environ.copy()
    for key, suffix in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                        ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
                        ("LOCALAPPDATA", "local"), ("APPDATA", "roaming")):
        env[key] = str(folder / suffix)
    env.pop("NVIM", None)
    env.pop("NVIM_LISTEN_ADDRESS", None)
    env.update(NVIM_APPNAME="re35-appearance-roundtrip", NVIM_LOG_FILE=str(folder / "nvim.log"),
               RE35_ROUNDTRIP_ROOT=ROOT.as_posix(), RE35_ROUNDTRIP_FOLDER=folder.as_posix(),
               RE35_ROUNDTRIP_HELPER=str(helper), RE35_ROUNDTRIP_RUNTIME=str(runtime),
               RE35_ROUNDTRIP_CORE=str(core), RE35_ROUNDTRIP_DEADLINE_MS=str(int((args.timeout - 10) * 1000)),
               RE35_ROUNDTRIP_FIXTURE=(ROOT / "tests/acceptance/presentation_roundtrip.lua").as_posix())
    lua_command = [str(nvim), "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n",
                   "-c", "lua dofile(vim.env.RE35_ROUNDTRIP_FIXTURE)"]
    steps = []
    for phase, command in (("export", lua_command), ("node", [str(node), str(ROOT / "tests/acceptance/presentation_roundtrip.js")]),
                           ("return", lua_command)):
        env["RE35_ROUNDTRIP_PHASE"] = phase
        result = run_step(command, folder, env, args.timeout)
        result["phase"] = phase
        if result["status"] == "passed" and result["observation"] is None:
            result.update(status="failed", reason="phase exited without its structured completion observation")
        if phase == "node" and result["status"] == "passed" and not result["observation"].get("cleanup", {}).get("helperClosed"):
            result.update(status="failed", reason="owned helper exit was not observed")
        (folder / f"{phase}-output.txt").write_text(result["output"], encoding="utf-8", newline="\n")
        steps.append(result)
        if result["status"] != "passed":
            break
    unchanged = before == manifest()
    binaries_unchanged = all(value["sha256"] == digest(Path(value["path"])) for value in binaries.values())
    core_unchanged = core_sources == {file.relative_to(core).as_posix(): digest(file) for file in sorted(core.rglob("*.lua"))}
    files = {file.name: {"bytes": file.stat().st_size, "sha256": digest(file)}
             for file in folder.glob("*.json")}
    passed = len(steps) == 3 and all(step["status"] == "passed" for step in steps)
    report = {"format": 1, "evidence": EVIDENCE, "passed": passed and unchanged and binaries_unchanged and core_unchanged,
              "scope": "actual Neovim codec/float projections + Node VS Code services/native helper/appearance files; declared trusted UI/workflow and memory-storage facade",
              "actual_extension_host": False, "physical_gestures": False, "human_times": False,
              "release_acceptance": False, "resource_acceptance": False,
              "isolated_workspace": str(folder), "source_sha256": before, "source_unchanged": unchanged,
              "binaries": binaries, "binaries_unchanged": binaries_unchanged,
              "core_path": str(core), "core_source_sha256": core_sources, "core_unchanged": core_unchanged,
              "appearance_files": files, "steps": steps}
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "report": str(output), "phases": len(steps)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Appearance round-trip runner failed: {error}", file=sys.stderr)
        raise SystemExit(1)
