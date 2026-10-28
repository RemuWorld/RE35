'use strict';
const assert = require('node:assert/strict');
const { projectInputFlow } = require('../input-flow-view');
function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); ++checks; };
  const ok = (actual, message) => { assert.ok(actual, message); ++checks; };
  eq(projectInputFlow().visible, false, 'An unused input view stays hidden');
  eq(projectInputFlow({ input: null, trace: null }).visible, false);
  const native = value => projectInputFlow({ trace: { enabled: true, ready: true, text: value } });
  for (const text of ['g', 'gg', 'ggV', 'ggVG']) {
    const view = native(text); ok(view.text.includes(text + ' · Observed')); ok(!view.text.includes('✓'));
    ok(view.tooltip.includes('command completion is not inferred'));
  }
  const history = [{ id: 1, text: 'gg', closed: true, reason: 'window_focus_lost', source: 'file:///a.cpp' }];
  const paused = projectInputFlow({ trace: { enabled: true, paused: true, text: '', history } });
  eq(paused.visible, true); ok(paused.text.includes('gg · Observed · Paused'));
  ok(paused.tooltip.includes('Window focus lost')); eq(paused.historyItems[0].closed, true);
  const resumed = projectInputFlow({ trace: { enabled: true, ready: true, text: 'VG', history: [...history,
    { id: 2, text: 'VG', gapBefore: { reason: 'window_focus_lost' }, closed: false }] } });
  ok(resumed.text.includes('VG · Observed · Gap before'));
  ok(!resumed.text.includes('ggVG'), 'Separate segments never look like one uninterrupted native flow');
  eq(resumed.historyItems.filter(item => item.kind === 'native').length, 2);
  ok(resumed.historyItems[0].detail.includes('Gap before: Window focus lost'));
  const rows = ['succeeded', 'queued', 'executing', 'failed', 'cancelled', 'stopped', 'passthrough', 'uncertain', 'surprise'];
  for (const status of rows) {
    const view = projectInputFlow({ input: { tokens: [{ token: 'F9', status, sequence: 3, reason: 'reason' }] } });
    eq(view.text.includes('✓'), status === 'succeeded', 'Only an observed success receipt earns a completion mark: ' + status);
    eq(view.historyItems[0].status, status); ok(view.tooltip.includes('reason'));
  }
  const mixed = projectInputFlow({ input: { enabled: true, tokens: [{ token: 'F9', status: 'succeeded' }, { token: 'F6', status: 'executing' }] },
    trace: { enabled: true, text: 'ggVG' } });
  ok(mixed.text.includes('F9 ✓ › F6 Running')); ok(mixed.text.includes('ggVG · Observed'));
  ok(!mixed.text.includes('ggVG ✓')); eq(mixed.historyItems.map(item => item.kind), ['action', 'action', 'native']);
  ok(mixed.tooltip.includes('\n'), 'Tooltip keeps channel headings and observations on separate lines');
  const blocked = projectInputFlow({ input: { blocked: true, tokens: [{ token: 'F9', status: 'failed' }] } });
  ok(blocked.text.includes('Inspect outcome')); ok(blocked.tooltip.includes('effect may be uncertain'));
  const unicode = native('x'.repeat(30) + 'e\u0301👩‍👩‍👧‍👦한글');
  ok(unicode.text.includes('e\u0301👩‍👩‍👧‍👦한글')); ok(!unicode.text.includes('\ufffd'));
  const notation = native('x'.repeat(30) + '<C-Left>'); ok(notation.text.includes('<C-Left>'));
  ok(!native('x'.repeat(30) + '<' + 'A'.repeat(40) + '>').text.includes('A'), 'Overlong key notation is omitted whole');
  const emojiBoundary = native('a'.repeat(25) + '👩‍👩‍👧‍👦'.repeat(4));
  ok(!emojiBoundary.text.includes('\ufffd')); ok(!emojiBoundary.text.includes('…‍'));
  const injector = native('$(check)'); ok(!injector.text.includes('$(check)'));
  ok(injector.tooltip.includes('$(check)'), 'A plain text tooltip retains data without enabling Markdown commands');
  const tokens = Array.from({ length: 200 }, (_, index) => ({ token: 'F' + index, sequence: index, status: 'succeeded' }));
  const segments = Array.from({ length: 20 }, (_, index) => ({ id: index, text: 'w'.repeat(10000), closed: true, reason: 'source_changed' }));
  const bounded = projectInputFlow({ input: { tokens }, trace: { history: segments, truncation: { segments: 12, tokens: 20 } } });
  eq(bounded.historyItems.filter(item => item.kind === 'action').length, 128);
  eq(bounded.historyItems.filter(item => item.kind === 'native').length, 8);
  ok(Array.from(bounded.tooltip).length <= 32768); ok(bounded.text.length < 200);
  const source = { input: { source: 'file:///a.cpp', tokens: [{ token: 'F9', status: 'queued', reason: 'why' }] },
    trace: { history: [{ id: 1, text: 'gg', closed: false }] } };
  const before = JSON.stringify(source), isolated = projectInputFlow(source);
  isolated.historyItems[0].label = 'changed'; eq(JSON.stringify(source), before, 'Projection and its consumers cannot mutate source execution state');
  const trimmed = projectInputFlow({ trace: { history: [{ text: 'w', truncated: true, droppedTokens: 14 }] } });
  ok(trimmed.historyItems[0].detail.includes('14 tokens'));
  const fallback = projectInputFlow({ trace: { history: [{ tokens: [{ token: 'g' }, { token: 'g' }, { token: 'V' }] }] } });
  ok(fallback.text.includes('ggV · Observed'));
  const original = projectInputFlow({ input: { source: 'file:///new.cpp', profile: 'new-profile', tokens: [
    { token: 'F6', status: 'succeeded', source: 'file:///original.cpp', profile: 'original-profile', recordedAt: 1234 }] } });
  eq(original.historyItems[0].source, 'file:///original.cpp', 'History retains original source, rather than a later active editor');
  eq(original.historyItems[0].profile, 'original-profile'); eq(original.historyItems[0].recordedAt, 1234);
  const gap = projectInputFlow({ input: { tokens: [{ token: 'F9', status: 'succeeded', segment: 1 },
    { token: 'F6', status: 'succeeded', segment: 2 }, { token: 'F10', status: 'queued', segment: 2 }] } });
  ok(!gap.text.includes('F9'), 'Statusbar never joins actions across separate input segments');
  ok(gap.text.includes('F6 ✓ › F10 Queued')); eq(gap.historyItems.length, 3);
  const sourceGap = projectInputFlow({ input: { tokens: [{ token: 'F9', status: 'succeeded', source: 'old' },
    { token: 'F6', status: 'succeeded', source: 'new' }] } });
  ok(!sourceGap.text.includes('F9'), 'Different action sources cannot appear continuous');
  for (const status of ['failed', 'cancelled', 'stopped']) {
    const unconfirmed = projectInputFlow({ input: { tokens: [{ token: 'F6', status, admitted: true, observed: false }] } });
    ok(unconfirmed.text.includes('Outcome unknown')); eq(unconfirmed.historyItems[0].status, status);
    ok(unconfirmed.historyItems[0].detail.includes('effect was not confirmed'));
  }
  const confirmedFailure = projectInputFlow({ input: { tokens: [{ token: 'F6', status: 'failed', admitted: true, observed: true }] } });
  ok(confirmedFailure.text.includes('Failed')); ok(!confirmedFailure.text.includes('Outcome unknown'));
  const fullNative = 'x'.repeat(32768) + 'ggVG';
  const retained = projectInputFlow({ trace: { history: [{ text: fullNative }] } });
  eq(retained.historyItems[0].text, fullNative, 'Inspector keeps all native text within the producer budget');
  ok(retained.text.includes('ggVG · Observed')); eq(retained.historyItems[0].projectionTruncated, false);
  const giantToken = projectInputFlow({ input: { tokens: [{ token: 'x'.repeat(1000), status: 'succeeded' }] } });
  ok(giantToken.text.length < 50, 'Trusted but overlong token text cannot consume the statusbar');
  const omitted = projectInputFlow({ input: { enabled: true, historyDropped: 17, tokens: [{ token: 'F9', status: 'succeeded' }] } });
  ok(omitted.tooltip.includes('17 earlier action receipts omitted.'));
  eq(omitted.historyItems.find(item => item.kind === 'notice')?.label, '17 earlier action receipts omitted',
    'Explicit inspection and the tooltip both disclose omitted action receipts');
  return { passed: true, checks, scope: 'Pure input-flow presentation, truthful action receipts versus native observations, retained gaps, bounded history and grapheme-safe text; no execution or physical-key claim' };
}
if (require.main === module) { try { console.log(JSON.stringify(run())); } catch (cause) { console.error(cause); process.exitCode = 1; } }
module.exports = { run };
