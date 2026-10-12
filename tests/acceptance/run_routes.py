#!/usr/bin/env python3
"""Run opt-in recipe/replacement routes; counted models, not human timing."""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = {
    "recipe": (ROOT / "tests/acceptance/recipe_routes.lua",
               "automated-current-session-route-count"),
    "replacement": (ROOT / "tests/acceptance/replacement_routes.lua",
                    "controlled executed routes with model-counted entry; no physical observation"),
}
REPORT_EVIDENCE = "controlled recipe/replacement route integration; no physical observation or human timing"


def route_observation(output: str, evidence: str) -> dict | None:
    decoder = json.JSONDecoder()
    for line in output.splitlines():
        # Neovim status output can precede the fixture's JSON on the same
        # captured line. Decode its object without treating that prefix as JSON.
        for index, character in enumerate(line):
            if character != "{":
                continue
            try:
                value, _ = decoder.raw_decode(line, index)
            except ValueError:
                continue
            if isinstance(value, dict) and value.get("evidence") == evidence:
                return value
    return None


def owned_report(path: Path, parser: argparse.ArgumentParser) -> None:
    if not path.exists():
        return
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        parser.error("Refusing to replace an existing file that is not a route probe record")
    if not isinstance(value, dict) or value.get("evidence") != REPORT_EVIDENCE:
        parser.error("Refusing to replace an existing file that is not a route probe record")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--select", action="append", choices=tuple(FIXTURES), metavar="SCENARIO",
                        help="recipe or replacement; repeat to add scenarios (default: both)")
    parser.add_argument("--nvim", default="nvim", help="Neovim executable or its name on PATH")
    parser.add_argument("--timeout", type=float, default=30,
                        help="Maximum seconds per fixture, in (0, 300] (default: 30)")
    parser.add_argument("--report", type=Path, default=Path(".artifacts/usage/route-counts.json"),
                        help="JSON destination inside this repository's .artifacts directory")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 300:
        parser.error("timeout must be in (0, 300]")
    nvim = shutil.which(args.nvim)
    if nvim is None:
        parser.error("Neovim was not found; use --nvim /path/to/nvim")
    selected = list(dict.fromkeys(args.select or FIXTURES))
    for name in selected:
        if not FIXTURES[name][0].is_file():
            parser.error(f"The {name} route fixture is missing")
    destination = (args.report if args.report.is_absolute() else ROOT / args.report).resolve()
    artifact_root = (ROOT / ".artifacts").resolve()
    if (not artifact_root.is_relative_to(ROOT.resolve())
            or not destination.is_relative_to(artifact_root) or destination.suffix != ".json"):
        parser.error("--report must be a JSON file inside this repository's .artifacts directory")
    owned_report(destination, parser)
    spec = importlib.util.spec_from_file_location("re35_route_fixture_runner", ROOT / "tests/run.py")
    assert spec and spec.loader
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    before = runner.runtime_manifest()
    version_process = subprocess.run([nvim, "--version"], capture_output=True,
                                     timeout=10, check=True)
    version = version_process.stdout.decode("utf-8", errors="replace").splitlines()[0]
    results = []
    for name in selected:
        fixture, evidence = FIXTURES[name]
        result = runner.run_fixture(nvim, fixture, args.timeout, 131072)
        result["scenario"] = name
        result["observation"] = route_observation(result["output"], evidence)
        if result["status"] == "passed" and result["observation"] is None:
            result["status"], result["reason"] = "failed", "Fixture exited without its route observation"
        results.append(result)
        print(f"{result['status'].upper()}: {name} routes ({result['duration_seconds']:.3f}s)", flush=True)
        if result["status"] != "passed":
            print(result["reason"], flush=True)
            print(result["output"], flush=True)
    unchanged = before == runner.runtime_manifest()
    passed = sum(result["status"] == "passed" for result in results)
    report = {
        "format": 1, "evidence": REPORT_EVIDENCE, "neovim": version,
        "physical_keys_measured": False, "human_times_measured": False,
        "runtime_source_sha256": before, "runtime_source_unchanged": unchanged,
        "runner_sha256": runner.digest(Path(__file__)),
        "shared_runner_sha256": runner.digest(ROOT / "tests/run.py"),
        "helpers_sha256": runner.digest(ROOT / "tests/helpers.lua"),
        "passed": passed, "failed": len(results) - passed, "results": results,
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Recheck ownership before replacement; a foreign report is never removed
    # merely because the caller selected it as the output destination.
    owned_report(destination, parser)
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8", newline="\n")
    print(f"{passed}/{len(results)} route fixtures passed; runtime unchanged: {unchanged}", flush=True)
    return 0 if passed == len(results) and unchanged else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Route probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
