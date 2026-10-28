#!/usr/bin/env python3
"""Verify the VSIX structure, reproducibility and exclusion of private/test data."""
from __future__ import annotations
import io
import json
from pathlib import Path
import sys
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import package_vscode
import prepare_source


class VscodePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise current source bytes without modifying the approved policy;
        # the public packager itself separately enforces that policy.
        cls.contents = {name: prepare_source.read_source(prepare_source.ROOT / name)[0]
                        for name in prepare_source.inventory()}

    def test_archive(self):
        files = package_vscode.entries(self.contents)
        first = package_vscode.archive(files)
        self.assertEqual(first, package_vscode.archive(dict(reversed(list(files.items())))))
        with zipfile.ZipFile(io.BytesIO(first)) as archive:
            self.assertEqual(archive.namelist(), sorted(files))
            self.assertEqual(len(archive.namelist()), len(set(archive.namelist())))
            self.assertIn('extension/runtime-paths.js', files)
            self.assertIn('extension/resources/lua/command_environment/core/bridge.lua', files)
            self.assertIn('extension/runtime/editing.lua',files)
            self.assertIn('extension/runtime/input.lua',files)
            self.assertIn('extension/docs/install.md',files)
            self.assertIn('extension/docs/README.md',files)
            self.assertIn('extension/resources/lua/command_tree/editing/init.lua',files)
            self.assertNotIn('extension/resources/lua/command_tree/editing/host.lua',files)
            self.assertEqual(json.loads(archive.read('extension/package.json')),
                             json.loads(self.contents['hosts/vscode/package.json']))
            self.assertTrue(all('/test/' not in name and not name.endswith(('.exe', '.dll', '.so'))
                                for name in archive.namelist()))
            self.assertTrue(all(not name.startswith(('tests/', 'docs/', '.git/', 'lua/command_tree/'))
                                for name in archive.namelist()))
            core = {name.removeprefix('extension/resources/') for name in files
                    if name.startswith('extension/resources/lua/')}
            self.assertEqual(core, {name for name in self.contents if name.startswith('lua/command_environment/core/')}
                             | {'lua/command_tree/editing/init.lua'})
            manifest = ET.fromstring(archive.read('extension.vsixmanifest'))
            ns = {'v': 'http://schemas.microsoft.com/developer/vsx-schema/2011'}
            self.assertEqual(manifest.find('v:Metadata/v:Identity', ns).attrib['Id'], 're35-desktop')
            self.assertEqual(manifest.find('v:Assets/v:Asset', ns).attrib['Path'], 'extension/package.json')

    def test_incomplete_loader_refused(self):
        missing = dict(self.contents)
        missing.pop('lua/command_environment/core/invocation.lua')
        with self.assertRaisesRegex(ValueError, 'manifest'):
            package_vscode.entries(missing)

    def test_vscode_release_keeps_legacy_version(self):
        contents = dict(self.contents)
        manifest = json.loads(contents['hosts/vscode/package.json'])
        manifest['version'] = '0.5.0'
        contents['hosts/vscode/package.json'] = json.dumps(manifest).encode()
        contents['lua/command_tree/init.lua'] = b"local M = { version = '0.4.0' }\nreturn M\n"
        self.assertEqual(prepare_source.validate_sources(contents), '0.5.0')
        files = package_vscode.entries(contents)
        identity = ET.fromstring(files['extension.vsixmanifest']).find(
            '{http://schemas.microsoft.com/developer/vsx-schema/2011}Metadata/'
            '{http://schemas.microsoft.com/developer/vsx-schema/2011}Identity')
        self.assertEqual(identity.attrib['Version'], '0.5.0')
        contents['hosts/vscode/package.json'] = b'[]'
        with self.assertRaisesRegex(ValueError, 'must be an object'):
            prepare_source.validate_sources(contents)

    def test_installed_documentation_links(self):
        contents = {
            'LICENSE': b'License',
            'hosts/vscode/README.md': b'[Install](../../docs/install.md#setup)\n[Source](../../native/ce.h)\n',
            'docs/install.md': b'[Home](../hosts/vscode/README.md)\n[Core][core]\n[core]: reference/core.md "Core"\n',
            'docs/reference/core.md': b'[License](../../LICENSE)\n',
            'native/ce.h': b'/* source only */',
        }
        files = {}
        package_vscode.package_documentation(contents, files, '0.5.0')
        self.assertIn(b'](docs/install.md#setup)', files['extension/README.md'])
        self.assertIn(b'https://github.com/RemuWorld/RE35/blob/v0.5.0/native/ce.h', files['extension/README.md'])
        self.assertIn(b'](../README.md)', files['extension/docs/install.md'])
        self.assertIn(b'[core]: reference/core.md "Core"', files['extension/docs/install.md'])
        self.assertIn(b'](../../LICENSE)', files['extension/docs/reference/core.md'])
        self.assertNotIn('extension/native/ce.h', files)
        for target in ('../../missing.md', '../../../private.txt', '/absolute-local.txt'):
            changed = dict(contents)
            changed['hosts/vscode/README.md'] = ('[Bad](' + target + ')').encode()
            with self.assertRaisesRegex(ValueError, 'outside the reviewed source'):
                package_vscode.package_documentation(changed, {}, '0.5.0')
        for target in ('file:///private/local.txt', 'C:/Users/example/local.txt', 'vscode://file/private.txt'):
            changed = dict(contents)
            changed['hosts/vscode/README.md'] = ('[Bad](' + target + ')').encode()
            with self.assertRaisesRegex(ValueError, 'non-public link scheme'):
                package_vscode.package_documentation(changed, {}, '0.5.0')

    def test_missing_resolver_refused(self):
        missing = dict(self.contents)
        missing.pop('hosts/vscode/runtime-paths.js')
        with self.assertRaisesRegex(ValueError, 'resolver'):
            package_vscode.entries(missing)

    def test_missing_editing_runtime_refused(self):
        for name in ('hosts/vscode/runtime/editing.lua','lua/command_tree/editing/init.lua'):
            missing=dict(self.contents);missing.pop(name)
            with self.assertRaisesRegex(ValueError,'editing runtime'):
                package_vscode.entries(missing)

    def test_missing_input_runtime_refused(self):
        missing = dict(self.contents)
        missing.pop('hosts/vscode/runtime/input.lua')
        with self.assertRaisesRegex(ValueError, 'input runtime'):
            package_vscode.entries(missing)

    def test_platform_inputs(self):
        def pe(dll=False, machine=0x8664):
            content = bytearray(128)
            content[:2] = b'MZ'
            struct.pack_into('<I', content, 0x3c, 64)
            content[64:68] = b'PE\0\0'
            struct.pack_into('<H', content, 68, machine)
            struct.pack_into('<H', content, 86, 0x2000 if dll else 0)
            return bytes(content)
        with tempfile.TemporaryDirectory(prefix='re35-native-package-') as folder:
            root = Path(folder).absolute()
            (root / 'ce_stdio.exe').write_bytes(pe())
            (root / 'command_environment.dll').write_bytes(pe(True))
            (root / 'runtime.dll').write_bytes(pe(True))
            (root / 'COPYRIGHT').write_text('Synthetic runtime copyright/license fixture.\n', encoding='utf-8')
            native = package_vscode.native_entries(root, root / 'runtime.dll', root / 'COPYRIGHT', 'win32-x64')
            prefix = 'extension/resources/native/win32-x64/'
            self.assertEqual(set(native), {prefix + name for name in ('ce_stdio.exe', 'command_environment.dll', 'lua51.dll', 'COPYRIGHT')})
            packed = package_vscode.entries(self.contents, native, 'win32-x64')
            identity = ET.fromstring(packed['extension.vsixmanifest']).find(
                '{http://schemas.microsoft.com/developer/vsx-schema/2011}Metadata/'
                '{http://schemas.microsoft.com/developer/vsx-schema/2011}Identity')
            self.assertEqual(identity.attrib['TargetPlatform'], 'win32-x64')
            self.assertEqual(packed[prefix + 'COPYRIGHT'], (root / 'COPYRIGHT').read_bytes())
            (root / 'ce_process_scope.exe').write_bytes(pe())
            self.assertIn(prefix + 'ce_process_scope.exe', package_vscode.native_entries(
                root, root / 'runtime.dll', root / 'COPYRIGHT', 'win32-x64'))
            (root / 'runtime.dll').write_bytes(pe(True, 0x14c))
            with self.assertRaisesRegex(ValueError, 'not Windows x64'):
                package_vscode.native_entries(root, root / 'runtime.dll', root / 'COPYRIGHT', 'win32-x64')
            (root / 'runtime.dll').write_bytes(pe())
            with self.assertRaisesRegex(ValueError, 'type differs'):
                package_vscode.native_entries(root, root / 'runtime.dll', root / 'COPYRIGHT', 'win32-x64')
            (root / 'runtime.dll').write_bytes(pe(True))
            (root / 'COPYRIGHT').write_bytes(b' ')
            with self.assertRaisesRegex(ValueError, 'copyright/license'):
                package_vscode.native_entries(root, root / 'runtime.dll', root / 'COPYRIGHT', 'win32-x64')
            with self.assertRaisesRegex(ValueError, 'only win32-x64'):
                package_vscode.native_entries(root, root / 'runtime.dll', root / 'COPYRIGHT', 'linux-x64')
            with self.assertRaisesRegex(ValueError, 'requires all native inputs'):
                package_vscode.entries(self.contents, target='win32-x64')


if __name__ == '__main__':
    unittest.main()
