#!/usr/bin/env python3
"""Prepare a local VSIX, optionally bundling reviewed Windows x64 native inputs."""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import posixpath
import re
import stat
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import quote, unquote, urlsplit, urlunsplit

import prepare_source as source


def package_documentation(contents: dict[str, bytes], files: dict[str, bytes], version: str) -> None:
    """Keep installed guides navigable; checkout-only links point to this tag."""
    locations = {'hosts/vscode/README.md': 'extension/README.md', 'LICENSE': 'extension/LICENSE'}
    locations.update({name: 'extension/' + name for name in contents
                      if name.startswith('docs/') and name.endswith('.md')})
    for name, target in locations.items():
        if name == 'LICENSE':
            continue
        content = contents[name].decode('utf-8')

        def link(raw: str) -> str:
            wrapped = raw.startswith('<') and raw.endswith('>')
            destination = raw[1:-1] if wrapped else raw
            parsed = urlsplit(destination)
            if parsed.scheme and parsed.scheme.casefold() not in {'https', 'http', 'mailto'}:
                raise ValueError('Documentation uses a non-public link scheme: ' + name)
            if parsed.scheme or parsed.netloc or not parsed.path:
                return raw
            path = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(parsed.path)))
            if parsed.path.startswith('/') or path.startswith('../') or path not in contents:
                raise ValueError('Documentation link is outside the reviewed source: ' + name + ' -> ' + destination)
            if path in locations:
                rewritten = posixpath.relpath(locations[path], posixpath.dirname(target))
                result = urlunsplit(('', '', quote(rewritten, safe='/.-_'), parsed.query, parsed.fragment))
            else:
                result = 'https://github.com/RemuWorld/RE35/blob/v' + quote(version, safe='.-_') + '/' + quote(path, safe='/.-_')
                if parsed.query:
                    result += '?' + parsed.query
                if parsed.fragment:
                    result += '#' + parsed.fragment
            return '<' + result + '>' if wrapped else result

        # Both inline and reference-style links retain their original labels and
        # titles. Source-only examples are linked, never copied into the VSIX.
        content = re.sub(r'(\]\()(<[^>\r\n]+>|[^\s)\r\n]+)([^)\r\n]*\))',
                         lambda match: match[1] + link(match[2]) + match[3], content)
        content = re.sub(r'(?m)^(\s{0,3}\[[^\]\r\n]+\]:\s*)(<[^>\r\n]+>|\S+)([^\r\n]*)$',
                         lambda match: match[1] + link(match[2]) + match[3], content)
        files[target] = content.encode('utf-8')


def read_native_input(filename: Path) -> bytes:
    before = source.identity(source.guard(filename))
    if before[3] > source.MAX_FILE:
        raise ValueError('Native packaging input exceeds 8 MiB')
    # Windows Python builds can infer executable permission bits from an .exe
    # pathname but not an open handle. Compare file type, identity and bytes;
    # retain each API's complete metadata checks before and after the read.
    common = lambda info: (info[0], info[1], stat.S_IFMT(info[2]), info[3], info[4])
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(filename, flags), 'rb') as stream:
        opened = source.identity(os.fstat(stream.fileno()))
        if common(before) != common(opened):
            raise ValueError('Native input identity changed before reading')
        data = stream.read(source.MAX_FILE + 1)
        if source.identity(os.fstat(stream.fileno())) != opened:
            raise ValueError('Native input changed during reading')
    if len(data) > source.MAX_FILE or source.identity(source.guard(filename)) != before:
        raise ValueError('Native input changed during reading')
    return data


def native_entries(native_dir: Path, lua_runtime: Path, runtime_license: Path, target: str) -> dict[str, bytes]:
    if target != 'win32-x64':
        raise ValueError('Bundled native target currently supports only win32-x64')
    for value in (native_dir, lua_runtime, runtime_license):
        if not value.is_absolute():
            raise ValueError('Native inputs must be explicit absolute paths')
    source.guard(native_dir, True)
    inputs = {'ce_stdio.exe': native_dir / 'ce_stdio.exe',
              'command_environment.dll': native_dir / 'command_environment.dll', 'lua51.dll': lua_runtime}
    process = native_dir / 'ce_process_scope.exe'
    if process.exists() or process.is_symlink():
        inputs['ce_process_scope.exe'] = process
    files = {}
    for name, filename in inputs.items():
        data = read_native_input(filename)
        if len(data) < 64 or data[:2] != b'MZ':
            raise ValueError(f'Native input is not a PE binary: {name}')
        offset = struct.unpack_from('<I', data, 0x3c)[0]
        if offset > len(data) - 24 or data[offset:offset + 4] != b'PE\0\0' or struct.unpack_from('<H', data, offset + 4)[0] != 0x8664:
            raise ValueError(f'Native input is not Windows x64: {name}')
        is_dll = bool(struct.unpack_from('<H', data, offset + 22)[0] & 0x2000)
        if is_dll != name.endswith('.dll'):
            raise ValueError(f'Native PE executable/library type differs: {name}')
        files['extension/resources/native/' + target + '/' + name] = data
    notice = read_native_input(runtime_license)
    if not notice.strip() or len(notice) > 65536:
        raise ValueError('Runtime copyright/license must be nonempty and at most 64 KiB')
    notice.decode('utf-8')
    files['extension/resources/native/' + target + '/COPYRIGHT'] = notice
    return files


