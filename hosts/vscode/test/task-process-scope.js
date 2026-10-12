'use strict';
// Actual optional native process ownership, not native editor interaction.
// Pass the separately built helper and a C compiler to exercise corrupt receipts.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const syncfs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { startProcess } = require('../task-process');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const execute = promisify(execFile);
async function run() {
  const helper = process.argv[2], compiler = process.argv[3];
  assert(helper && path.isAbsolute(helper), 'Pass the absolute native ce_process_scope path');
  assert(compiler && path.isAbsolute(compiler), 'Pass an absolute C compiler for receipt fault probes');
  const artifacts = path.resolve(__dirname, '../../../.artifacts');
  await fs.mkdir(artifacts, { recursive: true });
  const directory = await fs.mkdtemp(path.join(artifacts, 'task-process-scope-'));
  const scope = process.platform === 'win32' ? 'windows_job' : 'linux_group';
  const descendants = new Set();
  let checks = 0;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  async function deadline(task, timeout = 7000) {
    let timer;
    try { return await Promise.race([task.done, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Task did not terminate within test deadline')), timeout); })]); }
    finally { clearTimeout(timer); }
  }
  async function waitOutput(task, pattern) {
    const until = Date.now() + 5000;
    while (!pattern.test(task.snapshot().stdout) && Date.now() < until) await delay(10);
    assert.match(task.snapshot().stdout, pattern); ++checks;
  }
  function gone(pid) {
    if (process.platform === 'linux') {
      // kill(pid, 0) also succeeds for a terminated zombie. Match the native
      // receipt and process_tree.py liveness contract rather than PID reaping.
      let stat;
      try { stat = syncfs.readFileSync('/proc/' + pid + '/stat', 'utf8'); }
      catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ESRCH') throw error;
      }
      if (stat !== undefined) {
        const end = stat.lastIndexOf(')');
        assert(end >= 0, 'Owned child process state must be readable');
        const state = stat.slice(end + 1).trim().split(/\s+/)[0];
        assert(state === 'Z' || state === 'X', 'Owned child process is still running: ' + state);
      }
    } else {
      // Permission errors do not prove that the original process has exited.
      assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    }
    ++checks; descendants.delete(pid);
  }
  const command = script => [process.execPath, '-e', script];
  const options = (argv, extra = {}) => ({ argv, cwd: directory, processHelper: helper, cancelGraceMs: 60, ...extra });
  try {
    const exact = ['', 'with spaces', '한글 😀', '; echo unsafe', '$(echo unsafe)', 'a\\b'];
    const normal = startProcess(options([...command('process.stdout.write(JSON.stringify(process.argv.slice(1)));process.stderr.write("경고 😀\\n")'), ...exact]));
    const success = await deadline(normal);
    eq(success.status, 'succeeded'); eq(success.exitCode, 0); eq(success.processScope, scope);
    eq(JSON.parse(success.stdout), exact); eq(success.stderr, '경고 😀\n');
    eq(success.terminationConfirmed, true); eq(success.descendantTermination, 'confirmed');
    eq(success.receipt.version, 1); eq(success.helperExitCode, 0); eq(success.helperSignal, null);
    eq(success.timedOut, false); eq(success.outputIncomplete, false); eq(normal.snapshot() === success, true);
    eq(Object.isFrozen(success.receipt), true); eq(normal.cancel(), false); eq(normal.force(), false);
    const nonzero = await deadline(startProcess(options(command('process.stdout.write("failed partial");process.exitCode=7'))));
    eq(nonzero.status, 'failed'); eq(nonzero.exitCode, 7); eq(nonzero.stdout, 'failed partial'); eq(nonzero.terminationConfirmed, true);

    const treeScript = `
      const {spawn}=require('node:child_process');
      const child=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},100)'],{stdio:['ignore','inherit','inherit']});
      child.once('spawn',()=>{process.stdout.write(JSON.stringify({root:process.pid,child:child.pid})+'\\n');process.stderr.write('retained partial output\\n')});
      setInterval(()=>{},100);`;
    const updates = [], tree = startProcess(options(command(treeScript), { cancelGraceMs: 100 }), value => updates.push(value));
    await waitOutput(tree, /"root":\d+,"child":\d+/);
    const pids = JSON.parse(tree.snapshot().stdout.trim()); descendants.add(pids.root); descendants.add(pids.child);
    assert.throws(() => gone(pids.child), { code: 'ERR_ASSERTION' }); ++checks;
    eq(descendants.has(pids.child), true); // A live child remains owned for cleanup.
    eq(tree.force(), false); eq(tree.cancel(), true); eq(tree.cancel(), false); eq(tree.force(), false);
    eq(tree.snapshot().terminationConfirmed, false); eq(tree.snapshot().cancelState, 'requested');
    eq(tree.snapshot().cancelDeadline > 0, true);
    const cancelled = await deadline(tree);
    eq(cancelled.status, 'cancelled'); eq(cancelled.terminationConfirmed, true); eq(cancelled.descendantTermination, 'confirmed');
    eq(cancelled.receipt.cancelled, true); eq(cancelled.cancelState, 'confirmed'); eq(cancelled.stderr, 'retained partial output\n');
    gone(pids.root); gone(pids.child); eq(updates.filter(value => value.status !== 'running').length, 1);
    eq(tree.cancel(), false); eq(tree.force(), false);

    const timed = startProcess(options(command('process.stdout.write("before timeout");process.on("SIGTERM",()=>{});setInterval(()=>{},100)'), { timeoutMs: 500 }));
    const timeout = await deadline(timed);
    eq(timeout.status, 'cancelled'); eq(timeout.timedOut, true); eq(timeout.stdout, 'before timeout');
    eq(timeout.terminationConfirmed, true); eq(timeout.receipt.cancelled, true);
    if (process.platform === 'linux') {
      eq(timeout.receipt.forced, true); eq(timeout.forced, true);
      if (timeout.receipt.exit_code === 125 && timeout.receipt.signal === 0) {
        eq(timeout.exitCode, null); eq(timeout.exitCodeUnavailable, true);
        assert.match(timeout.message, /original command exit code unavailable/); ++checks;
      }
      // Short grace reliably exercises the native anchor/result-pipe race.
      // Every iteration still needs actual complete owned-group exit evidence.
      for (let repeat = 0; repeat < 8; ++repeat) {
        const forcedTimeout = await deadline(startProcess(options(command('process.on("SIGTERM",()=>{});setInterval(()=>{},100)'), {
          timeoutMs: 150, cancelGraceMs: 20
        })));
        eq(forcedTimeout.status, 'cancelled'); eq(forcedTimeout.timedOut, true); eq(forcedTimeout.terminationConfirmed, true);
        eq(forcedTimeout.receipt.error, ''); eq(forcedTimeout.receipt.forced, true);
        if (forcedTimeout.receipt.exit_code === 125 && forcedTimeout.receipt.signal === 0) {
          eq(forcedTimeout.exitCode, null); eq(forcedTimeout.exitCodeUnavailable, true);
        }
      }
    }
    const bounded = await deadline(startProcess(options(command('process.stdout.write("x".repeat(100));process.stderr.write("y".repeat(100))'), { maxBytes: 64 })));
    eq(bounded.capturedBytes, 64); eq(bounded.truncated, true); eq(Buffer.byteLength(bounded.stdout + bounded.stderr), 64);
    eq((await deadline(startProcess(options(command('process.stdout.write("discarded")'), { maxBytes: 0 })))).capturedBytes, 0);

    const marker = path.join(directory, 'must-not-spawn');
    const temporaryBefore = (await fs.readdir(os.tmpdir())).filter(name => name.startsWith('re35-process-')).sort();
    const before = startProcess(options(command('require("node:fs").writeFileSync(process.argv[1],"unexpected")').concat(marker)));
    eq(before.cancel(), true);
    const stopped = await deadline(before);
    eq(stopped.status, 'cancelled'); eq(stopped.started, false); eq(stopped.terminationConfirmed, true); eq(stopped.receipt, null);
    await assert.rejects(() => fs.stat(marker), { code: 'ENOENT' }); ++checks;
    eq((await fs.readdir(os.tmpdir())).filter(name => name.startsWith('re35-process-')).sort(), temporaryBefore);
    const missing = await deadline(startProcess(options(command('process.stdout.write("must not run")'), { processHelper: path.join(directory, 'missing-helper') })));
    eq(missing.status, 'failed'); eq(missing.started, false); eq(missing.stdout, ''); eq(missing.terminationConfirmed, true);
    const refused = await deadline(startProcess(options(command('process.stdout.write("must not run")'), { beforeSpawn: async () => { throw new Error('fixture owner changed'); } })));
    eq(refused.status, 'failed'); eq(refused.started, false); eq(refused.stdout, ''); eq(refused.launchError, 'fixture owner changed');
    const duringAdmission = startProcess(options(command('process.stdout.write("must not run")'), { beforeSpawn: async () => { await delay(100); } }));
    await delay(30); eq(duringAdmission.cancel(), true);
    eq((await deadline(duringAdmission)).started, false);

    // A normal parent exit also cleans children still in its owned scope.
    const parentExitScript = treeScript.replace('setInterval(()=>{},100);', 'setTimeout(()=>process.exit(0),200);');
    const parentExit = startProcess(options(command(parentExitScript)));
    await waitOutput(parentExit, /"root":\d+,"child":\d+/);
    const exitPids = JSON.parse(parentExit.snapshot().stdout.trim()); descendants.add(exitPids.child);
    const completed = await deadline(parentExit);
    eq(completed.status, 'succeeded'); eq(completed.terminationConfirmed, true); gone(exitPids.child);

    // Direct ownership does not promise descendants. Pipes cannot indefinitely
    // prevent an already exited direct child from reaching a truthful result.
    const orphanScript = `const {spawn}=require('node:child_process');const child=spawn(process.execPath,['-e','setInterval(()=>{},100)'],{detached:true,stdio:['ignore','inherit','inherit']});child.unref();child.once('spawn',()=>{process.stdout.write(String(child.pid)+'\\n');setTimeout(()=>process.exit(0),100)});`;
    const orphan = startProcess({ argv: command(orphanScript), cwd: directory });
    await waitOutput(orphan, /^\d+\n/);
    const orphanPid = Number(orphan.snapshot().stdout.trim()); descendants.add(orphanPid);
    const orphanResult = await deadline(orphan, 4000);
    eq(orphanResult.status, 'succeeded'); eq(typeof orphanResult.outputIncomplete, 'boolean'); eq(orphanResult.terminationConfirmed, true);
    if (process.platform === 'linux') eq(orphanResult.outputIncomplete, true);
    eq(orphanResult.descendantTermination, 'unknown'); eq(orphan.cancel(), false);
    assert.doesNotThrow(() => process.kill(orphanPid, 0)); ++checks;
    process.kill(orphanPid, 'SIGKILL'); descendants.delete(orphanPid);

    if (process.platform === 'linux') {
      const detachedScript = `const {spawn}=require('node:child_process');const child=spawn(process.execPath,['-e','setInterval(()=>{},100)'],{detached:true,stdio:'ignore'});child.unref();process.stdout.write(String(child.pid));`;
      const detached = await deadline(startProcess(options(command(detachedScript))));
      const detachedPid = Number(detached.stdout); descendants.add(detachedPid);
      eq(detached.status, 'succeeded'); eq(detached.terminationConfirmed, true); eq(detached.detachedObserved >= 1, true);
      assert.doesNotThrow(() => process.kill(detachedPid, 0)); ++checks;
      assert.match(detached.detachedExclusion, /excluded/); ++checks;
      process.kill(detachedPid, 'SIGKILL'); descendants.delete(detachedPid);
    }

    // Explicit fault executable writes corrupt or unconfirmed receipts. It is
    // deliberately different from the native scope binary and starts no tool.
    const source = path.join(directory, 'receipt-fault.c'), fault = path.join(directory, process.platform === 'win32' ? 'receipt-fault.exe' : 'receipt-fault');
    const normalReceipt = { version: 1, scope, exit_code: 0, signal: 0, cancelled: false, forced: false,
      termination_confirmed: true, detached_observed: process.platform === 'win32' ? -1 : 0, error: '' };
    const receipts = {
      malformed: '{}', duplicate: JSON.stringify(normalReceipt).replace('"version":1', '"version":1,"version":1'),
      unknown: JSON.stringify({ ...normalReceipt, extra: true }),
      unconfirmed: JSON.stringify({ ...normalReceipt, termination_confirmed: false }),
      wrongScope: JSON.stringify({ ...normalReceipt, scope: 'wrong_scope' }),
      wrongSignal: JSON.stringify({ ...normalReceipt, signal: 77 }), oversized: 'x'.repeat(4097), utf8: '\u00ff'
    };
    const cases = Object.entries(receipts).map(([name, value]) => {
      const cBytes = Buffer.from(value, 'utf8');
      if (name === 'utf8') cBytes[0] = 255;
      return `if(strcmp(mode,${JSON.stringify(name)})==0){const unsigned char bytes[]={${Array.from(cBytes).join(',')}};fwrite(bytes,1,sizeof(bytes),file);}`;
    }).join('\n');
    await fs.writeFile(source, `#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint main(int argc,char **argv){if(argc<3)return 125;FILE *file=fopen(argv[2],"wb");if(!file)return 125;const char *mode=getenv("RE35_RECEIPT_FAULT");if(!mode)mode="malformed";${cases}\nfclose(file);fwrite("fault partial",1,13,stdout);return 0;}\n`);
    await execute(compiler, [source, '-o', fault], { windowsHide: true });
    for (const name of Object.keys(receipts)) {
      const result = await deadline(startProcess(options(command('process.stdout.write("must not run")'), {
        processHelper: fault, env: { ...process.env, RE35_RECEIPT_FAULT: name }
      })));
      eq(result.status, 'failed'); eq(result.terminationConfirmed, false); eq(result.descendantTermination, 'unconfirmed');
      eq(result.stdout, 'fault partial'); eq(result.output.includes('must not run'), false);
      if (name !== 'unconfirmed') eq(result.receipt, null);
    }
    eq((await fs.readdir(os.tmpdir())).filter(name => name.startsWith('re35-process-')).sort(), temporaryBefore);
    console.log(JSON.stringify({ passed: true, checks, platform: process.platform, processScope: scope,
      scope: 'Actual owned child/descendant exit, cancellation, timeout, original argv/partial output, no-child cancellation and corrupt receipt rejection; detached services excluded' }));
  } finally {
    for (const pid of descendants) { try { process.kill(pid, 'SIGKILL'); } catch (_) { /* exited fixture only */ } }
    const relative = path.relative(artifacts, path.resolve(directory));
    assert(relative.startsWith('task-process-scope-') && !relative.includes(path.sep) && !path.isAbsolute(relative));
    await fs.rm(directory, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
