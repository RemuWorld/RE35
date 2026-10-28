'use strict';

// Convenience data for direct document commands. Source receipts, editor handles
// and approval never enter the cache; an invocation still validates its source.
const MAX_DRAFTS = 8, MAX_FIELD_BYTES = 4096, MAX_TOTAL_BYTES = 32768;
const fields = Object.freeze({
  'search.document': Object.freeze(['query']),
  'edit.replace_literal': Object.freeze(['find', 'replace'])
});
let ownerSerial = 0;
const validText = value => typeof value === 'string'
  && !/[\ud800-\udfff]/u.test(value.replace(/[\ud800-\udbff][\udc00-\udfff]/g, ''));
const recordBytes = record => Buffer.byteLength(JSON.stringify(record), 'utf8');

class DocumentInputDrafts {
  constructor(navigation = null) {
    if (navigation !== null && (typeof navigation !== 'object' || typeof navigation.clear !== 'function')) {
      throw new Error('Document input drafts need navigation memory or no navigation');
    }
    this.navigation = navigation;
    this.namespace = 'document.input.' + (++ownerSerial) + '.';
    this.documents = new WeakMap();
    this.documentSerial = 0; this.recordSerial = 0; this.ticketSerial = 0;
    this.records = new Map(); this.disposed = false;
  }
  source(document) {
    try {
      if (!document || typeof document !== 'object' || document.isClosed
        || !Number.isSafeInteger(document.version) || document.version < 1) return null;
      const uri = document.uri.toString();
      if (!validText(uri) || !uri || Buffer.byteLength(uri, 'utf8') > MAX_TOTAL_BYTES) return null;
      return { uri, version: document.version };
    } catch (_) { return null; }
  }
  forget(record) {
    if (this.records.get(record.key) !== record) return false;
    this.records.delete(record.key);
    if (this.navigation) this.navigation.clear(record.prefix);
    return true;
  }
  prune(documentId, source) {
    for (const record of this.records.values()) {
      if (record.document === documentId && (!source || record.uri !== source.uri || record.version !== source.version)) this.forget(record);
    }
  }
  bound() {
    let bytes = [...this.records.values()].reduce((total, record) => total + recordBytes(record), 0);
    while (this.records.size > MAX_DRAFTS || bytes > MAX_TOTAL_BYTES) {
      const record = this.records.values().next().value;
      bytes -= recordBytes(record); this.forget(record);
    }
  }
  begin(command, document) {
    if (this.disposed) throw new Error('Document input draft owner is disposed');
    if (!Object.hasOwn(fields, command)) throw new Error('This command has no resumable document inputs');
    const allowed = fields[command], source = this.source(document);
    let documentId = document && typeof document === 'object' ? this.documents.get(document) : undefined;
    if (!source) {
      if (documentId !== undefined) this.prune(documentId, null);
    } else if (documentId === undefined) {
      documentId = ++this.documentSerial; this.documents.set(document, documentId);
    }
    if (source) this.prune(documentId, source);
    const key = documentId + ':' + command;
    let record = source && this.records.get(key);
    if (source && !record) {
      record = { key, document: documentId, command, uri: source.uri, version: source.version,
        prefix: this.namespace + (++this.recordSerial) + '.', ticket: 0, fields: {} };
    }
    const ticket = ++this.ticketSerial;
    if (record) {
      record.ticket = ticket;
      this.records.delete(key); this.records.set(key, record); this.bound();
    }
    const field = name => {
      if (!allowed.includes(name)) throw new Error('Unsupported document input field: ' + name);
      return record && record.prefix + name;
    };
    const live = () => {
      if (this.disposed || !record || this.records.get(key) !== record || record.ticket !== ticket) return false;
      const current = this.source(document);
      if (!current || current.uri !== record.uri || current.version !== record.version) {
        this.prune(documentId, current); return false;
      }
      return true;
    };
    const removeField = name => {
      delete record.fields[name];
      if (this.navigation) this.navigation.clear(record.prefix + name);
    };
    return Object.freeze({
      value: name => { field(name); return live() ? record.fields[name] : undefined; },
      remember: name => { const key = field(name); return live() ? key : undefined; },
      accept: (name, value) => {
        field(name); if (!live()) return false;
        const valid = validText(value) && Buffer.byteLength(value, 'utf8') <= MAX_FIELD_BYTES;
        // A new find has a different replacement context. Even a refused find
        // drops old dependent text, rather than reviving an obsolete draft.
        if (name === 'find' && (!valid || value !== record.fields.find)) removeField('replace');
        removeField(name);
        if (!valid) return false;
        record.fields[name] = value;
        this.records.delete(key); this.records.set(key, record); this.bound();
        return this.records.get(key) === record;
      },
      clear: () => live() ? this.forget(record) : false
    });
  }
  clear() {
    const changed = this.records.size > 0;
    this.records.clear();
    if (this.navigation) this.navigation.clear(this.namespace);
    return changed;
  }
  dispose() {
    if (this.disposed) return;
    this.clear(); this.disposed = true; this.documents = new WeakMap(); this.navigation = null;
  }
}

module.exports = { DocumentInputDrafts, MAX_DRAFTS, MAX_FIELD_BYTES, MAX_TOTAL_BYTES };
