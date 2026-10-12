#!/usr/bin/env python3
"""Run built-in-only Neovim fixtures without a personal config or saved state."""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
# Shared data consumed by the inspection fixture; no general JSON discovery.
FIXTURE_INPUTS = (TESTS / "fixtures" / "presentation-inspection.json",)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def runtime_manifest() -> dict[str, str]:
    return {path.relative_to(ROOT).as_posix(): digest(path)
            for path in sorted((ROOT / "lua").rglob("*.lua"))}


def fixture_input_manifest() -> dict[str, str]:
    # Record the declared input snapshot even for a narrower fixture selection.
    return {path.relative_to(ROOT).as_posix(): digest(path) for path in FIXTURE_INPUTS}


def selected_fixtures(patterns: list[str]) -> list[Path]:
    fixtures = sorted(TESTS.rglob("test_*.lua"))
    if not patterns:
        return fixtures
    selected: set[Path] = set()
    for pattern in patterns:
        pattern = pattern.replace("\\", "/")
        matched = [path for path in fixtures if any(fnmatch.fnmatchcase(name, pattern)
                   for name in (path.stem, path.name, path.relative_to(TESTS).as_posix(),
                                path.relative_to(ROOT).as_posix()))]
        if not matched:
            raise ValueError(f"No fixture matches {pattern!r}")
        selected.update(matched)
    return sorted(selected)


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "posix":
        # This process group is created exclusively for this test invocation.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    else:
        process.kill()


