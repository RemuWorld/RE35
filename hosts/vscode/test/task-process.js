'use strict';
// Actual direct Node children and filesystem identities; not editor acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { startProcess, resolveExecutable, revalidateExecutable, identifyDirectory, revalidateDirectory } = require('../task-process');
async function run() {
  const artifacts = path.resolve(__dirname, '../../../.artifacts');
  await fs.mkdir(artifacts, { recursive: true });
  const directory = await fs.mkdtemp(path.join(artifacts, 'task-process-'));
  let checks = 0;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  try {
    const identity = await resolveExecutable(process.execPath);
    eq(await revalidateExecutable(identity), true); eq(Object.isFrozen(identity), true);
    const env = { ...process.env };
    for (const name of Object.keys(env)) if (name.toUpperCase() === 'PATH') delete env[name];
    env.PATH = path.dirname(process.execPath);
    const fromPath = await resolveExecutable(path.basename(process.execPath), env);
    eq(fromPath.path, identity.path);
    await assert.rejects(() => resolveExecutable('missing-command-for-re35', env)); ++checks;
    await assert.rejects(() => resolveExecutable(path.join(directory, 'fake.cmd')), /explicitly declared interpreter/); ++checks;
    await assert.rejects(() => resolveExecutable('./local-program', env), /PATH name or an absolute/); ++checks;
    const cwdIdentity = await identifyDirectory(directory);
    eq(await revalidateDirectory(cwdIdentity), true);
    const exact = ['', 'with spaces', '한글 😀', '; echo unsafe', '$(echo unsafe)', 'a\\b'];
    const argv = [process.execPath, '-e', 'process.stdout.write(JSON.stringify({args:process.argv.slice(1),cwd:process.cwd()}));process.stderr.write("경고 😀\\n")', ...exact];
    const untouched = JSON.stringify(argv), updates = [];
    const successful = startProcess({ argv, cwd: directory }, value => updates.push(value));
    const success = await successful.done, output = JSON.parse(success.stdout);
    eq(success.status, 'succeeded'); eq(success.exitCode, 0); eq(success.started, true);
    eq(output.args, exact); eq(output.cwd.toLowerCase(), directory.toLowerCase()); eq(success.stderr, '경고 😀\n');
    eq(success.processScope, 'direct'); eq(success.descendantTermination, 'unknown'); eq(success.terminationConfirmed, true);
    eq(JSON.stringify(argv), untouched); eq(Object.isFrozen(success.argv), true);
    eq(successful.snapshot(), success); eq(successful.snapshot() === success, true);
    eq(updates.filter(value => value.status !== 'running').length, 1); eq(successful.dispose(), false);
    const failed = await startProcess({ argv: [process.execPath, '-e', 'process.stdout.write("failed output");process.exitCode=7'], cwd: directory }).done;
    eq(failed.status, 'failed'); eq(failed.exitCode, 7); eq(failed.stdout, 'failed output');
    eq((await startProcess({ argv: [process.execPath, '-e', 'process.stdout.write("ok")'], cwd: directory }, () => { throw new Error('UI fixture error'); }).done).status, 'succeeded');
    const missing = await startProcess({ argv: [path.join(directory, 'missing-executable.exe')], cwd: directory }).done;
    eq(missing.status, 'failed'); eq(missing.started, false); eq(missing.launchError.length > 0, true);
    eq(missing.terminationConfirmed, true);
    const captured = await startProcess({ argv: [process.execPath, '-e', 'process.stdout.write("A"+"😀".repeat(300000))'], cwd: directory }).done;
    eq(captured.status, 'succeeded'); eq(captured.truncated, true); eq(captured.capturedBytes, 1048576);
    eq(captured.stdout.includes('\uFFFD'), false); eq(Buffer.byteLength(captured.stdout, 'utf8') <= 1048576, true);
    eq(captured.stdout, 'A' + '😀'.repeat(262143));
    const controlled = startProcess({ argv: [process.execPath, '-e', 'process.stdout.write(String(process.pid));setInterval(()=>{},100)'], cwd: directory });
    const deadline = Date.now() + 5000;
    while ((!controlled.snapshot().started || controlled.snapshot().stdout === '') && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    const pid = Number(controlled.snapshot().stdout); assert(Number.isInteger(pid) && pid > 0); ++checks;
    eq(controlled.dispose(), true); eq(controlled.snapshot().status, 'running'); eq(controlled.snapshot().terminationConfirmed, false);
    const cancelled = await controlled.done;
    eq(cancelled.status, 'cancelled'); eq(cancelled.terminationConfirmed, true); eq(cancelled.descendantTermination, 'unknown');
    assert.throws(() => process.kill(pid, 0)); ++checks;
    eq(controlled.dispose(), false);
    const sparse = [process.execPath]; sparse.length = 3;
    assert.throws(() => startProcess({ argv: sparse, cwd: directory }), /dense/); ++checks;
    assert.throws(() => startProcess({ argv: [process.execPath, '\ud800'], cwd: directory }), /valid exact/); ++checks;
    assert.throws(() => startProcess({ argv: [process.execPath], cwd: 'relative' }), /absolute local/); ++checks;
    const unknownDirectory = await startProcess({ argv: [process.execPath, '-e', 'process.exit(0)'], cwd: path.join(directory, 'missing-cwd') }).done;
    eq(unknownDirectory.status, 'failed'); eq(unknownDirectory.started, false);
    if (process.platform === 'win32') {
      await fs.writeFile(path.join(directory, 'batch-only.cmd'), '@echo off\r\nexit /b 0\r\n');
      const batchEnv = { ...env, PATH: directory, PATHEXT: '.EXE;.CMD' };
      await assert.rejects(() => resolveExecutable('batch-only', batchEnv), /explicitly declared interpreter/); ++checks;
    }
    await fs.writeFile(path.join(directory, 'local.sh'), '#!/bin/sh\nexit 0\n');
    const file = path.join(directory, 'local.sh');
    if (process.platform !== 'win32') {
      await fs.chmod(file, 0o700);
      const executable = await resolveExecutable(file); await fs.writeFile(file, '#!/bin/sh\nexit 1\n');
      await assert.rejects(() => revalidateExecutable(executable)); ++checks;
    }
    const chunked = await startProcess({ argv: [process.execPath, '-e',
      'for(let i=0;i<10000;i++){process.stdout.write("a");process.stderr.write("b")}'], cwd: directory }).done;
    eq(chunked.stdout, 'a'.repeat(10000)); eq(chunked.stderr, 'b'.repeat(10000));
    eq(chunked.capturedBytes, 20000); eq(chunked.truncated, false);
    const interleaved = await startProcess({ argv: [process.execPath, '-e',
      'process.stdout.write(Buffer.from([240,159]));setTimeout(()=>{process.stderr.write("x");setTimeout(()=>process.stdout.write(Buffer.from([152,128])),30)},30)'], cwd: directory }).done;
    eq(interleaved.stdout, '😀'); eq(interleaved.stderr, 'x'); eq(interleaved.output, 'x😀');
    eq(interleaved.output.includes('\uFFFD'), false);
    // Keep completed process handles alive in a separate GC-enabled worker.
    // Retained terminal text belongs to heap; old raw capture ArrayBuffers must
    // not remain attached to each process handle after close.
    const modulePath = path.resolve(__dirname, '../task-process.js');
    const memoryScript = `
      const {startProcess}=require(${JSON.stringify(modulePath)});
      (async()=>{
        global.gc(); const before=process.memoryUsage().arrayBuffers; const retained=[];
        for(let i=0;i<10;i++){
          const task=startProcess({argv:[process.execPath,'-e','process.stdout.write("x".repeat(1048576))'],cwd:${JSON.stringify(directory)}});
          const result=await task.done;
          if(result.status!=='succeeded'||task.snapshot()!==result) throw new Error('terminal cache mismatch');
          retained.push(task);
        }
        await new Promise(setImmediate); global.gc();
        await new Promise(setImmediate); global.gc();
        const delta=process.memoryUsage().arrayBuffers-before;
        if(delta>4194304) throw new Error('raw capture buffers remained retained: '+delta);
        process.stdout.write(JSON.stringify({retained:retained.length,rawArrayBufferDelta:delta}));
      })().catch(error=>{console.error(error);process.exitCode=1});`;
    const memory = await startProcess({ argv: [process.execPath, '--expose-gc', '-e', memoryScript], cwd: directory }).done;
    assert.equal(memory.status, 'succeeded', memory.stderr || memory.message); ++checks;
    eq(JSON.parse(memory.stdout).retained, 10);
    eq(JSON.parse(memory.stdout).rawArrayBufferDelta <= 4194304, true);
    console.log(JSON.stringify({ passed: true, checks, platform: process.platform,
      scope: 'Actual direct child success/failure/output/termination and local identity; descendants remain unknown' }));
  } finally {
    const resolved = path.resolve(directory), relative = path.relative(artifacts, resolved);
    assert(relative.startsWith('task-process-') && !relative.includes(path.sep) && !path.isAbsolute(relative));
    await fs.rm(resolved, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
