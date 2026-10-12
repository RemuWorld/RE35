#!/usr/bin/env python3
"""Explicit opt-in real CMake/C++ recovery probe; not a human usability test."""
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


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests/acceptance/recipe_compiler_recovery.lua"
REPORT_EVIDENCE = "controlled actual compiler/editor integration; no physical UI or human timing"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--report", type=Path,
                        default=Path(".artifacts/usage/recipe-compiler-recovery.json"))
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 300:
        parser.error("timeout must be in (0, 300]")
    nvim = shutil.which(args.nvim)
    if nvim is None:
        parser.error("Neovim was not found; use --nvim /path/to/nvim")
    if not FIXTURE.is_file():
        parser.error("The recipe compiler fixture is missing")
    destination = (args.report if args.report.is_absolute() else ROOT / args.report).resolve()
    artifact_root = (ROOT / ".artifacts").resolve()
    if (not artifact_root.is_relative_to(ROOT.resolve())
            or not destination.is_relative_to(artifact_root) or destination.suffix != ".json"):
        parser.error("--report must be a JSON file inside this repository's .artifacts directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    observation = destination.with_name(destination.stem + "-observation.json")
    for path, evidence in ((destination, REPORT_EVIDENCE),
                           (observation, "controlled-real-compiler-integration")):
        if not path.resolve().is_relative_to(artifact_root):
            parser.error("Report paths must not resolve outside .artifacts")
        if path.exists():
            try:
                previous = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                parser.error("Refusing to replace an existing file that is not a compiler probe record")
            if not isinstance(previous, dict) or previous.get("evidence") != evidence:
                parser.error("Refusing to replace an existing file that is not a compiler probe record")
    # A failed rerun must never pick up an earlier successful observation.
    observation.unlink(missing_ok=True)
    os.environ["RE35_COMPILER_OBSERVATION"] = observation.as_posix()
    spec = importlib.util.spec_from_file_location("re35_fixture_runner", ROOT / "tests/run.py")
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    before = module.runtime_manifest()
    version = subprocess.run([nvim, "--version"], capture_output=True, text=True,
                             timeout=10, check=True).stdout.splitlines()[0]
    result = module.run_fixture(nvim, FIXTURE, args.timeout, 131072)
    unchanged = before == module.runtime_manifest()
    report = {
        "format": 1,
        "evidence": REPORT_EVIDENCE,
        "neovim": version,
        "runtime_source_sha256": before,
        "runtime_source_unchanged": unchanged,
        "runner_sha256": module.digest(Path(__file__)),
        "shared_runner_sha256": module.digest(ROOT / "tests/run.py"),
        "helpers_sha256": module.digest(ROOT / "tests/helpers.lua"),
        "observation": observation.name if observation.is_file() else None,
        "result": result,
    }
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8", newline="\n")
    print(f"{result['status'].upper()}: recipe compiler recovery; runtime unchanged: {unchanged}")
    if result["status"] != "passed":
        print(result["reason"])
        print(result["output"])
    return 0 if result["status"] == "passed" and unchanged else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
