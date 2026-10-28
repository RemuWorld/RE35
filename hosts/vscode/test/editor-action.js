'use strict';
const assert = require('node:assert/strict');
const { createEditorAction, prepareEdits } = require('../editor-action');
const { fixture } = require('./editor-fixture');
const edit = (start, end, text, line = 0) => ({ range: { start: { line, character: start }, end: { line, character: end } }, text });
async function run() {
  let checks = 0; const eq = (a, b, label) => { assert.deepEqual(a, b, label); ++checks; };
  function setup(text = '한글 😀 word   ') {
    const f = fixture(text); let nativeCalls = 0, availability = { available: true };
    const apply = createEditorAction({ vscode: f.vscode, getBridge: () => { ++nativeCalls; throw new Error('An editor observation must never acquire Neovim'); }, observationEngine: 'editor', editorAvailable: () => availability });
    return { ...f, apply, options: extra => ({ source: { editor: f.editor, version: f.doc.version }, ...extra }), nativeCalls: () => nativeCalls,
      available(value) { availability = value; } };
  }
  const f = setup(); let admitted = 0, declared;
  const ordinary = fixture('word');
  const ordinaryApply = createEditorAction({ vscode: ordinary.vscode });
  eq((await ordinaryApply([edit(0, 4, 'WORD')], { source: { editor: ordinary.editor, version: ordinary.doc.version } })).mode, 'editor',
    'The default editor adapter has no native-bridge dependency');
  eq(ordinary.doc.getText(), 'WORD');
  const result = await f.apply([edit(10, 13, '')], f.options({ onAdmit() { ++admitted; }, expectEditorChange(value) { declared = value; } }));
  eq(f.doc.getText(), '한글 😀 word'); eq(result.status, 'succeeded'); eq(result.mode, 'editor'); eq(result.observed, true); eq(result.sourceVersion, 2);
  eq(admitted, 1); eq(declared, { text: '한글 😀 word', allowSelection: true }); eq(f.nativeCalls(), 0);
  eq(f.edits.length, 1); eq(f.edits[0].options, { undoStopBefore: true, undoStopAfter: true });
  const multi = setup('first second third'); await multi.apply([edit(0, 5, '1'), edit(13, 18, '3')], multi.options());
  eq(multi.doc.getText(), '1 second 3'); eq(multi.edits.length, 1, 'Multiple explicit edits stay one authoring API call');

  const unicode = setup('😀 word');
  for (const changes of [[edit(1, 2, 'x')], [edit(0, 1, 'x')], [edit(0, 0, '\uD800')], [edit(0, 0, '\uDC00')]]) {
    await assert.rejects(unicode.apply(changes, unicode.options()), /Unicode/); ++checks;
  }
  eq(unicode.edits.length, 0);
  const bounds = setup('abcd');
  for (const changes of [[], [edit(2, 1, '')], [edit(-1, 0, '')], [edit(0, 20, '')], [edit(0, 2, ''), edit(1, 2, '')], [edit(0, 0, 'a'), edit(0, 0, 'b')], [edit(0, 0, 'x'.repeat(256 * 1024 + 1))]]) {
    await assert.rejects(bounds.apply(changes, bounds.options()), /explicit|reversed|coordinate|overlap|256 KiB/); ++checks;
  }
  assert.throws(() => prepareEdits(unicode.doc, Array(257).fill(edit(0, 0, '')), unicode.vscode.Position), /1–256/); ++checks;
  assert.throws(() => createEditorAction({ vscode: f.vscode, getBridge() {}, observationEngine: 'unknown' }), /Unknown/); ++checks;

  const stale = setup('word'), previous = stale.options(); stale.type(' input');
  await assert.rejects(stale.apply([edit(0, 4, 'WORD')], previous), /source changed/); ++checks; eq(stale.edits.length, 0);
  const cancel = new AbortController(); cancel.abort();
  await assert.rejects(stale.apply([edit(0, 4, 'WORD')], stale.options({ signal: cancel.signal })), /before application/); ++checks;
  const changedAtAdmit = setup('word');
  await assert.rejects(changedAtAdmit.apply([edit(0, 4, 'WORD')], changedAtAdmit.options({ onAdmit() { changedAtAdmit.type(' input'); } })), /before application/); ++checks; eq(changedAtAdmit.edits.length, 0);
  const off = setup('word'); off.available({ available: false, reason: 'Explicitly disable the native editing engine' });
  await assert.rejects(off.apply([edit(0, 4, 'WORD')], off.options()), /disable/); ++checks; eq(off.nativeCalls(), 0); eq(off.edits.length, 0);
  off.available({ available: true }); off.focus(false);
  await assert.rejects(off.apply([edit(0, 4, 'WORD')], off.options()), /not focused/); ++checks;

  const raced = setup('word'); raced.editHook(async stage => { if (stage === 'after') raced.type(' input'); });
  await assert.rejects(raced.apply([edit(0, 4, 'WORD')], raced.options()), /result changed/); ++checks; eq(raced.doc.getText(), 'WORD input', 'The helper retains concurrent input and reports an unconfirmed result');
  const revision = setup('word'); revision.editHook(async stage => { if (stage === 'after') revision.doc.version += 2; });
  await assert.rejects(revision.apply([edit(0, 4, 'WORD')], revision.options()), /result changed/); ++checks;
  const lost = setup('word'); lost.editHook(async stage => { if (stage === 'after') lost.focus(false); });
  await assert.rejects(lost.apply([edit(0, 4, 'WORD')], lost.options()), /result changed/); ++checks;
  const check = setup('word'); let valid = true; check.editHook(async stage => { if (stage === 'after') valid = false; });
  await assert.rejects(check.apply([edit(0, 4, 'WORD')], check.options({ check() { if (!valid) throw new Error('Registration owner changed'); } })), cause => cause.effects === 'applied-but-unconfirmed' && cause.message.includes('owner changed')); ++checks;
  const held = setup('word'), gate = held.deferred(); held.editHook(async stage => { if (stage === 'after') await gate.promise; });
  const pending = held.apply([edit(0, 4, 'WORD')], held.options());
  await assert.rejects(held.apply([edit(0, 4, 'word')], held.options()), /already running/); ++checks; gate.resolve(); await pending;
  return { checks, scope: 'Controlled public editor API: bounded Unicode edits, source/registration guards, nonnative observation, concurrent input, no physical/host claim' };
}
if (require.main === module) run().then(result => console.log(JSON.stringify(result))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
