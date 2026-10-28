'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Explicit machine-local paths override a platform package. A source-only VSIX
// still needs those settings; it never downloads executables or a Lua runtime.
function resolveRuntimePaths(extensionPath, options = {}) {
  if (typeof extensionPath !== 'string' || !path.isAbsolute(extensionPath) || extensionPath.includes('\0')) {
    throw new Error('RE35 extension location must be an absolute directory');
  }
  const installedCore = path.join(extensionPath, 'resources', 'lua');
  const corePath = options.corePath || (fs.existsSync(path.join(installedCore, 'command_environment', 'core', 'bridge.lua'))
    ? installedCore : path.resolve(extensionPath, '../../lua'));
  const native = path.join(extensionPath, 'resources', 'native', process.platform + '-' + process.arch);
  const bundled = filename => {
    const candidate = path.join(native, filename);
    return fs.existsSync(candidate) ? candidate : undefined;
  };
  const supported = process.platform === 'win32' && process.arch === 'x64';
  return { helperPath: options.helperPath || (supported ? bundled('ce_stdio.exe') : undefined),
    luaRuntime: options.luaRuntime || (supported ? bundled('lua51.dll') : undefined), corePath,
    processHelper: options.processHelper || (supported ? bundled('ce_process_scope.exe') : undefined) };
}

module.exports = { resolveRuntimePaths };
