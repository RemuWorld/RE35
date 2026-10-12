#!/usr/bin/env python3
"""Explicit actual process-tree probe with an already built optional helper."""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = "controlled actual owned process tree; not human usability or detached-service termination"


def launch_crash_probe(helper: Path) -> dict:
    """Explicit Windows compile-time pause build; never a production switch."""
    import ctypes
    api = ctypes.WinDLL("kernel32", use_last_error=True)
    api.OpenProcess.restype = ctypes.c_void_p
    api.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    api.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    api.CloseHandle.argtypes = [ctypes.c_void_p]
    with tempfile.TemporaryDirectory(prefix="re35-launch-owner-") as temporary:
        folder = Path(temporary)
        status = folder / "launch.json"
        command = [str(helper), "--status", str(status), "--grace-ms", "150", "--", sys.executable,
                   str(ROOT / "tests/acceptance/process_tree.py"), "args", str(folder), "must-not-run"]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        child_handle = None
        try:
            expiry = time.monotonic() + 3
            phase = None
            while time.monotonic() < expiry and process.poll() is None:
                try:
                    phase = json.loads(status.read_text(encoding="utf-8"))
                except (FileNotFoundError, ValueError):
                    time.sleep(0.01)
                    continue
                break
            if not isinstance(phase, dict) or phase.get("phase") != "created_suspended_in_job":
                raise ValueError("Launch pause probe did not reach atomic created-in-Job phase")
            child_handle = api.OpenProcess(0x00100000, False, int(phase["pid"]))
            if not child_handle or api.WaitForSingleObject(child_handle, 0) != 258:
                raise ValueError("Expected original live suspended child handle")
            process.kill()  # Exact Popen-owned supervisor, not PID/name matching.
            process.communicate(timeout=3)
            if api.WaitForSingleObject(child_handle, 2000) != 0:
                raise ValueError("Suspended owned Job child did not stop after supervisor death")
            if (folder / "argv.json").exists():
                raise ValueError("Tool executed before launch pause was stopped")
            return {"evidence": "explicit compile-time launch-pause helper", "status": "passed",
                    "phase": "created_suspended_in_job", "child_handle_exit_observed": True, "tool_started": False}
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)
            if child_handle:
                api.CloseHandle(child_handle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--launch-failure-helper", type=Path,
                        help="Windows-only explicitly compiled CE_PROCESS_TEST_LAUNCH_PAUSE helper")
    parser.add_argument("--nonblocking-failure-helper", type=Path,
                        help="Linux-only explicitly compiled CE_PROCESS_TEST_NONBLOCK_FAIL helper")
    parser.add_argument("--ready-write-failure-helper", type=Path,
                        help="Linux-only explicitly compiled CE_PROCESS_TEST_READY_WRITE_FAIL helper")
    parser.add_argument("--result-write-failure-helper", type=Path,
                        help="Linux-only explicitly compiled CE_PROCESS_TEST_RESULT_WRITE_FAIL helper")
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--report", type=Path, default=Path(".artifacts/usage/process-scope.json"))
    args = parser.parse_args()
    nvim = shutil.which(args.nvim)
    helper = args.helper.resolve()
    if not nvim or not helper.is_file():
        parser.error("Neovim and an explicitly supplied already built helper are required")
    fault_helpers = {}
    for name, path, supported in (("launch", args.launch_failure_helper, os.name == "nt"),
                                  ("nonblocking", args.nonblocking_failure_helper, sys.platform.startswith("linux")),
                                  ("ready_write", args.ready_write_failure_helper, sys.platform.startswith("linux")),
                                  ("result_write", args.result_write_failure_helper, sys.platform.startswith("linux"))):
        if path:
            if not supported or not path.resolve().is_file():
                parser.error(f"{name} fault helper requires its supported platform and an existing explicit build")
            fault_helpers[name] = path.resolve()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 300:
        parser.error("timeout must be in (0, 300]")
    artifacts = (ROOT / ".artifacts").resolve()
    destination = (ROOT / args.report).resolve()
    if not artifacts.is_relative_to(ROOT.resolve()) or not destination.is_relative_to(artifacts) or destination.suffix != ".json":
        parser.error("--report must be a JSON file below this repository's .artifacts")
    observation = destination.with_name(destination.stem + "-observation.json")
    for path, kind in ((destination, EVIDENCE), (observation, "controlled-owned-process-tree")):
        if not path.resolve().is_relative_to(artifacts):
            parser.error("Reports must remain below .artifacts")
        if path.exists():
            try:
                old = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                parser.error("Refusing to replace a foreign existing report")
            if not isinstance(old, dict) or old.get("evidence") != kind:
                parser.error("Refusing to replace a foreign existing report")
    destination.parent.mkdir(parents=True, exist_ok=True)
    observation.unlink(missing_ok=True)
    os.environ.update(RE35_PROCESS_HELPER=helper.as_posix(), RE35_PROCESS_PYTHON=Path(sys.executable).as_posix(),
                      RE35_PROCESS_OBSERVATION=observation.as_posix())
    os.environ.pop("RE35_NONBLOCK_FAILURE_HELPER", None)
    os.environ.pop("RE35_READY_WRITE_FAILURE_HELPER", None)
    os.environ.pop("RE35_RESULT_WRITE_FAILURE_HELPER", None)
    if "nonblocking" in fault_helpers:
        os.environ["RE35_NONBLOCK_FAILURE_HELPER"] = fault_helpers["nonblocking"].as_posix()
    if "ready_write" in fault_helpers:
        os.environ["RE35_READY_WRITE_FAILURE_HELPER"] = fault_helpers["ready_write"].as_posix()
    if "result_write" in fault_helpers:
        os.environ["RE35_RESULT_WRITE_FAILURE_HELPER"] = fault_helpers["result_write"].as_posix()
    spec = importlib.util.spec_from_file_location("re35_fixture_runner", ROOT / "tests/run.py")
    assert spec and spec.loader
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    before = runner.runtime_manifest()
    probe_paths = [ROOT / name for name in (
        "native/process_scope.c", "CMakeLists.txt", "examples/re35-development.json", "tests/run.py", "tests/helpers.lua",
        "tests/acceptance/run_process_scope.py", "tests/acceptance/process_scope.lua", "tests/acceptance/process_tree.py")]
    probe_before = {path.relative_to(ROOT).as_posix(): runner.digest(path) for path in probe_paths}
    helper_before = runner.digest(helper)
    fault_before = {name: runner.digest(path) for name, path in fault_helpers.items()}
    result = runner.run_fixture(nvim, ROOT / "tests/acceptance/process_scope.lua", args.timeout, 1048576)
    fault_result = None
    if "launch" in fault_helpers:
        try:
            fault_result = launch_crash_probe(fault_helpers["launch"])
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            fault_result = {"evidence": "explicit compile-time launch-pause helper", "status": "failed", "reason": str(error)}
    after = runner.runtime_manifest()
    probe_after = {path.relative_to(ROOT).as_posix(): runner.digest(path) for path in probe_paths}
    helper_after = runner.digest(helper)
    fault_after = {name: runner.digest(path) for name, path in fault_helpers.items()}
    passed = (result["status"] == "passed" and before == after and probe_before == probe_after
              and helper_before == helper_after and fault_before == fault_after and observation.is_file()
              and (fault_result is None or fault_result["status"] == "passed"))
    record = {"evidence": EVIDENCE, "status": "passed" if passed else "failed", "runtime_source_unchanged": before == after,
              "runtime_sources": before, "probe_sources": probe_before, "probe_source_unchanged": probe_before == probe_after,
              "helper_sha256": helper_before, "helper_sha256_after": helper_after,
              "helper_binary_unchanged": helper_before == helper_after,
              "fault_helpers_sha256": fault_before, "fault_helpers_sha256_after": fault_after,
              "fault_helpers_unchanged": fault_before == fault_after, "launch_fault_probe": fault_result,
              "native_source_sha256": probe_before["native/process_scope.c"], "result": result}
    if passed:
        record["observation"] = json.loads(observation.read_text(encoding="utf-8"))
    destination.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(result.get("output", ""))
    print(f"Owned process-tree probe {'passed' if passed else 'failed'}; report: {destination}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
