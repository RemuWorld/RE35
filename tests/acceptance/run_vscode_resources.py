#!/usr/bin/env python3
"""Opt-in resource baseline using an installed, isolated VS Code test host."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = "controlled actual VS Code API resource baseline"
POLICY = {
    "helper_start_and_register_ms": {"factor": 2, "allowance_ms": 100, "ceiling_ms": 1000},
    "first_command_data_ready_ms": {"factor": 2, "allowance_ms": 100, "ceiling_ms": 1000},
    "warm_command_data_ready": {"factor": 2, "allowance_ms": 25, "ceiling_ms": 250},
    "small_document_find": {"factor": 2, "allowance_ms": 25, "ceiling_ms": 250},
    "prepare_and_discard": {"factor": 2, "allowance_ms": 25, "ceiling_ms": 250},
    "apply_and_undo": {"factor": 2, "allowance_ms": 50, "ceiling_ms": 1000},
    "dispose_to_helper_exit_ms": {"factor": 2, "allowance_ms": 50, "ceiling_ms": 2000},
    "post_plateau_heap_growth_bytes": 4 * 1024 * 1024,
    "post_plateau_helper_private_growth_bytes": 2 * 1024 * 1024,
    "retained_heap_baseline_allowance_bytes": 8 * 1024 * 1024,
    "retained_helper_private_baseline_allowance_bytes": 8 * 1024 * 1024,
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(values: list[float]) -> dict:
    ordered = sorted(values)
    return {"count": len(values), "median": ordered[len(ordered) // 2],
            "p95": ordered[max(0, (len(ordered) * 95 + 99) // 100 - 1)],
            "min": ordered[0], "max": ordered[-1]}


def collect_metrics(runs: list[dict]) -> dict:
    metrics = {}
    for name, policy in POLICY.items():
        if not isinstance(policy, dict):
            continue
        values = []
        for run in runs:
            value = run["timings"][name]
            values.extend(value["samples_ms"] if isinstance(value, dict) else [value])
        metrics[name] = summarize(values)
    for name, key, field in [("heap", "extension_host", "heapUsed"),
                             ("helper_private", "helper", "private_bytes")]:
        values, growth = [], []
        for run in runs:
            before = run["memory"]["after_100_cycles"][key][field]
            after = run["memory"]["after_300_cycles"][key][field]
            if before is not None and after is not None:
                values.append(after)
                growth.append(after - before)
        metrics[f"retained_{name}_bytes"] = summarize(values) if values else None
        metrics[f"post_plateau_{name}_growth_bytes"] = summarize(growth) if growth else None
    return metrics


def compare(report: dict, baseline: dict | None) -> dict:
    checks = []
    metrics = report["metrics"]
    for name, policy in POLICY.items():
        if isinstance(policy, dict):
            current = metrics[name]["p95"]
            limit = policy["ceiling_ms"]
            if baseline is not None:
                original = baseline["metrics"][name]["p95"]
                limit = min(limit, max(original * policy["factor"], original + policy["allowance_ms"]))
            checks.append({"metric": name, "value": current, "limit": limit, "unit": "ms", "passed": current <= limit})
    for kind in ["heap", "helper_private"]:
        name = f"post_plateau_{kind}_growth_bytes"
        value = metrics[name]
        checks.append({"metric": name, "value": value["max"] if value else None,
                       "limit": POLICY[name], "unit": "bytes", "passed": value["max"] <= POLICY[name] if value else None})
        if baseline is not None:
            name = f"retained_{kind}_bytes"
            value, original = metrics[name], baseline["metrics"][name]
            limit = original["max"] + POLICY[f"retained_{kind}_baseline_allowance_bytes"] if original else None
            checks.append({"metric": name, "value": value["max"] if value else None,
                           "limit": limit, "unit": "bytes", "passed": value["max"] <= limit if value and limit else None})
    return {"kind": "fixed workload resource regression, not usability acceptance", "checks": checks,
            "passed": all(item["passed"] is not False for item in checks),
            "unmeasured": [item["metric"] for item in checks if item["passed"] is None]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--code", required=True, type=Path, help="Existing VS Code executable; nothing is downloaded")
    parser.add_argument("--helper", required=True, type=Path, help="Existing ce_stdio executable with its adjacent bridge library")
    parser.add_argument("--lua-runtime", required=True, type=Path, help="Existing compatible Lua 5.1 ABI runtime")
    parser.add_argument("--node", type=Path, help="Installed direct Node executable for the optional single-task resource workload")
    parser.add_argument("--ripgrep", type=Path, help="Installed ripgrep for the separate saved-file search resource workload")
    parser.add_argument("--runs", type=int, default=3, help="Fresh isolated VS Code processes, from 1 to 5 (default 3)")
    parser.add_argument("--timeout", type=int, default=180, help="Maximum seconds for each owned test process, from 30 to 600")
    parser.add_argument("--report", type=Path, default=Path(".artifacts/usage/v6-workflow-resource-baseline.json"))
    parser.add_argument("--baseline", type=Path, help="Previously frozen baseline JSON for the same machine and conditions")
    parser.add_argument("--source-tree", type=Path, help="Previously captured source tree inside .artifacts; default current checkout")
    args = parser.parse_args()
    if args.node and (not args.node.is_absolute() or not args.node.is_file()):
        parser.error("node must be an already installed absolute executable")
    if args.ripgrep and (not args.ripgrep.is_absolute() or not args.ripgrep.is_file()):
        parser.error("ripgrep must be an already installed absolute executable")
    if not 1 <= args.runs <= 5 or not 30 <= args.timeout <= 600:
        parser.error("runs must be in [1, 5] and timeout in [30, 600]")
    for candidate in [args.code, args.helper, args.lua_runtime]:
        if not candidate.is_file():
            parser.error(f"Existing executable/runtime not found: {candidate}")
    artifact_root = (ROOT / ".artifacts").resolve()
    destination = (ROOT / args.report).resolve()
    if not artifact_root.is_relative_to(ROOT.resolve()) or not destination.is_relative_to(artifact_root) or destination.suffix != ".json":
        parser.error("report must be JSON inside this repository's .artifacts directory")
    if destination.exists():
        parser.error("Choose a new report path; a frozen baseline is never overwritten")
    source_base = (ROOT / args.source_tree).resolve() if args.source_tree else ROOT
    if args.source_tree and not source_base.is_relative_to(artifact_root):
        parser.error("source-tree must be a captured tree inside this repository's .artifacts directory")
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    if baseline is not None and (baseline.get("evidence") != EVIDENCE or baseline.get("regression_policy") != POLICY
                                or baseline.get("passed") is not True or len(baseline.get("runs", [])) != args.runs):
        parser.error("baseline must use the same evidence format and frozen resource policy")
    probe_root = artifact_root / ("vscode-resource-" + uuid.uuid4().hex)
    probe_root.mkdir(parents=True)
    source_root = probe_root / "source"
    # Measure an immutable captured source tree, so parallel development does
    # not silently change core modules between repeated helper invocations.
    sources = [*sorted((source_base / "lua").rglob("*.lua")),
               *sorted((source_base / "hosts/vscode").glob("*.js")),
               source_base / "hosts/vscode/package.json", source_base / "hosts/vscode/test/resources.js"]
    task_probe = source_base / "hosts/vscode/test/task-resources.js"
    if task_probe.is_file():
        sources.append(task_probe)
    elif args.node:
        parser.error("selected source tree has no task resource probe")
    if args.ripgrep:
        sources.append(source_base / 'hosts/vscode/test/results-resources.js')
    presentation_probe = source_base / 'hosts/vscode/test/presentation-resources.js'
    if presentation_probe.is_file():
        sources.append(presentation_probe)
        # Newer presentation probes use controlled persistent native widgets.
        # Earlier frozen trees have neither helper nor import; keep them valid.
        native_widget_probe = source_base / 'hosts/vscode/test/native-widget.js'
        if native_widget_probe.is_file():
            sources.append(native_widget_probe)
    source_hashes = {}
    for source in sources:
        relative = source.relative_to(source_base)
        target = source_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        content = source.read_bytes()
        target.write_bytes(content)
        source_hashes[relative.as_posix()] = hashlib.sha256(content).hexdigest()
    native_root = probe_root / "native"
    native_root.mkdir()
    binaries = {}
    for source in [args.helper.resolve(), *sorted(args.helper.resolve().parent.glob("*.dll")),
                   *sorted(args.helper.resolve().parent.glob("libcommand_environment*.so*")),
                   *sorted(args.helper.resolve().parent.glob("libcommand_environment*.dylib"))]:
        target = native_root / source.name
        shutil.copy2(source, target)
        binaries[source.name] = digest(target)
    helper = native_root / args.helper.name
    environment = os.environ.copy()
    environment.pop("RE35_TEST_NODE", None)
    environment.pop("RE35_TEST_RIPGREP", None)
    environment.pop("RE35_TEST_PRESENTATION_RESOURCES", None)
    if args.node:
        environment["RE35_TEST_NODE"] = str(args.node)
    if args.ripgrep:
        environment["RE35_TEST_RIPGREP"] = str(args.ripgrep)
    if presentation_probe.is_file():
        environment["RE35_TEST_PRESENTATION_RESOURCES"] = "1"
    environment.pop("ELECTRON_RUN_AS_NODE", None)
    environment.update(RE35_TEST_HELPER=str(helper), RE35_TEST_LUA_RUNTIME=str(args.lua_runtime.resolve()),
                       RE35_TEST_CORE=str(source_root / "lua"))
    report = {"format": 1, "evidence": EVIDENCE, "created_utc": datetime.now(timezone.utc).isoformat(),
              "regression_policy": POLICY, "source_sha256": source_hashes,
              "snapshot_before_sha256": source_hashes, "runner_sha256": digest(Path(__file__)),
              "binary_sha256": binaries, "lua_runtime_sha256": digest(args.lua_runtime),
              "code_executable_sha256": digest(args.code), "runs": [], "passed": False,
              "human_times_measured": False, "physical_keys_measured": False,
              "rendered_ui_latency_measured": False, "artifact_directory": probe_root.relative_to(ROOT).as_posix()}
    report['external_tool_sha256'] = {name: digest(value) for name, value in [('node', args.node), ('ripgrep', args.ripgrep)] if value}
    try:
        for index in range(args.runs):
            run_root = probe_root / f"run-{index + 1}"
            workspace = run_root / "workspace"
            workspace.mkdir(parents=True)
            user = run_root / "user-data/User"
            user.mkdir(parents=True)
            (user / "settings.json").write_text(json.dumps({"files.autoSave": "off", "update.mode": "none",
                "telemetry.telemetryLevel": "off", "extensions.autoUpdate": False, "extensions.autoCheckUpdates": False}) + "\n", encoding="utf-8")
            environment["RE35_RESOURCE_DIR"] = str(workspace)
            arguments = [str(args.code.resolve()), f"--user-data-dir={user.parent}",
                f"--extensions-dir={run_root / 'extensions'}", f"--extensionDevelopmentPath={source_root / 'hosts/vscode'}",
                f"--extensionTestsPath={source_root / 'hosts/vscode/test/resources.js'}", "--disable-extensions",
                "--disable-updates", "--disable-telemetry", "--disable-gpu", "--skip-welcome", "--skip-release-notes",
                "--disable-workspace-trust", str(workspace)]
            startup = None
            if os.name == "nt":
                startup = subprocess.STARTUPINFO()
                startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startup.wShowWindow = subprocess.SW_HIDE
            started = time.monotonic()
            with (run_root / "stdout.log").open("wb") as stdout, (run_root / "stderr.log").open("wb") as stderr:
                process = subprocess.Popen(arguments, env=environment, stdout=stdout, stderr=stderr, startupinfo=startup)
                try:
                    code = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    if os.name == "nt":
                        subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
                    else:
                        process.kill()
                    process.wait(timeout=10)
                    raise RuntimeError("Owned isolated VS Code resource probe timed out; no baseline accepted")
            sample = json.loads((workspace / "resources.json").read_text(encoding="utf-8"))
            sample["launcher_total_seconds"] = time.monotonic() - started
            sample["launcher_exit_code"] = code
            report["runs"].append(sample)
            if code != 0 or sample.get("passed") is not True:
                raise RuntimeError("Actual VS Code resource probe failed; inspect isolated diagnostics")
            print(f"PASS: actual VS Code resource run {index + 1}/{args.runs} ({sample['launcher_total_seconds']:.2f}s)", flush=True)
        report["snapshot_after_sha256"] = {relative: digest(source_root / relative) for relative in source_hashes}
        report["snapshot_source_unchanged"] = report["snapshot_before_sha256"] == report["snapshot_after_sha256"]
        report['external_tools_unchanged'] = report['external_tool_sha256'] == {name: digest(value) for name, value in [('node', args.node), ('ripgrep', args.ripgrep)] if value}
        report["metrics"] = collect_metrics(report["runs"])
        if baseline is not None:
            if (baseline.get("lua_runtime_sha256") != report["lua_runtime_sha256"]
                    or baseline.get("code_executable_sha256") != report["code_executable_sha256"]
                    or baseline["runs"][0]["platform"] != report["runs"][0]["platform"]
                    or baseline["runs"][0]["vscode"] != report["runs"][0]["vscode"]
                    or baseline["runs"][0]["node"] != report["runs"][0]["node"]
                    or baseline["runs"][0]["conditions"] != report["runs"][0]["conditions"]):
                raise RuntimeError("Baseline uses another platform/VS Code/runtime; create a separate baseline")
            report["compared_baseline_sha256"] = digest(args.baseline)
        report["resource_checks"] = compare(report, baseline)
        report["passed"] = report["snapshot_source_unchanged"] and report['external_tools_unchanged'] and report["resource_checks"]["passed"]
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(f"Report: {destination}; passed: {report['passed']}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
