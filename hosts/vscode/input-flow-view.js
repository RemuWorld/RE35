'use strict';
// A read-only projection. Observed native keys are never execution receipts.
const segmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });
const LIMIT = Object.freeze({ actions: 128, segments: 8, recentActions: 3, nativeDisplay: 24,
  segmentText: 65536, reason: 1024, tooltip: 32768 });
const STATUS = Object.freeze({ succeeded: ['✓', 'Completed'], queued: ['Queued', 'Queued'],
  executing: ['Running', 'Running'], failed: ['Failed', 'Failed'], cancelled: ['Cancelled', 'Cancelled'],
  stopped: ['Stopped', 'Stopped'], passthrough: ['Native', 'Handed to native input; completion unconfirmed'],
  rejected: ['Rejected', 'Rejected'], uncertain: ['Uncertain', 'Uncertain'] });
const GAP = Object.freeze({ window_focus_lost: 'Window focus lost', source_changed: 'Source changed',
  unsupported_mode: 'Input mode excluded', profile_changed: 'Input profile changed',
  input_queue_limit: 'Input queue limit reached', sequence_gap: 'Observation sequence gap',
  connection_failed: 'Observation connection failed', disposed: 'Observation ended',
  paused: 'Paused', reset: 'Input cleared', 'RE35 command interface': 'RE35 interface opened' });