def entries(contents: dict[str, bytes], native: dict[str, bytes] | None = None, target: str | None = None) -> dict[str, bytes]:
    """Package the reviewed host sources and exact shared native-core manifest."""
    version = source.validate_sources(contents)
    package = json.loads(contents['hosts/vscode/package.json'].decode('utf-8'))
    for field in ('name', 'publisher', 'displayName', 'description'):
        if not isinstance(package.get(field), str) or not package[field]:
            raise ValueError(f'VS Code package requires {field}')
    files = {'extension/LICENSE': contents['LICENSE'],
             'extension/README.md': contents['hosts/vscode/README.md']}
    package_documentation(contents, files, version)
    for name, data in contents.items():
        if (name.startswith('hosts/vscode/') and name.count('/') == 2
                and (name.endswith('.js') or name == 'hosts/vscode/package.json')):
            files['extension/' + name.removeprefix('hosts/vscode/')] = data
        elif name.startswith('lua/command_environment/core/') and name.endswith('.lua'):
            files['extension/resources/' + name] = data
        elif name == 'lua/command_tree/editing/init.lua':
            # Only the bounded native executor belongs inside embedded Neovim.
            # Terminal UI, setup, themes and language services remain outside.
            files['extension/resources/' + name] = data
        elif name in {'hosts/vscode/runtime/editing.lua', 'hosts/vscode/runtime/input.lua'}:
            files['extension/' + name.removeprefix('hosts/vscode/')] = data
    if 'extension/runtime-paths.js' not in files:
        raise ValueError('Installed core resolver is missing')
    if not {'extension/runtime/editing.lua','extension/resources/lua/command_tree/editing/init.lua',
            'extension/resources/lua/command_environment/core/editing.lua'} <= files.keys():
        raise ValueError('Bounded native editing runtime is incomplete')
    if 'extension/runtime/input.lua' not in files:
        raise ValueError('Continuous input runtime is incomplete')
    if native is not None:
        prefix = 'extension/resources/native/win32-x64/'
        allowed = {prefix + name for name in ('ce_stdio.exe', 'command_environment.dll', 'ce_process_scope.exe', 'lua51.dll', 'COPYRIGHT')}
        required = allowed - {prefix + 'ce_process_scope.exe'}
        if target != 'win32-x64' or not required <= native.keys() or not native.keys() <= allowed:
            raise ValueError('Unexpected platform package inputs')
        files.update(native)
    elif target is not None:
        raise ValueError('A platform target requires all native inputs')

    namespace = 'http://schemas.microsoft.com/developer/vsx-schema/2011'
    ET.register_namespace('', namespace)
    def element(parent, name, attributes=None, text=None):
        node = ET.SubElement(parent, '{' + namespace + '}' + name, attributes or {})
        node.text = text
        return node
    manifest = ET.Element('{' + namespace + '}PackageManifest', {'Version': '2.0.0'})
    metadata = element(manifest, 'Metadata')
    identity = {'Language': 'en-US', 'Id': package['name'], 'Version': version, 'Publisher': package['publisher']}
    if target:
        identity['TargetPlatform'] = target
    element(metadata, 'Identity', identity)
    element(metadata, 'DisplayName', text=package['displayName'])
    element(metadata, 'Description', {'{http://www.w3.org/XML/1998/namespace}space': 'preserve'}, package['description'])
    element(metadata, 'License', text='extension/LICENSE')
    properties = element(metadata, 'Properties')
    element(properties, 'Property', {'Id': 'Microsoft.VisualStudio.Code.Engine', 'Value': package['engines']['vscode']})
    element(properties, 'Property', {'Id': 'Microsoft.VisualStudio.Code.ExtensionKind', 'Value': 'workspace'})
    installation = element(manifest, 'Installation')
    element(installation, 'InstallationTarget', {'Id': 'Microsoft.VisualStudio.Code'})
    element(manifest, 'Dependencies')
    assets = element(manifest, 'Assets')
    for kind, filename in [('Microsoft.VisualStudio.Code.Manifest', 'extension/package.json'),
                           ('Microsoft.VisualStudio.Services.Content.Details', 'extension/README.md'),
                           ('Microsoft.VisualStudio.Services.Content.License', 'extension/LICENSE')]:
        element(assets, 'Asset', {'Type': kind, 'Path': filename, 'Addressable': 'true'})
    files['extension.vsixmanifest'] = ET.tostring(manifest, encoding='utf-8', xml_declaration=True)

    types_namespace = 'http://schemas.openxmlformats.org/package/2006/content-types'
    types = ET.Element('Types', {'xmlns': types_namespace})
    for extension, content_type in [('json', 'application/json'), ('js', 'application/javascript'),
                                    ('lua', 'text/plain'), ('md', 'text/markdown'),
                                    ('vsixmanifest', 'text/xml'), ('exe', 'application/octet-stream'),
                                    ('dll', 'application/octet-stream')]:
        ET.SubElement(types, 'Default', {'Extension': extension, 'ContentType': content_type})
    ET.SubElement(types, 'Override', {'PartName': '/extension/LICENSE', 'ContentType': 'text/plain'})
    if native:
        ET.SubElement(types, 'Override', {'PartName': '/extension/resources/native/' + target + '/COPYRIGHT', 'ContentType': 'text/plain'})
    files['[Content_Types].xml'] = ET.tostring(types, encoding='utf-8', xml_declaration=True)
    return files


