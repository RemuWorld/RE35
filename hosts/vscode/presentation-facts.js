'use strict';
const { randomUUID } = require('node:crypto');
const LIMIT = 1024 * 1024;

// Native list detail can be elided. This immutable, read-only document is a
// separate way to inspect the exact original facts; it carries no action links.
class FactsDocument {
  constructor(ui) { this.ui = ui; this.scheme = 're35-facts-' + randomUUID(); this.provider = null; this.snapshot = null; this.disposed = false; }
  supported() {
    const ui = this.ui;
    return !this.disposed && typeof ui.ThemeIcon === 'function' && ui.Uri && typeof ui.Uri.parse === 'function'
      && typeof ui.workspace.registerTextDocumentContentProvider === 'function'
      && typeof ui.workspace.openTextDocument === 'function' && typeof ui.window.showTextDocument === 'function';
  }
  content(items, title) {
    if (!Array.isArray(items) || (title !== undefined && typeof title !== 'string')) {
      throw new Error('Complete facts require rows and a plain text title');
    }
    const parts = ['RE35 — ' + (title || 'Complete facts'),
      'Immutable display snapshot. This document cannot approve, save or run an operation.', ''];
    let bytes = Buffer.byteLength(parts.join('\n'), 'utf8');
    if (bytes > LIMIT) throw new Error('Complete facts exceed the 1 MiB read-only display limit');
    for (const item of items) {
      for (const key of ['label', 'description', 'detail']) {
        if (item[key] === undefined) continue;
        if (typeof item[key] !== 'string') throw new Error('Facts must be plain text');
        bytes += Buffer.byteLength(item[key], 'utf8') + 1;
        if (bytes > LIMIT) throw new Error('Complete facts exceed the 1 MiB read-only display limit');
        parts.push(item[key]);
      }
      parts.push(''); ++bytes;
      if (bytes > LIMIT) throw new Error('Complete facts exceed the 1 MiB read-only display limit');
    }
    return parts.join('\n');
  }
  async open(items, title, verifyOwner) {
    if (!this.supported()) throw new Error('Read-only facts are unavailable');
    if (typeof verifyOwner !== 'function') throw new Error('Complete facts require an owner check');
    verifyOwner();
    const text = this.content(items, title);
    const uri = this.ui.Uri.parse(this.scheme + ':/' + randomUUID() + '/facts.txt');
    this.snapshot = { key: uri.toString(), text };
    if (!this.provider) this.provider = this.ui.workspace.registerTextDocumentContentProvider(this.scheme, {
      provideTextDocumentContent: requested => {
        if (this.disposed || !this.snapshot || requested.toString() !== this.snapshot.key) throw new Error('Facts snapshot is retired');
        return this.snapshot.text;
      }
    });
    const document = await this.ui.workspace.openTextDocument(uri); verifyOwner();
    await this.ui.window.showTextDocument(document, { preview: true, preserveFocus: true }); verifyOwner();
    return document;
  }
  dispose() {
    this.disposed = true; this.snapshot = null;
    if (this.provider) this.provider.dispose();
    this.provider = null; this.ui = null;
  }
}
module.exports = { FactsDocument, LIMIT };