def run_fixture(nvim: str, fixture: Path, timeout: float, limit: int) -> dict:
    name = fixture.relative_to(ROOT).as_posix()
    token = uuid.uuid4().hex
    start = time.monotonic()
    result = {"fixture": name, "fixture_sha256": digest(fixture), "status": "failed"}
    with tempfile.TemporaryDirectory(prefix="re35-test-") as temporary:
        folder = Path(temporary)
        env = os.environ.copy()
        # These locations also isolate fixtures that leave persistence enabled.
        for key, suffix in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                            ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
                            ("LOCALAPPDATA", "local"), ("APPDATA", "roaming")):
            env[key] = str(folder / suffix)
        env["NVIM_APPNAME"] = "re35-test"
        env["CE_TEST_ROOT"] = ROOT.as_posix()
        env["RE35_TEST_ROOT"] = ROOT.as_posix()
        env["RE35_TEST_TMP"] = folder.as_posix()
        env["RE35_TEST_FIXTURE"] = fixture.as_posix()
        env["RE35_TEST_TOKEN"] = token
        env["NVIM_LOG_FILE"] = str(folder / "nvim.log")
        # Prevent an existing Neovim server address from leaking into child tests.
        env.pop("NVIM", None)
        env.pop("NVIM_LISTEN_ADDRESS", None)
        bootstrap = folder / "bootstrap.lua"
        bootstrap.write_text("""local root = assert(vim.env.CE_TEST_ROOT)
vim.opt.runtimepath = { root, assert(vim.env.VIMRUNTIME) }
vim.opt.packpath = {}
vim.o.swapfile, vim.o.backup, vim.o.writebackup = false, false, false
vim.o.shadafile = 'NONE'
package.path = root .. '/tests/?.lua;' .. root .. '/lua/?.lua;'
  .. root .. '/lua/?/init.lua;' .. package.path
require('helpers').run(assert(vim.env.RE35_TEST_FIXTURE))
""", encoding="utf-8", newline="\n")
        env["RE35_TEST_BOOTSTRAP"] = bootstrap.as_posix()
        command = [nvim, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n",
                   "-c", "lua dofile(vim.env.RE35_TEST_BOOTSTRAP)"]
        process = subprocess.Popen(command, cwd=folder, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=(os.name == "posix"))
        captured = bytearray()
        output_overflow = threading.Event()
        stream_error: list[str] = []

        def read_output() -> None:
            try:
                assert process.stdout is not None
                while chunk := process.stdout.read1(8192):
                    remaining = limit - len(captured)
                    captured.extend(chunk[:max(remaining, 0)])
                    if len(chunk) > remaining:
                        output_overflow.set()
                        stop(process)
                        break
            except (OSError, ValueError) as error:
                stream_error.append(str(error))

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        expired = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            expired = True
            stop(process)
            process.wait(timeout=5)
        reader.join(timeout=2)
        output = captured.decode("utf-8", errors="replace")
        marker = f"RE35_TEST_PASS:{token}"
        # Exit 0 without normal fixture completion is an error, not a pass.
        if expired:
            reason = f"Exceeded {timeout:g}s timeout"
        elif output_overflow.is_set():
            reason = f"Exceeded {limit} byte output limit"
        elif reader.is_alive() or stream_error:
            reason = "Output stream did not close cleanly"
        elif process.returncode != 0:
            reason = f"Neovim exit code {process.returncode}"
        elif marker not in output.splitlines():
            reason = "Fixture exited without its completion marker"
        else:
            reason = None
        result.update(status="passed" if reason is None else "failed",
                      exit_code=process.returncode, duration_seconds=round(time.monotonic() - start, 3),
                      reason=reason, output=output.replace(marker, "RE35_TEST_PASS"))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default="nvim", help="Neovim executable, or its name on PATH")
    parser.add_argument("--select", action="append", default=[], metavar="GLOB",
                        help="Select by fixture stem or relative path; repeat to add fixtures")
    parser.add_argument("--list", action="store_true", help="List selected fixtures without running Neovim")
    parser.add_argument("--timeout", type=float, default=30, help="Maximum seconds per fixture (default: 30)")
    parser.add_argument("--output-limit", type=int, default=131072,
                        help="Maximum combined output bytes per fixture (default: 131072)")
    parser.add_argument("--report", type=Path, help="Write a JSON summary, e.g. .artifacts/tests.json")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 300 or args.output_limit < 1024 or args.output_limit > 1048576:
        parser.error("timeout must be in (0, 300]; output-limit must be 1024..1048576")
    try:
        fixtures = selected_fixtures(args.select)
    except ValueError as error:
        parser.error(str(error))
    if not fixtures:
        parser.error("No fixtures discovered")
    if args.list:
        for fixture in fixtures:
            print(fixture.relative_to(ROOT).as_posix())
        return 0
    nvim = shutil.which(args.nvim)
    if nvim is None:
        parser.error("Neovim was not found; use --nvim /path/to/nvim")
    before = runtime_manifest()
    inputs_before = fixture_input_manifest()
    version_process = subprocess.run([nvim, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     timeout=10, check=True)
    version = version_process.stdout.decode("utf-8", errors="replace").splitlines()[0]
    results = []
    for fixture in fixtures:
        result = run_fixture(nvim, fixture, args.timeout, args.output_limit)
        results.append(result)
        print(f"{result['status'].upper():6} {result['fixture']} ({result['duration_seconds']:.3f}s)", flush=True)
        if result["status"] != "passed":
            print(result["reason"], flush=True)
            print(result["output"], flush=True)
    after = runtime_manifest()
    runtime_unchanged = before == after
    inputs_unchanged = inputs_before == fixture_input_manifest()
    source_unchanged = runtime_unchanged and inputs_unchanged
    passed = sum(result["status"] == "passed" for result in results)
    report = {"format": 1, "neovim": version, "runtime_source_sha256": before,
              "runner_sha256": digest(Path(__file__)), "helpers_sha256": digest(TESTS / "helpers.lua"),
              "runtime_source_unchanged": runtime_unchanged,
              "fixture_input_sha256": inputs_before, "fixture_inputs_unchanged": inputs_unchanged,
              "source_unchanged": source_unchanged, "passed": passed,
              "failed": len(results) - passed, "results": results}
    if args.report:
        destination = args.report if args.report.is_absolute() else ROOT / args.report
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"{passed}/{len(results)} fixtures passed; runtime and fixture inputs unchanged: {source_unchanged}", flush=True)
    return 0 if passed == len(results) and source_unchanged else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Test runner failed: {error}", file=sys.stderr)
        raise SystemExit(1)