def archive(files: dict[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as packed:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            packed.writestr(info, data)
    return output.getvalue()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New .vsix file outside reviewed source directories')
    parser.add_argument('--native-dir', type=Path, help='Existing absolute build directory with helper and bridge library')
    parser.add_argument('--lua-runtime', type=Path, help='Explicit existing Lua 5.1 ABI DLL for the platform package')
    parser.add_argument('--runtime-license', type=Path, help='Copyright and license notice accompanying that runtime')
    parser.add_argument('--target', choices=['win32-x64'], help='Native platform target; requires every native option')
    args = parser.parse_args()
    try:
        destination = Path(os.path.abspath(args.output))
        if destination.suffix.lower() != '.vsix':
            raise ValueError('Output must name a new .vsix file')
        if destination.is_relative_to(source.ROOT) and not destination.is_relative_to(source.ROOT / '.artifacts'):
            raise ValueError('Generated VSIX must stay outside reviewed source directories')
        if destination.exists() or destination.is_symlink():
            raise ValueError('Existing output is never replaced')
        source.guard(source.ROOT, True)
        policy, policy_identity = source.read_source(source.ROOT / source.POLICY)
        names = source.parse_policy(policy)
        contents, identities = {}, {}
        total = 0
        for name in names:
            data, identity = source.read_source(source.ROOT / name)
            total += len(data)
            if total > source.MAX_TOTAL:
                raise ValueError('Source packaging byte limit exceeded')
            contents[name], identities[name] = data, identity
        native_args = [args.native_dir, args.lua_runtime, args.runtime_license, args.target]
        if any(native_args) and not all(native_args):
            raise ValueError('native-dir, lua-runtime, runtime-license and target are required together')
        native = native_entries(*native_args) if all(native_args) else None
        packed = archive(entries(contents, native, args.target))
        if source.inventory() != names or source.read_source(source.ROOT / source.POLICY) != (policy, policy_identity):
            raise ValueError('Source policy changed during preparation')
        for name, data in contents.items():
            if source.read_source(source.ROOT / name) != (data, identities[name]):
                raise ValueError(f'Source changed during preparation: {name}')
        ancestor = destination.parent
        while not ancestor.exists():
            if ancestor.is_symlink():
                raise ValueError('Dangling output ancestor refused')
            ancestor = ancestor.parent
        source.guard(ancestor, True)
        destination.parent.mkdir(parents=True, exist_ok=True)
        source.guard(destination.parent, True)
        with destination.open('xb') as stream:
            stream.write(packed)
        print(f'Prepared local VSIX: {destination}')
        print(f'SHA-256: {source.digest(packed)}')
        if native:
            print(f'Bundled {args.target} helper, Lua runtime and its supplied copyright/license notice.')
        else:
            print('Native helper and compatible Lua 5.1 ABI runtime are required separately.')
        print('Nothing was installed or published.')
        return 0
    except (OSError, ValueError, UnicodeError, KeyError, zipfile.BadZipFile) as error:
        print(f'VSIX preparation refused: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
