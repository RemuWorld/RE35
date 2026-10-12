'use strict';
const { spawn } = require('node:child_process');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const MAX_BYTES = 1024 * 1024;
class Backend {
  constructor(options) {
    for (const key of ['helperPath', 'luaRuntime', 'corePath']) {
      if (typeof options[key] !== 'string' || !path.isAbsolute(options[key]) || options[key].includes('\0')) {
        throw new Error(`Configure an absolute RE35 ${key} path before opening the environment`);
      }
    }
    this.closed = false;
    this.lossListeners = new Set();
    this.queue = [];
    this.pending = null;
    this.buffer = Buffer.alloc(0);
    this.child = spawn(options.helperPath, [options.luaRuntime, options.corePath], {
      stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, shell: false
    });
    this.child.stdout.on('data', chunk => this.receive(chunk));
    // Do not retain child diagnostics or host paths in user results.
    this.child.stderr.resume();
    this.child.on('error', () => this.fail(new Error('Could not start the configured RE35 core helper')));
    this.child.on('exit', () => this.fail(new Error('RE35 core helper closed; reopen the environment to retry')));
    this.child.stdin.on('error', () => this.fail(new Error('RE35 core input closed')));
  }
  call(operation, data = {}, options = {}) {
    if (this.closed) return Promise.reject(new Error('RE35 core helper is closed'));
    if (!/^[a-z_]{1,64}$/.test(operation)) return Promise.reject(new Error('Invalid core operation'));
    const timeout = options.timeoutMs === undefined ? 10000 : options.timeoutMs;
    if (!Number.isInteger(timeout) || timeout < 1 || timeout > 10000) return Promise.reject(new Error('Invalid core request timeout'));
    if (this.queue.length + (this.pending ? 1 : 0) >= 16) return Promise.reject(new Error('Too many pending core requests'));
    let frame;
    try { frame = Buffer.from(operation + '\t' + JSON.stringify(data) + '\n', 'utf8'); }
    catch (_) { return Promise.reject(new Error('Core request must be finite JSON data')); }
    if (frame.length > MAX_BYTES + operation.length + 2) return Promise.reject(new Error('Core request exceeds its byte limit'));
    return new Promise((resolve, reject) => {
      const request = { frame, resolve, reject };
      request.timer = setTimeout(() => this.fail(new Error('RE35 core request timed out; review the target again')), timeout);
      this.queue.push(request);
      this.drain();
    });
  }
  drain() {
    if (this.closed || this.pending || !this.queue.length) return;
    this.pending = this.queue.shift();
    this.child.stdin.write(this.pending.frame);
  }
  receive(chunk) {
    if (this.closed) return;
    // A frame can span chunks, but never grow without a finite bound.
    if (this.buffer.length + chunk.length > MAX_BYTES + 1) return this.fail(new Error('Core response exceeds its byte limit'));
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const newline = this.buffer.indexOf(10);
    if (newline < 0) return;
    const response = this.buffer.subarray(0, newline);
    const remaining = this.buffer.subarray(newline + 1);
    if (!this.pending || remaining.length) return this.fail(new Error('Unexpected core response framing'));
    this.buffer = Buffer.alloc(0);
    const pending = this.pending;
    this.pending = null;
    clearTimeout(pending.timer);
    try {
      const envelope = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(response));
      if (!envelope || typeof envelope.ok !== 'boolean') throw new Error('Invalid core response');
      if (!envelope.ok) {
        if (typeof envelope.error !== 'string') throw new Error('Invalid core error');
        pending.reject(new Error(envelope.error));
      } else pending.resolve(envelope.value);
    } catch (error) { pending.reject(error); this.fail(new Error('Invalid core response')); return; }
    this.drain();
  }
  fail(error) {
    if (this.closed) return;
    this.closed = true;
    for (const listener of this.lossListeners) { try { listener(error); } catch (_) { /* Resource owners settle independently. */ } }
    this.lossListeners.clear();
    this.buffer = Buffer.alloc(0);
    if (this.pending) {
      clearTimeout(this.pending.timer);
      this.pending.reject(error);
      this.pending = null;
    }
    for (const request of this.queue.splice(0)) { clearTimeout(request.timer); request.reject(error); }
    this.child.stdin.destroy();
    this.child.stdout.destroy();
    this.child.kill();
  }
  dispose() { this.fail(new Error('RE35 host disposed')); }
  onClosed(listener) {
    if (this.closed) listener(new Error('RE35 core helper is closed'));
    else this.lossListeners.add(listener);
    return () => this.lossListeners.delete(listener);
  }
}
module.exports = { Backend };
