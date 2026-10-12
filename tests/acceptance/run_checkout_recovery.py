#!/usr/bin/env python3
"""Actual RE35 compiler recovery in a disposable source copy; no human trial."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nvim', default='nvim')
    parser.add_argument('--cmake', default='cmake')
    parser.add_argument('--cc', default='gcc')
    parser.add_argument('--cxx', default='g++')
    parser.add_argument('--ninja', default='ninja')
    parser.add_argument('--lua-runtime', required=True)
    parser.add_argument('--report', type=Path, default=Path('.artifacts/usage/checkout-recovery.json'))
    args = parser.parse_args()
    binaries = {}
    for key in ('nvim', 'cmake', 'cc', 'cxx', 'ninja'):
        binaries[key] = shutil.which(getattr(args, key))
        if not binaries[key]:
            parser.error('Missing installed prerequisite: ' + key)
    destination = (ROOT / args.report).resolve()
    artifacts = (ROOT / '.artifacts').resolve()
    if not artifacts.is_relative_to(ROOT.resolve()) or not destination.is_relative_to(artifacts) or destination.suffix != '.json':
        parser.error('Report must be a JSON file inside repository .artifacts')
    if destination.exists():
        parser.error('Use a fresh report path; existing evidence is preserved')
    destination.parent.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('fixture_runner', ROOT / 'tests/run.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    before = runner.runtime_manifest()
    copied = {}
    with tempfile.TemporaryDirectory(prefix='checkout-recovery-', dir=artifacts) as temporary:
        checkout = Path(temporary) / 'RE35'
        checkout.mkdir()
        # Copy only source roots used by the actual CMake project and driver.
        # Refuse symlinks rather than following paths outside the checkout.
        for name in ('lua', 'native', 'examples', 'tests'):
            for path in (ROOT / name).rglob('*'):
                if '__pycache__' in path.parts:
                    continue
                if path.is_symlink():
                    raise ValueError('Source symlinks are not allowed in this probe: ' + str(path))
                if path.is_file():
                    relative = path.relative_to(ROOT)
                    target = checkout / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
                    copied[relative.as_posix()] = runner.digest(path)
        for name in ('CMakeLists.txt', 'LICENSE'):
            source = ROOT / name
            if source.is_symlink():
                raise ValueError('Source symlinks are not allowed')
            shutil.copyfile(source, checkout / name)
            copied[name] = runner.digest(source)
        flags = ['--cmake', binaries['cmake'], '--generator', 'Ninja', '--c-compiler', binaries['cc'],
                 '--cxx-compiler', binaries['cxx'], '--make-program', binaries['ninja'],
                 '--lua-runtime', args.lua_runtime, '--native-namespace', 'compiler-recovery']
        os.environ.update(RE35_RECOVERY_COPY=checkout.as_posix(), RE35_RECOVERY_PYTHON=sys.executable,
                          RE35_RECOVERY_FLAGS=json.dumps(flags))
        result = runner.run_fixture(binaries['nvim'], ROOT / 'tests/acceptance/checkout_recovery.lua', 240, 131072)
        observation = None
        for line in result['output'].splitlines():
            if line.startswith('RE35_CHECKOUT_RECOVERY:'):
                observation = json.loads(line.split(':', 1)[1])
        unchanged = before == runner.runtime_manifest() and all(runner.digest(ROOT / path) == digest for path, digest in copied.items())
        report = dict(evidence='actual RE35 checkout copy compiler recovery; no human observation',
                      runtime_source_sha256=before, copied_source_sha256=copied,
                      source_unchanged=unchanged, tools=binaries, result=result, observation=observation,
                      fixture_sha256=runner.digest(ROOT / 'tests/acceptance/checkout_recovery.lua'),
                      runner_sha256=runner.digest(Path(__file__)))
        destination.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(result['status'].upper(), 'actual checkout recovery; original sources unchanged:', unchanged)
    if result['status'] != 'passed':
        print(result['output'])
    return 0 if result['status'] == 'passed' and unchanged and observation else 1


if __name__ == '__main__':
    sys.exit(main())
