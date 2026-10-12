#!/usr/bin/env python3
"""Exercise the actual native FIFO helper; no Neovim or third-party modules."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('helper')
parser.add_argument('runtime')
parser.add_argument('core')
args = parser.parse_args()
command = [args.helper, args.runtime, args.core]
checks = 0

def check(condition):
    global checks
    assert condition
    checks += 1

def frame(operation, data):
    return (operation + '\t' + json.dumps(data, ensure_ascii=True, separators=(',', ':')) + '\n').encode('utf-8')

snapshot = {'uri': 'file:///project/document', 'revision': '1', 'encoding': 'utf-16',
            'lines': ['😀 한글 needle needle', 'needle']}
requests = b''.join([
    frame('document_search', {'snapshot': snapshot, 'query': 'needle'}),
    frame('document_search', {'snapshot': snapshot, 'query': '\ud800'}),
    frame('document_prepare_replace', {'snapshot': snapshot, 'find': 'needle', 'replace': '새😀'}),
    frame('snapshot', {}),
])
result = subprocess.run(command, input=requests, capture_output=True, timeout=10)
check(result.returncode == 0)
responses = [json.loads(line) for line in result.stdout.decode('utf-8').splitlines()]
check(len(responses) == 4)
check(responses[0]['ok'] and len(responses[0]['value']['locations']) == 3)
check(responses[0]['value']['locations'][0]['range']['start'] == {'line': 0, 'character': 6})
check(not responses[1]['ok'])
check(responses[2]['ok'] and responses[2]['value']['match_count'] == 3)
check(responses[3]['ok'] and responses[3]['value']['protocol_version'] == 1)
plan = responses[2]['value']
requests = frame('document_apply', {'snapshot': snapshot, 'plan': plan})
result = subprocess.run(command, input=requests, capture_output=True, timeout=10)
check(result.returncode == 0 and json.loads(result.stdout)['value'] == ['😀 한글 새😀 새😀', '새😀'])
for invalid in [b'snapshot\t{}', b'bad operation\t{}\n', b'snapshot\t\0\n', b'snapshot\t' + b'x' * 1048642 + b'\n']:
    result = subprocess.run(command, input=invalid, capture_output=True, timeout=10)
    check(result.returncode != 0 and not result.stdout)

if os.name == 'nt':
    # Real Windows argv and file opening, separate from escaped JSON strings.
    temp_parent = Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix='re35-stdio-', dir=temp_parent) as directory:
        fixture = Path(directory).resolve()
        if fixture.parent != temp_parent:
            raise RuntimeError('The isolated argv fixture escaped its temporary parent')
        runtime = fixture / ' leading 런타임😀 with spaces.dll'
        core = fixture / '核心 🧭 with spaces' / 'lua'
        shutil.copyfile(args.runtime, runtime)
        definition = Path(__file__).resolve().parent.parent / 'native' / 'core_modules.def'
        modules = re.findall(r'CE_CORE_MODULE\("[^\"]+", "([^\"]+)"\)', definition.read_text(encoding='utf-8'))
        if not modules:
            raise RuntimeError('The approved core module fixture is empty')
        for module in modules:
            destination = core / module
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(args.core) / module, destination)
        control = frame('document_search', {'snapshot': snapshot, 'query': 'needle'}) + frame('snapshot', {})
        for selected_core in (str(core), str(core) + os.sep):
            result = subprocess.run([args.helper, str(runtime), selected_core], input=control,
                                    capture_output=True, timeout=10)
            check(result.returncode == 0)
            values = [json.loads(line) for line in result.stdout.decode('utf-8').splitlines()]
            check(len(values) == 2 and values[0]['ok'] and len(values[0]['value']['locations']) == 3
                  and values[0]['value']['locations'][0]['range']['start'] == {'line': 0, 'character': 6}
                  and values[1]['ok'] and values[1]['value']['protocol_version'] == 1)
        refused = [[], [str(runtime)], [str(runtime), str(core), 'extra'], ['', str(core)], [str(runtime), '']]
        # CPython passes these lone surrogates via CreateProcessW without Node/V8 normalization.
        for surrogate in ('\ud800', '\udfff'):
            refused.extend(([str(runtime) + surrogate, str(core)], [str(runtime), str(core) + surrogate]))
        for arguments in refused:
            result = subprocess.run([args.helper, *arguments], input=control, capture_output=True, timeout=10)
            check(result.returncode == 2 and not result.stdout)
print(json.dumps({'passed': True, 'checks': checks, 'host': 'native FIFO/core document integration'}))
