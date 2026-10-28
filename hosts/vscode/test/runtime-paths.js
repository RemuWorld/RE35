'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { resolveRuntimePaths } = require('../runtime-paths');

function run() {
  let checks = 0;
  const equal = (a, b) => { assert.deepEqual(a, b); ++checks; };
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 're35-runtime-paths-'));
  try {
    const extension = path.join(folder, 'hosts', 'vscode');
    const options = { helperPath: path.join(folder, 'ce_stdio'), luaRuntime: path.join(folder, 'lua51') };
    equal(resolveRuntimePaths(extension, options), { ...options, corePath: path.join(folder, 'lua'), processHelper: undefined });
    const installed = path.join(extension, 'resources', 'lua');
    const bridge = path.join(installed, 'command_environment', 'core', 'bridge.lua');
    fs.mkdirSync(path.dirname(bridge), { recursive: true });
    fs.writeFileSync(bridge, '-- synthetic source marker\n');
    equal(resolveRuntimePaths(extension, options), { ...options, corePath: installed, processHelper: undefined });
    equal(resolveRuntimePaths(extension, { ...options, corePath: path.join(folder, 'custom') }).corePath,
      path.join(folder, 'custom'));
    equal(resolveRuntimePaths(extension).helperPath, undefined);
    equal(resolveRuntimePaths(extension).luaRuntime, undefined);
    equal(resolveRuntimePaths(extension, { corePath: '' }).corePath, installed);
    assert.throws(() => resolveRuntimePaths('relative'), /absolute/); ++checks;
    assert.throws(() => resolveRuntimePaths(extension + '\0'), /absolute/); ++checks;
    const native = path.join(extension, 'resources', 'native', process.platform + '-' + process.arch);
    fs.mkdirSync(native, { recursive: true });
    for (const filename of ['ce_stdio.exe', 'lua51.dll', 'ce_process_scope.exe']) fs.writeFileSync(path.join(native, filename), 'fixture');
    if (process.platform === 'win32' && process.arch === 'x64') {
      equal(resolveRuntimePaths(extension), { corePath: installed, helperPath: path.join(native, 'ce_stdio.exe'),
        luaRuntime: path.join(native, 'lua51.dll'), processHelper: path.join(native, 'ce_process_scope.exe') });
      equal(resolveRuntimePaths(extension, { ...options, processHelper: path.join(folder, 'owned-helper') }),
        { ...options, corePath: installed, processHelper: path.join(folder, 'owned-helper') });
      fs.unlinkSync(path.join(native, 'ce_process_scope.exe'));
      equal(resolveRuntimePaths(extension).processHelper, undefined);
    } else {
      equal(resolveRuntimePaths(extension).helperPath, undefined);
      equal(resolveRuntimePaths(extension).luaRuntime, undefined);
      equal(resolveRuntimePaths(extension).processHelper, undefined);
    }
    return { passed: true, checks, scope: 'installed/source core and platform native resolution; explicit path precedence' };
  } finally { fs.rmSync(folder, { recursive: true, force: true }); }
}
if (require.main === module) console.log(JSON.stringify(run()));
module.exports = { run };