function count(value) { return Array.from(value).length; }
function plain(value, max = LIMIT.reason, multiline = false) {
  if (typeof value !== 'string') return '';
  const clean = value.replace(multiline ? /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g : /[\u0000-\u001f\u007f-\u009f]/g, ' ');
  if (count(clean) <= max) return clean;
  let result = '', used = 0;
  for (const part of segmenter.segment(clean)) {
    const size = count(part.segment); if (used + size > max - 1) break;
    result += part.segment; used += size;
  }
  return result + '…';
}
function reason(value) { return GAP[value] || plain(value); }
// Keep <C-Left>, combining marks and ZWJ emoji whole when showing a suffix.
function nativeSuffix(value, max = LIMIT.nativeDisplay) {
  const text = plain(value, LIMIT.segmentText), total = count(text);
  if (total <= max) return text;
  const graphemes = segmenter.segment(text);
  let result = '', used = 1, cursor = text.length;
  while (cursor > 0) {
    let unit = graphemes.containing(cursor - 1), start = unit.index, part = unit.segment;
    if (text[cursor - 1] === '>') {
      const key = /<[^<>\r\n]{1,80}>$/.exec(text.slice(Math.max(0, cursor - 82), cursor));
      if (key) { part = key[0]; start = cursor - part.length; }
    }
    const size = count(part); if (used + size > max) break;
    result = part + result; used += size; cursor = start;
  }
  return '…' + result;
}
function status(value) { return STATUS[value] || ['Unconfirmed', 'Unconfirmed']; }
function actionRows(input) {
  if (!Array.isArray(input.tokens)) return [];
  return input.tokens.slice(-LIMIT.actions).filter(item => item && typeof item.token === 'string').map((item, index) => {
    const token = plain(item.token, 128), uncertain = item.status !== 'succeeded' &&
      (item.admitted === true && item.observed !== true && ['failed', 'cancelled', 'stopped'].includes(item.status)
        || input.blocked === true && index === Math.min(input.tokens.length, LIMIT.actions) - 1);
    const [short, label] = uncertain ? ['Outcome unknown', 'Outcome unknown'] : status(item.status);
    const why = plain(item.reason), source = plain(item.source || input.source, 2048), profile = plain(item.profile || input.profile, 256);
    const segment = typeof item.segment === 'string' ? plain(item.segment, 128) : Number.isSafeInteger(item.segment) ? item.segment : null;
    return { kind: 'action', id: 'action:' + (segment ?? '') + ':' + (Number.isSafeInteger(item.sequence) ? item.sequence : index),
      label: token + ' · ' + label, description: 'RE35 action' + (Number.isSafeInteger(item.sequence) ? ' · #' + item.sequence : ''),
      detail: [uncertain && 'Reported status: ' + status(item.status)[1] + '; the admitted effect was not confirmed.', why,
        segment !== null && 'Segment: ' + segment, profile && 'Profile: ' + profile, source].filter(Boolean).join('\n'),
      source, token, status: item.status || 'unconfirmed', statusLabel: label, uncertain,
      reason: why, short, sequence: item.sequence, profile, segment, admitted: item.admitted === true, observed: item.observed === true,
      recordedAt: Number.isFinite(item.recordedAt) ? item.recordedAt : null,
      completedAt: Number.isFinite(item.completedAt) ? item.completedAt : null };
  });
}
function nativeRows(trace) {
  const supplied = Array.isArray(trace.history) ? trace.history.slice(-LIMIT.segments) : [];
  // Older observers expose only their active text. Never append it to a closed
  // history segment, because the gap may include unobserved editing.
  const active = plain(trace.text || '', LIMIT.segmentText);
  if (!supplied.length && active) supplied.push({ id: 'legacy', text: active, source: trace.source,
    closed: trace.paused === true, reason: trace.paused ? trace.pauseReason || trace.message : null });
  return supplied.filter(item => item && typeof item === 'object').map((item, index) => {
    const fallback = Array.isArray(item.tokens) ? item.tokens.slice(-128).map(token => plain(token?.token, 256)).join('') : '';
    const originalText = typeof item.text === 'string' ? item.text : fallback;
    const projectionTruncated = count(originalText) > LIMIT.segmentText;
    const text = plain(originalText, LIMIT.segmentText);
    const source = plain(item.source || trace.source, 2048), boundary = reason(item.reason), gapBefore = reason(item.gapBefore?.reason || item.gapBefore);
    const closed = item.closed === true, dropped = Number.isSafeInteger(item.droppedTokens) && item.droppedTokens > 0 ? item.droppedTokens : 0;
    const facts = [text, 'Observed native input; command completion is not inferred.',
      gapBefore && 'Gap before: ' + gapBefore, closed && 'Segment ended: ' + (boundary || 'Observation paused'),
      item.truncated || dropped ? 'Earlier input omitted' + (dropped ? ': ' + dropped + ' tokens' : '') : '',
      projectionTruncated && 'Display limit reached; retained native text was shortened.', source];
    return { kind: 'native', id: 'native:' + plain(String(item.id ?? index), 128),
      label: (text ? nativeSuffix(text, 64) : 'No observed keys') + ' · Observed',
      description: closed ? 'Closed segment · ' + (boundary || 'Observation paused') : gapBefore ? 'New segment · Gap before' : 'Current segment',
      detail: facts.filter(Boolean).join('\n'), source, text, closed, reason: boundary, gapBefore,
      truncated: item.truncated === true || dropped > 0, droppedTokens: dropped, projectionTruncated,
      startedAt: Number.isFinite(item.startedAt) ? item.startedAt : null,
      endedAt: Number.isFinite(item.endedAt) ? item.endedAt : null };
  });
}
function projectInputFlow({ input = {}, trace = {} } = {}) {
  input = input || {}; trace = trace || {};
  const actions = actionRows(input), segments = nativeRows(trace), last = segments.at(-1), latestAction = actions.at(-1);
  let start = actions.length - 1;
  while (start > 0 && actions[start - 1].segment === latestAction.segment && actions[start - 1].source === latestAction.source
    && actions[start - 1].profile === latestAction.profile) --start;
  const recent = actions.slice(Math.max(start, actions.length - LIMIT.recentActions));
  const visible = !!(input.enabled || input.blocked || trace.enabled || actions.length || segments.length);
  if (!visible) return { visible: false, text: '', tooltip: '', description: '', historyItems: [] };
  const actionText = recent.map(item => nativeSuffix(item.token, 12) + ' ' + item.short).join(' › ');
  const parts = ['RE35' + (actionText ? ' ' + actionText : '')];
  if (input.blocked) parts.push('Inspect outcome');
  else if (input.suspended) parts.push('Paused');
  else if (input.busy && !recent.some(item => item.status === 'executing' || item.status === 'queued')) parts.push('Running');
  if (last?.text) {
    const state = trace.paused ? 'Paused' : last.closed ? 'Gap' : last.gapBefore ? 'Gap before' : '';
    parts.push(nativeSuffix(last.text) + ' · Observed' + (state ? ' · ' + state : ''));
  } else if (!actionText) parts.push(trace.paused ? 'Observation paused' : trace.enabled ? trace.ready ? 'Observing' : 'Connecting' : 'Input');
  const droppedActions = Number.isSafeInteger(input.historyDropped) && input.historyDropped > 0 ? input.historyDropped : 0;
  const actionNotice = droppedActions ? { kind: 'notice', id: 'action-history-omitted',
    label: droppedActions + ' earlier action receipts omitted', description: 'RE35 action history limit',
    detail: 'Only the most recent ' + LIMIT.actions + ' RE35 action receipts are retained. Omission is a display-history boundary, not an execution result.' } : null;
  const historyItems = [...actions.slice().reverse(), ...(actionNotice ? [actionNotice] : []), ...segments.slice().reverse()];
  const omitted = trace.truncation && (trace.truncation.segments || trace.truncation.tokens)
    ? 'Earlier observed history omitted: ' + (Number.isSafeInteger(trace.truncation.segments) ? trace.truncation.segments : 0) + ' segments, '
      + (Number.isSafeInteger(trace.truncation.tokens) ? trace.truncation.tokens : 0) + ' tokens.' : '';
  const lines = [input.blocked && 'Inspect the document before reconnecting; the last effect may be uncertain.',
    plain(input.message), plain(trace.message), last?.closed && 'Observation gap: ' + (last.reason || 'Observation paused'),
    actions.length && 'RE35 action receipts', droppedActions && droppedActions + ' earlier action receipts omitted.',
    ...actions.map(item => item.label + (item.reason ? ' — ' + item.reason : '')),
    segments.length && 'Native observations (not command completion)',
    ...segments.map(item => item.description + '\n' + item.detail), omitted];
  // StatusBarItem text recognizes codicons. Data must not impersonate UI icons.
  const text = parts.join(' · ').replace(/\$\(/g, '$ (');
  const tooltip = plain(lines.filter(Boolean).join('\n'), LIMIT.tooltip, true);
  return { visible, text, tooltip,
    description: [recent.map(item => item.token + ': ' + item.statusLabel).join('; '),
      last && 'Native keys observed' + (last.closed || trace.paused ? '; observation paused or interrupted' : '')].filter(Boolean).join('. '),
    historyItems };
}
module.exports = { projectInputFlow };
