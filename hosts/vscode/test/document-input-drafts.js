'use strict';
const assert = require('node:assert/strict');
const { DocumentInputDrafts, MAX_DRAFTS, MAX_FIELD_BYTES, MAX_TOTAL_BYTES } = require('../document-input-drafts');
const { NavigationMemory } = require('../navigation-memory');

async function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { ++checks; assert.deepEqual(actual, expected, message); };
  const throws = (callback, pattern) => { ++checks; assert.throws(callback, pattern); };
  const doc = (uri = 'file:///owned/source.txt', version = 1) => ({
    isClosed: false, version, uri: { toString: () => uri }
  });
  const navigation = new NavigationMemory(), store = new DocumentInputDrafts(navigation), source = doc();
  let lease = store.begin('edit.replace_literal', source);
  eq(lease.value('find'), undefined);
  const findKey = lease.remember('find'), replaceKey = lease.remember('replace');
  eq(typeof findKey, 'string'); eq(Buffer.byteLength(findKey) < 256, true);
  eq(lease.accept('find', '한글😀 needle'), true); eq(lease.value('find'), '한글😀 needle');
  navigation.open(replaceKey, 'input', null, {}).checkpoint({ value: 'unfinished 😀', accepted: false });
  const first = lease;
  lease = store.begin('edit.replace_literal', source);
  eq(lease.value('find'), '한글😀 needle', 'Accepted text remains scalar draft data after the native form closes');
  eq(lease.remember('replace'), replaceKey, 'Reopening the same source keeps its unfinished input key');
  let field = navigation.open(lease.remember('replace'), 'input', null, {});
  eq(field.options.value, 'unfinished 😀'); field.checkpoint({ value: 'unfinished 😀', accepted: false });
  eq(first.accept('find', 'late replacement'), false, 'A newer begin retires writes from the prior invocation');
  eq(first.clear(), false); eq(first.value('find'), undefined); eq(first.remember('find'), undefined);
  eq(lease.value('find'), '한글😀 needle');
  eq(lease.accept('find', '한글😀 needle'), true);
  eq(navigation.views.has(replaceKey), true, 'Reconfirming the same find preserves its unfinished replacement');
  eq(lease.accept('replace', ''), true); eq(lease.value('replace'), '', 'An empty replacement is meaningful');
  eq(navigation.views.has(replaceKey), false, 'Accepting a field retires any old navigation copy');
  navigation.open(replaceKey, 'input', null, {}).checkpoint({ value: 'old replacement', accepted: false });
  eq(lease.accept('find', 'different needle'), true);
  eq(lease.value('replace'), undefined); eq(navigation.views.has(replaceKey), false,
    'Changing find drops both accepted and unfinished replacement context');

  eq(lease.accept('replace', 'accepted replacement'), true);
  eq(lease.accept('find', 'x'.repeat(MAX_FIELD_BYTES + 1)), false);
  eq(lease.value('find'), undefined); eq(lease.value('replace'), undefined,
    'An oversized find cannot revive its old accepted value or dependent replacement');
  eq(lease.accept('find', 'valid'), true); eq(lease.accept('find', '\ud800'), false);
  eq(lease.value('find'), undefined);
  eq(lease.accept('find', 'valid'), true); eq(lease.accept('replace', '\udc00'), false); eq(lease.value('replace'), undefined);
  eq(lease.accept('replace', 'a'.repeat(MAX_FIELD_BYTES)), true);
  eq(lease.value('replace').length, MAX_FIELD_BYTES);
  eq(lease.accept('replace', 'é'.repeat(MAX_FIELD_BYTES / 2 + 1)), false,
    'The limit counts UTF-8 bytes rather than JavaScript characters');
  eq(lease.value('replace'), undefined);
  for (const invalid of [undefined, null, 1, {}, []]) eq(lease.accept('replace', invalid), false);

  let search = store.begin('search.document', source);
  eq(search.accept('query', 'other command'), true); eq(lease.value('find'), 'valid',
    'A query and a replacement draft on the same source do not share accepted fields');
  throws(() => search.value('find'), /Unsupported/);
  throws(() => search.remember('replace'), /Unsupported/);
  throws(() => search.accept('__proto__', 'bad'), /Unsupported/);
  throws(() => store.begin('project.build', source), /no resumable/);
  throws(() => store.begin('__proto__', source), /no resumable/);

  const oldSourceKey = search.remember('query');
  const oldCheckpoint = navigation.open(oldSourceKey, 'input', null, {});
  source.version = 2;
  eq(search.value('query'), undefined); eq(search.accept('query', 'stale'), false);
  eq(store.records.size, 0, 'Source changes prune stale drafts for both document commands');
  eq(navigation.views.has(oldSourceKey), false); eq(oldCheckpoint.checkpoint({ value: 'late old source', accepted: false }), false);
  search = store.begin('search.document', source);
  eq(search.value('query'), undefined); eq(search.remember('query') !== oldSourceKey, true);
  eq(search.accept('query', 'current'), true);
  const reopened = doc(source.uri.toString(), 2), reopenedSearch = store.begin('search.document', reopened);
  eq(reopenedSearch.value('query'), undefined, 'A new document object at the same URI/version does not inherit a closed document draft');
  eq(reopenedSearch.remember('query') !== search.remember('query'), true);
  source.isClosed = true;
  eq(search.remember('query'), undefined); eq(search.clear(), false);
  eq(store.records.size, 1, 'A closed document lease prunes its own record without affecting the reopened document');
  eq(reopenedSearch.accept('query', 'new source'), true);
  reopened.version = NaN;
  eq(reopenedSearch.value('query'), undefined); eq(store.records.size, 0);

  const renamed = doc(), renameLease = store.begin('search.document', renamed);
  renameLease.accept('query', 'before rename'); renamed.uri = { toString: () => 'file:///owned/renamed.txt' };
  eq(renameLease.value('query'), undefined); eq(renameLease.accept('query', 'stale rename'), false);
  const invalidDocument = store.begin('search.document', { version: 0, uri: { toString: () => 'invalid' } });
  eq(invalidDocument.value('query'), undefined); eq(invalidDocument.remember('query'), undefined);
  eq(invalidDocument.accept('query', 'ignored'), false); eq(invalidDocument.clear(), false);

  store.clear();
  const old = store.begin('search.document', doc('file:///owned/old.txt'));
  const oldKey = old.remember('query'); old.accept('query', 'old');
  navigation.open(oldKey, 'input', null, {}).checkpoint({ value: 'old unfinished', accepted: false });
  for (let index = 0; index < MAX_DRAFTS; ++index) {
    store.begin('search.document', doc('file:///owned/item-' + index + '.txt')).accept('query', 'item ' + index);
  }
  eq(store.records.size, MAX_DRAFTS); eq(old.value('query'), undefined); eq(navigation.views.has(oldKey), false,
    'Eviction also removes unfinished input keys');
  eq(old.accept('query', 'late evicted'), false);
  store.clear();
  const largeSources = [];
  for (let index = 0; index < MAX_DRAFTS; ++index) {
    const document = doc('file:///owned/budget-' + index + '.txt'); largeSources.push(document);
    const value = store.begin('edit.replace_literal', document);
    value.accept('find', 'f'.repeat(MAX_FIELD_BYTES)); value.accept('replace', 'r'.repeat(MAX_FIELD_BYTES));
  }
  eq(store.records.size < MAX_DRAFTS, true, 'Total retained bytes have an independent bound');
  eq([...store.records.values()].reduce((sum, record) => sum + Buffer.byteLength(JSON.stringify(record), 'utf8'), 0) <= MAX_TOTAL_BYTES, true);
  const checkData = value => {
    if (value && typeof value === 'object') {
      eq(Array.isArray(value), false); eq(Object.getPrototypeOf(value), Object.prototype);
      for (const child of Object.values(value)) checkData(child);
    } else eq(['string', 'number', 'boolean'].includes(typeof value), true, 'Cache records contain only bounded data, never source/editor handles or callbacks');
  };
  for (const record of store.records.values()) checkData(record);

  const noNavigation = new DocumentInputDrafts();
  const independent = noNavigation.begin('search.document', largeSources[largeSources.length - 1]);
  const finalSource = doc('file:///owned/reset.txt'), finalLease = store.begin('search.document', finalSource);
  eq(independent.remember('query').startsWith(store.namespace), false, 'Host owners have distinct navigation namespaces');
  finalLease.accept('query', 'clear me');
  const pendingKey = finalLease.remember('query'), pending = navigation.open(pendingKey, 'input', null, {});
  eq(store.clear(), true); eq(finalLease.value('query'), undefined); eq(finalLease.accept('query', 'late reset'), false);
  eq(pending.checkpoint({ value: 'late reset input', accepted: false }), false);
  eq(navigation.views.has(pendingKey), false);
  eq(store.clear(), false);
  noNavigation.dispose(); eq(independent.value('query'), undefined); eq(independent.accept('query', 'late disposed'), false);
  throws(() => noNavigation.begin('search.document', doc()), /disposed/);
  noNavigation.dispose(); store.dispose();
  return { passed: true, checks, scope: 'Bounded scalar document-input drafts, source identity/version ownership, invalid-value refusal, replacement dependency and navigation retirement; no execution or physical UI claim' };
}

if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
