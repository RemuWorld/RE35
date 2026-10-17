#!/usr/bin/env python3
"""Run the actual VS Code integration fixture from an immutable local snapshot."""
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
import uuid

ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--code', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--lua-runtime', required=True, type=Path)
    parser.add_argument('--node', type=Path, help='Installed direct Node executable for task/editor admission checks')
    parser.add_argument('--process-helper', type=Path, help='Already built optional ce_process_scope for owned descendant cancellation')
    parser.add_argument('--ripgrep', type=Path, help='Already installed ripgrep for structured project-search checks')
    parser.add_argument('--recipe-checkout', type=Path, help='Actual RE35 checkout for opt-in declared CMake task checks')
    parser.add_argument('--cmake', type=Path)
    parser.add_argument('--ninja', type=Path)
    parser.add_argument('--cc', type=Path)
    parser.add_argument('--cxx', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--timeout', type=float, default=150)
    parser.add_argument('--invocation-only', action='store_true', help='Run only semantic invocation and real editor-bound command checks')
    args = parser.parse_args()
    if args.node and (not args.node.is_absolute() or not args.node.is_file()):
        parser.error('node must be an already installed absolute executable')
    if args.process_helper and (not args.process_helper.is_absolute() or not args.process_helper.is_file()):
        parser.error('process-helper must be an already built absolute executable')
    if args.ripgrep and (not args.ripgrep.is_absolute() or not args.ripgrep.is_file()):
        parser.error('ripgrep must be an already installed absolute executable')
    recipe_values = [args.recipe_checkout, args.cmake, args.ninja, args.cc, args.cxx]
    if any(recipe_values) and not all(recipe_values):
        parser.error('recipe-checkout, cmake, ninja, cc and cxx must be supplied together')
    if args.recipe_checkout and (not args.recipe_checkout.is_absolute() or not (args.recipe_checkout / 'CMakeLists.txt').is_file()):
        parser.error('recipe-checkout must be an existing absolute RE35 checkout')
    for value in recipe_values[1:]:
        if value and (not value.is_absolute() or not value.is_file()):
            parser.error('recipe tools must be already installed absolute executables')
    for label, value in [('code', args.code), ('helper', args.helper), ('Lua runtime', args.lua_runtime)]:
        if not value.is_absolute() or not value.is_file():
            parser.error(f'{label} must be an already installed/built absolute file')
    if not 10 <= args.timeout <= 600:
        parser.error('timeout must be 10–600 seconds')
    artifacts = ROOT / '.artifacts'
    destination = args.report.resolve()
    if not destination.is_relative_to(artifacts.resolve()) or destination.exists():
        parser.error('report must be a new path below this repository .artifacts')
    folder = artifacts / ('vscode-integration-' + uuid.uuid4().hex)
    source_root = folder / 'source'
    sources = [*sorted((ROOT / 'lua').rglob('*.lua')), *sorted((ROOT / 'hosts/vscode').glob('*.js')),
               ROOT / 'hosts/vscode/package.json', *sorted((ROOT / 'hosts/vscode/test').glob('*.js')),
               ROOT / 'tests/fixtures/presentation-inspection.json']
    hashes = {}
    for source in sources:
        relative = source.relative_to(ROOT)
        target = source_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        hashes[relative.as_posix()] = digest(target)
    native = folder / 'native'
    native.mkdir()
    binaries = {}
    for source in [args.helper, *([args.process_helper] if args.process_helper else []), *sorted(args.helper.parent.glob('*.dll')),
                   *sorted(args.helper.parent.glob('libcommand_environment*.so*')),
                   *sorted(args.helper.parent.glob('libcommand_environment*.dylib'))]:
        target = native / source.name
        shutil.copy2(source, target)
        binaries[source.name] = digest(target)
    workspace = folder / 'workspace'
    workspace.mkdir()
    settings = folder / 'user-data/User'
    settings.mkdir(parents=True)
    (settings / 'settings.json').write_text(json.dumps({'files.autoSave': 'off', 'update.mode': 'none',
        'telemetry.telemetryLevel': 'off', 'extensions.autoUpdate': False,
        'extensions.autoCheckUpdates': False}) + '\n', encoding='utf-8')
    environment = os.environ.copy()
    environment.pop('ELECTRON_RUN_AS_NODE', None)
    environment.pop('RE35_TEST_INVOCATION_ONLY', None)
    if args.invocation_only:
        environment['RE35_TEST_INVOCATION_ONLY'] = '1'
    environment.update(RE35_HOST_TEST_DIR=str(workspace), RE35_TEST_HELPER=str(native / args.helper.name),
                       RE35_TEST_LUA_RUNTIME=str(args.lua_runtime), RE35_TEST_CORE=str(source_root / 'lua'))
    environment.pop('RE35_TEST_NODE', None)
    environment.pop('RE35_TEST_PROCESS_HELPER', None)
    environment.pop('RE35_TEST_RIPGREP', None)
    environment.pop('RE35_RECIPE_CHECKOUT', None)
    if args.node:
        environment['RE35_TEST_NODE'] = str(args.node)
    if args.process_helper:
        environment['RE35_TEST_PROCESS_HELPER'] = str(native / args.process_helper.name)
    if args.ripgrep:
        environment['RE35_TEST_RIPGREP'] = str(args.ripgrep)
    recipe_hashes = {}
    if args.recipe_checkout:
        checkout = args.recipe_checkout.resolve()
        recipe_artifacts = checkout / '.artifacts'
        recipe_artifacts.mkdir(exist_ok=True)
        if (recipe_artifacts.is_symlink() or getattr(recipe_artifacts.lstat(), 'st_file_attributes', 0) & 0x400
                or recipe_artifacts.resolve().parent != checkout):
            parser.error('recipe artifact directory must physically remain inside the checkout')
        recipe_sources = [checkout / 'CMakeLists.txt', *sorted((checkout / 'native').rglob('*')),
                          *sorted((checkout / 'examples/cpp').rglob('*')), checkout / 'examples/re35-development.json',
                          checkout / 'examples/command.json',
                          *sorted((checkout / 'lua/command_environment/core').rglob('*.lua'))]
        recipe_hashes = {file.relative_to(checkout).as_posix(): digest(file) for file in recipe_sources if file.is_file()}
        environment.update(RE35_RECIPE_CHECKOUT=str(checkout), RE35_RECIPE_BUILD=str(checkout / '.artifacts' / ('task-build-' + uuid.uuid4().hex)),
            RE35_RECIPE_CMAKE=str(args.cmake), RE35_RECIPE_NINJA=str(args.ninja), RE35_RECIPE_CC=str(args.cc), RE35_RECIPE_CXX=str(args.cxx))
    arguments = [str(args.code), f'--user-data-dir={settings.parent}', f'--extensions-dir={folder / "extensions"}',
        f'--extensionDevelopmentPath={source_root / "hosts/vscode"}',
        f'--extensionTestsPath={source_root / "hosts/vscode/test/extension.js"}',
        '--disable-extensions', '--disable-updates', '--disable-telemetry', '--disable-gpu',
        '--skip-welcome', '--skip-release-notes', '--disable-workspace-trust', str(workspace)]
    startup = None
    if os.name == 'nt':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
    report = {'format': 1, 'created_utc': datetime.now(timezone.utc).isoformat(),
        'evidence': 'actual VS Code Extension Development Host API integration', 'passed': False,
        'source_sha256': hashes, 'binary_sha256': binaries, 'runner_sha256': digest(Path(__file__)),
        'lua_runtime_sha256': digest(args.lua_runtime), 'code_executable_sha256': digest(args.code),
        'artifact_directory': folder.relative_to(ROOT).as_posix(), 'physical_gestures_measured': False,
        'recipe_checkout_source_sha256': recipe_hashes}
    if args.process_helper:
        report['process_helper_sha256'] = digest(args.process_helper)
    external_tools = {name: value for name, value in [('node', args.node), ('ripgrep', args.ripgrep), ('cmake', args.cmake),
        ('ninja', args.ninja), ('cc', args.cc), ('cxx', args.cxx)] if value}
    report['external_tool_sha256'] = {name: digest(value) for name, value in external_tools.items()}
    try:
        with (folder / 'stdout.log').open('wb') as stdout, (folder / 'stderr.log').open('wb') as stderr:
            process = subprocess.Popen(arguments, env=environment, stdout=stdout, stderr=stderr, startupinfo=startup)
            try:
                code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                if os.name == 'nt':
                    subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
                else:
                    process.kill()
                process.wait(timeout=10)
                raise RuntimeError('Owned isolated VS Code integration host timed out')
        sample = json.loads((workspace / 'vscode-report.json').read_text(encoding='utf-8'))
        report['fixture'] = sample
        report['exit_code'] = code
        report['snapshot_source_unchanged'] = hashes == {name: digest(source_root / name) for name in hashes}
        report['snapshot_binaries_unchanged'] = binaries == {name: digest(native / name) for name in binaries}
        report['external_tools_unchanged'] = report['external_tool_sha256'] == {name: digest(value) for name, value in external_tools.items()}
        if recipe_hashes:
            report['recipe_checkout_source_unchanged'] = recipe_hashes == {name: digest(args.recipe_checkout / name) for name in recipe_hashes}
        report['passed'] = code == 0 and sample.get('passed') is True and report['snapshot_source_unchanged'] and report['snapshot_binaries_unchanged'] and report['external_tools_unchanged'] and report.get('recipe_checkout_source_unchanged', True)
        if not report['passed']:
            report['error'] = sample.get('error', 'Integration host or immutable snapshot verification failed')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({key: report.get(key) for key in ['passed', 'fixture', 'error']}, ensure_ascii=False))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
