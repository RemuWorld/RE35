#!/usr/bin/env python3
"""Explicit installed ripgrep integration; no installation or human evidence."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rg', default='rg')
    parser.add_argument('--nvim', default='nvim')
    parser.add_argument('--report', type=Path, default=Path('.artifacts/usage/ripgrep-integration.json'))
    args = parser.parse_args()
    rg, nvim = shutil.which(args.rg), shutil.which(args.nvim)
    if not rg or not nvim:
        parser.error('Explicit integration requires already installed rg and Neovim')
    destination = (ROOT / args.report).resolve()
    if destination.suffix != '.json' or not destination.is_relative_to((ROOT / '.artifacts').resolve()):
        parser.error('Report must be JSON inside repository .artifacts')
    if destination.exists():
        parser.error('Choose a fresh report path to preserve prior evidence')
    destination.parent.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('fixture_runner', ROOT / 'tests/run.py')
    runner = importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
    before = runner.runtime_manifest()
    os.environ['RE35_TEST_RG'] = rg
    result = runner.run_fixture(nvim, ROOT / 'tests/acceptance/ripgrep.lua', 60, 131072)
    unchanged = before == runner.runtime_manifest()
    destination.write_text(json.dumps(dict(evidence='installed ripgrep structured integration; no human observation',
        runtime_source_sha256=before,runtime_source_unchanged=unchanged,rg=rg,result=result,
        fixture_sha256=runner.digest(ROOT / 'tests/acceptance/ripgrep.lua'),runner_sha256=runner.digest(Path(__file__))),indent=2)+'\n',encoding='utf-8')
    print(result['status'].upper(), 'installed ripgrep; runtime unchanged:', unchanged)
    if result['status'] != 'passed':
        print(result['output'])
    return 0 if result['status'] == 'passed' and unchanged else 1


if __name__ == '__main__':
    sys.exit(main())
