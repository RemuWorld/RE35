'use strict';
// Host-owned execution. Optional native scope evidence covers the owned Job or
// process group; direct children never imply that descendants have stopped.
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { StringDecoder } = require('node:string_decoder');
const MAX_BYTES = 1024 * 1024;
const forbiddenShell = value => /\.(?:cmd|bat)$/i.test(value);
function validText(value, empty = false) {
  return typeof value === 'string' && (empty || value !== '') && !value.includes('\0')
    && Buffer.from(value, 'utf8').toString('utf8') === value;
}
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function environment(value = process.env) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Process environment must be a string map');
  const result = Object.create(null);
  for (const [key, item] of Object.entries(value)) {
    if (!validText(key) || key.includes('=') || !validText(item, true)) throw new Error('Process environment must contain valid text without NUL');
    result[key] = item;
  }
  return result;
}
function envValue(env, name) {
  if (process.platform !== 'win32') return env[name] || '';
  const keys = Object.keys(env).filter(key => key.toUpperCase() === name).sort();
  if (keys.length > 1) throw new Error('Process environment has ambiguous ' + name + ' casing');
  return keys.length ? env[keys[0]] : '';
}
function key(value) { return process.platform === 'win32' ? value.toLowerCase() : value; }
async function fileIdentity(file, executable) {
  const real = await fs.realpath(file), stat = await fs.stat(real, { bigint: true });
  if (!stat.isFile()) throw new Error('Configured executable is not a regular file');
  if (forbiddenShell(real)) throw new Error('Batch scripts require an explicitly declared interpreter; no shell is added');
  await fs.access(real, executable && process.platform !== 'win32' ? constants.X_OK : constants.R_OK);
  return { path: path.resolve(real), dev: String(stat.dev), ino: String(stat.ino), size: String(stat.size),
    mtimeNs: String(stat.mtimeNs), ctimeNs: String(stat.ctimeNs) };
}
async function resolveExecutable(command, values) {
  if (!validText(command)) throw new Error('Tool executable must be valid nonempty text without NUL');
  if (forbiddenShell(command)) throw new Error('Batch scripts require an explicitly declared interpreter; no shell is added');
  const env = environment(values), pathValue = envValue(env, 'PATH'), extensionValue = envValue(env, 'PATHEXT');
  const searchRevision = createHash('sha256').update(JSON.stringify([pathValue, extensionValue])).digest('hex');
  let candidates;
  if (path.isAbsolute(command)) candidates = [path.resolve(command)];
  else {
    if (command.includes('/') || command.includes('\\')) throw new Error('Tool executable must be a PATH name or an absolute local path');
    const suffixes = process.platform === 'win32' && !path.extname(command)
      ? ['', ...(extensionValue || '.COM;.EXE;.BAT;.CMD').split(';').filter(value => /^\.[A-Za-z0-9]+$/.test(value))] : [''];
    // Empty/relative PATH entries depend on a later cwd. Never invent that
    // relationship while resolving an executable for a retained task.
    candidates = pathValue.split(path.delimiter).filter(value => value && path.isAbsolute(value))
      .flatMap(directory => suffixes.map(suffix => path.join(directory, command + suffix)));
  }
  let rejectedBatch = false;
  for (const candidate of candidates) {
    if (forbiddenShell(candidate)) {
      try { const stat = await fs.stat(candidate); if (stat.isFile()) rejectedBatch = true; } catch (_) { /* unavailable candidate */ }
      continue;
    }
    try { return freeze({ command, ...(await fileIdentity(candidate, true)), searchRevision }); }
    catch (error) {
      if (path.isAbsolute(command)) throw new Error('Configured executable is unavailable: ' + error.message);
      if (!['ENOENT', 'ENOTDIR', 'EACCES', 'EPERM'].includes(error.code) && error.message.includes('Batch scripts')) rejectedBatch = true;
    }
  }
  throw new Error(rejectedBatch ? 'Batch scripts require an explicitly declared interpreter; no shell is added'
    : 'Executable is unavailable on the explicit local PATH: ' + command);
}
async function revalidateExecutable(identity, values) {
  if (!identity || !validText(identity.command) || !path.isAbsolute(identity.path || '')) throw new Error('Executable identity is invalid');
  const current = await resolveExecutable(identity.command, values);
  if (JSON.stringify(current) !== JSON.stringify(identity)) throw new Error('Executable or local PATH changed; prepare the task again');
  return true;
}
async function identifyDirectory(cwd) {
  if (!validText(cwd) || !path.isAbsolute(cwd)) throw new Error('Task cwd must be an explicit absolute local directory');
  const real = await fs.realpath(cwd), stat = await fs.stat(real, { bigint: true });
  if (!stat.isDirectory()) throw new Error('Task cwd is not a directory');
  return freeze({ selectedPath: path.resolve(cwd), path: path.resolve(real), dev: String(stat.dev), ino: String(stat.ino) });
}
async function revalidateDirectory(identity) {
  if (!identity || !validText(identity.selectedPath)) throw new Error('Task directory identity is invalid');
  const current = await identifyDirectory(identity.selectedPath);
  if (key(current.path) !== key(identity.path) || current.dev !== identity.dev || current.ino !== identity.ino) {
    throw new Error('Task working directory changed; prepare the task again');
  }
  return true;
}
function utf8Prefix(buffer, complete) {
  const decoder = new StringDecoder('utf8');
  return decoder.write(buffer) + (complete ? decoder.end() : '');
}
function integer(value, minimum, maximum) { return Number.isInteger(value) && value >= minimum && value <= maximum; }
function boundedOption(options, name, fallback, maximum) {
  const value = options[name] === undefined ? fallback : options[name];
  if (!integer(value, 0, maximum)) throw new Error(name + ' must be an integer from 0 to ' + maximum);
  return value;
}
// The native receipt is a flat JSON object. Reject duplicate keys as well as
// unknown fields instead of accepting whichever duplicate JSON.parse kept.
function parseReceipt(text) {
  const value = JSON.parse(text), names = new Set();
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Receipt must be an object');
  const tokens = text.match(/"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}:,\[\]]/g) || [];
  let at = 0;
  if (tokens[at++] !== '{') throw new Error('Receipt must be flat');
  while (tokens[at] !== '}') {
    const token = tokens[at++];
    if (!token || token[0] !== '"') throw new Error('Receipt key is invalid');
    const name = JSON.parse(token);
    if (names.has(name)) throw new Error('Receipt contains duplicate keys');
    names.add(name);
    if (tokens[at++] !== ':') throw new Error('Receipt key lacks a value');
    const item = tokens[at++];
    if (!item || ['{', '[', '}', ']', ':', ','].includes(item)) throw new Error('Receipt values must be primitive');
    if (tokens[at] === ',') { ++at; continue; }
    if (tokens[at] !== '}') throw new Error('Receipt separator is invalid');
  }
  if (++at !== tokens.length || names.size !== Object.keys(value).length) throw new Error('Receipt contains trailing data');
  return value;
}
async function readReceipt(file, scope) {
  let descriptor;
  try {
    const initial = await fs.lstat(file, { bigint: true });
    if (!initial.isFile() || initial.isSymbolicLink() || initial.size > 4096n) throw new Error('Receipt is not a bounded regular file');
    descriptor = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const before = await descriptor.stat({ bigint: true });
    // Windows path stat can expose dev=0 while fstat supplies the volume ID.
    // Both still expose the same file index; compare a supplied nonzero dev.
    if (!before.isFile() || before.size > 4096n || initial.dev !== 0n && before.dev !== initial.dev || before.ino !== initial.ino) throw new Error('Receipt identity changed');
    const bytes = Buffer.alloc(4097), { bytesRead } = await descriptor.read(bytes, 0, bytes.length, 0);
    const after = await descriptor.stat({ bigint: true });
    if (bytesRead > 4096 || BigInt(bytesRead) !== before.size || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs || after.ctimeNs !== before.ctimeNs) throw new Error('Receipt changed while reading');
    const text = bytes.subarray(0, bytesRead).toString('utf8');
    if (!bytes.subarray(0, bytesRead).equals(Buffer.from(text, 'utf8'))) throw new Error('Receipt is not UTF-8');
    const value = parseReceipt(text);
    const fields = ['version', 'scope', 'exit_code', 'signal', 'cancelled', 'forced', 'termination_confirmed', 'detached_observed', 'error'];
    if (Object.keys(value).length !== fields.length || fields.some(name => !Object.hasOwn(value, name))
      || value.version !== 1 || value.scope !== scope
      || typeof value.cancelled !== 'boolean' || typeof value.forced !== 'boolean' || typeof value.termination_confirmed !== 'boolean'
      || !validText(value.error, true) || Buffer.byteLength(value.error, 'utf8') > 500 || /[\u0000-\u001f\u007f]/.test(value.error)) throw new Error('Receipt fields are invalid');
    const coordinates = scope === 'windows_job'
      ? integer(value.exit_code, -2147483648, 2147483647) && value.signal === 0 && value.detached_observed === -1
      : integer(value.exit_code, 0, 255) && integer(value.signal, 0, 64)
        && (value.signal === 0 || value.exit_code === 128 + value.signal) && integer(value.detached_observed, 0, 1000000);
    if (!coordinates) throw new Error('Receipt coordinates are invalid');
    return freeze(value);
  } finally { if (descriptor) await descriptor.close(); }
}
function startProcess(options, onUpdate) {
  if (!options || !Array.isArray(options.argv) || options.argv.length < 1 || options.argv.length > 257
    || options.argv.some((value, index) => !validText(value, index > 0))) throw new Error('Task argv must contain 1–257 valid exact string arguments');
  for (let index = 0; index < options.argv.length; ++index) {
    if (!Object.hasOwn(options.argv, index)) throw new Error('Task argv must be dense');
  }
  if (Buffer.byteLength(JSON.stringify(options.argv), 'utf8') > MAX_BYTES) throw new Error('Task argv exceeds 1 MiB');
  if (forbiddenShell(options.argv[0])) throw new Error('Batch scripts require an explicitly declared interpreter; no shell is added');
  if (!validText(options.cwd) || !path.isAbsolute(options.cwd)) throw new Error('Task cwd must be an explicit absolute local directory');
  if (onUpdate !== undefined && typeof onUpdate !== 'function') throw new Error('Task update handler must be a function');
  if (options.beforeSpawn !== undefined && typeof options.beforeSpawn !== 'function') throw new Error('beforeSpawn must be a local admission function');
  const beforeSpawn = options.beforeSpawn, helperPath = options.processHelper;
  const argv = options.argv.slice(), cwd = path.resolve(options.cwd), env = environment(options.env);
  const timeoutMs = boundedOption(options, 'timeoutMs', 0, 86400000);
  const cancelGraceMs = boundedOption(options, 'cancelGraceMs', 2000, 60000);
  const maxBytes = boundedOption(options, 'maxBytes', MAX_BYTES, MAX_BYTES);
  const owned = options.processHelper !== undefined && options.processHelper !== false;
  if (owned && (!validText(options.processHelper) || !path.isAbsolute(options.processHelper))) {
    throw new Error('processHelper must be an absolute local executable path or false');
  }
  if (owned && !['win32', 'linux'].includes(process.platform)) throw new Error('Owned process helper is unsupported on this platform');
  const scope = owned ? process.platform === 'win32' ? 'windows_job' : 'linux_group' : 'direct';
  // Buffers grow geometrically; stdout+stderr share one logical byte budget.
  // Merged output retains observed decoded-text order. Separate pipe decoders
  // prevent interleaved writes from splitting another stream's UTF-8 character.
  // Small tasks allocate only what
  // they use, and terminal snapshots release all raw capture buffers.
  let buffers = { output: Buffer.alloc(0), stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }, terminal = null;
  const sizes = { output: 0, stdout: 0, stderr: 0 }, cut = { output: false, stdout: false, stderr: false };
  const decoders = { stdout: new StringDecoder('utf8'), stderr: new StringDecoder('utf8') };
  let capturedBytes = 0;
  let status = 'running', started = false, closed = false, closeObserved = false, cancelled = false, exitCode = null, signal = null;
  let exitObserved = false, forceRequested = false, timedOut = false, cancelDeadline = 0, forced = false, outputIncomplete = false, exitCodeUnavailable = false;
  let cancelMonotonicDeadline = 0n;
  let cancelState = 'none', receipt = null, helperDirectory = null, receiptFile = null;
  let launchError = '', streamError = '', controlError = '', receiptError = '', updateTimer = null, timeoutTimer = null, graceTimer = null, drainTimer = null, child, finish;
  const done = new Promise(resolve => { finish = resolve; });
  function snapshot() {
    if (terminal) return terminal;
    return freeze({ status, started, argv: argv.slice(), cwd, stdout: utf8Prefix(buffers.stdout.subarray(0, sizes.stdout), closed && !cut.stdout && !outputIncomplete),
      stderr: utf8Prefix(buffers.stderr.subarray(0, sizes.stderr), closed && !cut.stderr && !outputIncomplete),
      output: utf8Prefix(buffers.output.subarray(0, sizes.output), closed && !cut.output),
      capturedBytes, truncated: cut.output, outputIncomplete, exitCode, exitCodeUnavailable, signal, cancelled, timedOut, forced, forceRequested, cancelState, cancelDeadline,
      launchError, message: launchError || receiptError || (receipt && receipt.error) || streamError || controlError
        || (exitCodeUnavailable ? 'Owned group termination confirmed; original command exit code unavailable'
          : timedOut ? 'Task timeout reached; cancellation requested' : cancelled ? 'Process cancellation requested' : ''),
      processScope: scope, descendantTermination: owned ? receipt && receipt.termination_confirmed ? 'confirmed' : 'unconfirmed' : 'unknown',
      terminationConfirmed: owned ? !started && closed || Boolean(receipt && receipt.termination_confirmed) : closeObserved,
      detachedObserved: receipt ? receipt.detached_observed : -1,
      receipt, helperExitCode: owned && closeObserved ? helperExitCode : null, helperSignal: owned && closeObserved ? helperSignal : null,
      detachedExclusion: owned ? 'Deliberately detached daemons and services outside the owned scope are excluded; their termination is not promised'
        : 'Descendants and deliberately detached services are outside direct-process termination evidence' });
  }
  function notify() {
    if (updateTimer) { clearTimeout(updateTimer); updateTimer = null; }
    if (onUpdate) { try { onUpdate(snapshot()); } catch (_) { /* UI failure cannot own or relaunch this child */ } }
  }
  function scheduleUpdate() {
    if (!updateTimer && onUpdate) updateTimer = setTimeout(notify, 25);
  }
  function capacity(channel, needed) {
    const previous = buffers[channel];
    if (previous.length >= needed) return previous;
    const next = Buffer.allocUnsafe(Math.min(maxBytes, Math.max(4096, previous.length * 2, needed)));
    previous.copy(next, 0, 0, sizes[channel]); buffers[channel] = next;
    return next;
  }
  function settle() {
    if (timeoutTimer) { clearTimeout(timeoutTimer); timeoutTimer = null; }
    if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
    if (drainTimer) { clearTimeout(drainTimer); drainTimer = null; }
    terminal = snapshot(); buffers = null;
    notify(); finish(terminal);
  }
  function appendOutput(text) {
    if (!text) return;
    let bytes = Buffer.from(text, 'utf8');
    const remaining = maxBytes - sizes.output;
    if (bytes.length > remaining) {
      cut.output = true;
      bytes = Buffer.from(utf8Prefix(bytes.subarray(0, remaining), false), 'utf8');
    }
    if (bytes.length) { bytes.copy(capacity('output', sizes.output + bytes.length), sizes.output); sizes.output += bytes.length; }
  }
  function collect(channel, chunk) {
    if (closed) return;
    const remaining = maxBytes - capturedBytes, length = Math.min(remaining, chunk.length);
    if (length < chunk.length) cut.output = cut[channel] = true;
    if (length) {
      chunk.copy(capacity(channel, sizes[channel] + length), sizes[channel], 0, length);
      capturedBytes += length; sizes[channel] += length;
      appendOutput(decoders[channel].write(chunk.subarray(0, length)));
    }
    scheduleUpdate();
  }
  let helperExitCode = null, helperSignal = null;
  async function cleanup() {
    if (!helperDirectory) return;
    const directory = helperDirectory; helperDirectory = null;
    // This exact mkdtemp result is private to this process owner. Never remove
    // a supplied directory, status path, or any resolved user project path.
    try {
      const relative = path.relative(path.resolve(os.tmpdir()), path.resolve(directory));
      if (!relative.startsWith('re35-process-') || relative.includes(path.sep) || path.isAbsolute(relative)) throw new Error('Private receipt directory escaped its temporary parent');
      await fs.rm(directory, { recursive: true, force: true });
    }
    catch (error) { controlError = 'Owned process receipt cleanup failed: ' + String(error.message).slice(0, 400); }
  }
  async function close(code, receivedSignal) {
    if (closed || closeObserved) return;
    closeObserved = exitObserved = true;
    helperExitCode = Number.isInteger(code) ? code : null; helperSignal = receivedSignal || null;
    if (timeoutTimer) { clearTimeout(timeoutTimer); timeoutTimer = null; }
    if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
    if (owned) {
      try { receipt = await readReceipt(receiptFile, scope); }
      catch (error) { receiptError = 'Owned process helper exited without a valid termination report: ' + String(error.message).slice(0, 350); }
      await cleanup();
      exitCodeUnavailable = Boolean(scope === 'linux_group' && receipt && receipt.cancelled && receipt.forced
        && receipt.termination_confirmed && receipt.error === '' && receipt.exit_code === 125 && receipt.signal === 0);
      exitCode = exitCodeUnavailable ? null : receipt ? receipt.exit_code : 125; signal = receipt && receipt.signal || null;
      forced = Boolean(receipt && receipt.forced);
      // A receipt owns the actual outcome. A late local request does not turn
      // an already successful child into a falsely reported cancellation.
      const evidenceFailure = launchError || streamError || receiptError || code !== 0 || receivedSignal
        || !receipt || receipt.error || !receipt.termination_confirmed;
      status = evidenceFailure ? 'failed' : receipt.cancelled ? 'cancelled' : receipt.exit_code !== 0 || receipt.signal ? 'failed' : 'succeeded';
      cancelled = receipt ? receipt.cancelled : cancelled;
    } else {
      exitCode = Number.isInteger(code) ? code : null; signal = receivedSignal || null;
      status = cancelled ? 'cancelled' : launchError || streamError || code !== 0 || receivedSignal ? 'failed' : 'succeeded';
      forced = forceRequested && receivedSignal === 'SIGKILL';
    }
    for (const channel of ['stdout', 'stderr']) if (!cut[channel] && !outputIncomplete) appendOutput(decoders[channel].end());
    closed = true;
    cancelState = cancelled ? (owned && (!receipt || !receipt.termination_confirmed) ? 'unconfirmed' : 'confirmed') : 'none';
    settle();
  }
  function spawnChild(launch) {
    try {
      child = spawn(launch[0], launch.slice(1), { cwd, env, shell: false, windowsHide: true,
        stdio: [owned ? 'pipe' : 'ignore', 'pipe', 'pipe'] });
    } catch (error) { return admissionFailure(error); }
    child.on('spawn', () => {
      started = true;
      if (timeoutMs) timeoutTimer = setTimeout(() => { timedOut = true; cancel(); }, timeoutMs);
      scheduleUpdate();
    });
    child.on('error', error => { launchError = String(error.message).slice(0, 500); scheduleUpdate(); });
    child.on('exit', () => {
      exitObserved = true;
      if (timeoutTimer) { clearTimeout(timeoutTimer); timeoutTimer = null; }
      if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
      // Direct descendants can retain inherited pipes after the owned child
      // exits. Bound draining without signalling unrelated descendant PIDs.
      if (!owned) drainTimer = setTimeout(() => {
        if (closed || closeObserved) return;
        outputIncomplete = true;
        controlError = 'Direct child exited; inherited output pipes remained open and descendant termination is unknown';
        child.stdout.destroy(); child.stderr.destroy();
      }, 2000);
    });
    if (child.stdin) child.stdin.on('error', error => {
      if (!exitObserved && !closed) { controlError = 'Owned process control failed: ' + String(error.message).slice(0, 400); child.stdin.destroy(); scheduleUpdate(); }
    });
    for (const channel of ['stdout', 'stderr']) {
      child[channel].on('data', chunk => collect(channel, chunk));
      child[channel].on('error', error => { streamError = 'Process output failed: ' + String(error.message).slice(0, 450); scheduleUpdate(); });
    }
    child.on('close', (code, receivedSignal) => { void close(code, receivedSignal); });
  }
  async function admissionFailure(error) {
    launchError = String(error.message).slice(0, 500); status = cancelled && !started ? 'cancelled' : 'failed'; exitObserved = true;
    await cleanup();
    if (status === 'cancelled') cancelState = 'confirmed';
    closed = closeObserved = true; settle();
  }
  function control(force) {
    if (!child || exitObserved || closed) return false;
    try {
      if (owned) {
        if (!child.stdin || child.stdin.destroyed || !child.stdin.writable) throw new Error('Owned helper control is unavailable');
        child.stdin.write(force ? 'f\n' : 'c\n');
      } else if (!child.kill(force ? 'SIGKILL' : 'SIGTERM')) throw new Error('Direct process signal could not be delivered');
      return true;
    } catch (error) { controlError = 'Process cancellation failed: ' + String(error.message).slice(0, 450); scheduleUpdate(); return false; }
  }
  function force() {
    if (closed || exitObserved || !cancelled || forceRequested || process.hrtime.bigint() < cancelMonotonicDeadline) return false;
    if (!control(true)) return false;
    forceRequested = true; cancelState = 'force_requested'; scheduleUpdate(); return true;
  }
  function forceAfterGrace() {
    graceTimer = null;
    if (closed || exitObserved || !cancelled || forceRequested) return;
    const remaining = cancelMonotonicDeadline - process.hrtime.bigint();
    if (remaining > 0n) {
      // Timer rounding can deliver an early callback; wall-clock adjustments
      // never extend or shorten the owned cancellation grace period.
      graceTimer = setTimeout(forceAfterGrace, Number((remaining + 999999n) / 1000000n)); return;
    }
    force(); // A failed control delivery is reported, not busy-retried.
  }
  function cancel() {
    if (closed || exitObserved || cancelled) return false;
    // Async helper preparation is cancellable without admitting either a
    // helper or a tool. Its private receipt file is still cleaned up.
    if (child && !control(false)) return false;
    cancelled = true; cancelState = 'requested'; cancelDeadline = Date.now() + cancelGraceMs;
    cancelMonotonicDeadline = process.hrtime.bigint() + BigInt(cancelGraceMs) * 1000000n;
    if (child) graceTimer = setTimeout(forceAfterGrace, cancelGraceMs);
    scheduleUpdate(); return true;
  }
  async function cancelledBeforeSpawn() {
    if (!cancelled) return false;
    await cleanup(); closed = closeObserved = true; status = 'cancelled'; cancelState = 'confirmed'; settle(); return true;
  }
  async function admit() {
    if (cancelled) { await cancelledBeforeSpawn(); return false; }
    if (beforeSpawn) await beforeSpawn();
    if (cancelled) { await cancelledBeforeSpawn(); return false; }
    return true;
  }
  async function prepareHelper() {
    try {
      const helper = await resolveExecutable(helperPath, env);
      if (!cancelled) {
        helperDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 're35-process-'));
        receiptFile = path.join(helperDirectory, 'status.json');
        await fs.writeFile(receiptFile, '', { flag: 'wx', mode: 0o600 });
        await revalidateExecutable(helper, env);
      }
      if (!await admit()) return;
      spawnChild([helper.path, '--status', receiptFile, '--grace-ms', String(Math.max(1, cancelGraceMs)), '--', ...argv]);
    } catch (error) { await admissionFailure(error); }
  }
  async function prepareDirect() {
    try { if (await admit()) spawnChild(argv); }
    catch (error) { await admissionFailure(error); }
  }
  if (owned) void prepareHelper(); else if (beforeSpawn) void prepareDirect(); else spawnChild(argv);
  return Object.freeze({ snapshot, done, dispose: cancel, cancel, force });
}
module.exports = { startProcess, resolveExecutable, revalidateExecutable, identifyDirectory, revalidateDirectory };
