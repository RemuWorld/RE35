'use strict';
const assert = require('node:assert/strict');
const { discoveryRows } = require('../discovery');

async function run() {
  let checks = 0;
  const eq = (actual, expected, label) => { ++checks; assert.deepEqual(actual, expected, label); };
  const throws = (callback, pattern) => { ++checks; assert.throws(callback, pattern); };
  const commands = Array.from({ length: 96 }, (_, index) => ({
    id: 'local.action_' + index, name: 'Action ' + index, path: ['opaque', String(index)],
    aliases: ['alias-' + index], execute() { throw new Error('Discovery must not execute actions'); }
  }));
  const saved = [{ id: 'user.example', name: 'My reusable command', steps: [{ command: commands[0].id }] }];
  const rows = discoveryRows(commands, saved, { locations: { [commands[0].id]: 'Document' } });
  eq(rows.length, 97, 'All current commands remain discoverable beyond the previous 64-row cutoff');
  eq(rows[95], { id: 'local.action_95', label: 'Action 95' });
  eq(rows[96], { id: 'user.example', label: 'My reusable command', description: 'User command', optionalPresentation: { status: true } });
  eq(rows[0], { id: 'local.action_0', label: 'Action 0', description: 'Document', optionalPresentation: { status: true } });
  eq(rows.some(row => Object.hasOwn(row, 'path') || Object.hasOwn(row, 'aliases') || Object.hasOwn(row, 'execute') || Object.hasOwn(row, 'steps')), false,
    'Display projection does not carry adapters, composition steps or hidden search claims');
  eq(discoveryRows(commands.slice(1), []).some(row => row.id === commands[0].id), false,
    'Reopening projects only the current registration catalog');
  eq(discoveryRows([{ id: 'unknown.third_party', name: 'External action' }], []), [{ id: 'unknown.third_party', label: 'External action' }],
    'External IDs do not fabricate a human group or location');
  const unicode = [{ id: 'local.unicode', name: '문서 😀 찾기', description: '선택한 문서를 검색합니다.' }];
  eq(discoveryRows(unicode, [], { locations: new Map([['local.unicode', '문서']]) }), [{ id: 'local.unicode', label: '문서 😀 찾기',
    description: '문서', detail: '선택한 문서를 검색합니다.', optionalPresentation: { status: true, details: true } }]);
  const described = { id: 'local.describe', name: 'Described command', description: 'A useful explanation' };
  eq(discoveryRows([described], [])[0], { id: described.id, label: described.name, detail: described.description, optionalPresentation: { details: true } });
  for (const description of ['', '   ', described.name, described.id]) {
    eq(discoveryRows([{ ...described, description }], [])[0], { id: described.id, label: described.name }, 'Do not repeat blank, name or ID text as an explanation');
  }
  eq(discoveryRows([{ id: 'local.location', name: 'Document', description: 'Document' }], [], {
    locations: { 'local.location': 'Document' }
  }), [{ id: 'local.location', label: 'Document' }], 'An explicit location still does not need to repeat the name');
  eq(discoveryRows([], saved, { locations: { 'user.example': 'Build workflow' } })[0].description, 'Build workflow');

  const sameNames = [{ id: 'local.first', name: 'Select word' }, { id: 'local.second', name: 'Select word' }];
  const distinctContexts = discoveryRows(sameNames, [], {
    locations: { 'local.first': 'Native editing', 'local.second': 'VS Code editing' }
  });
  eq(distinctContexts.map(row => row.description), ['Native editing', 'VS Code editing'], 'Distinct explicit contexts distinguish matching names without adding IDs');
  eq(distinctContexts.every(row => !row.optionalPresentation?.status), true, 'Ambiguous names keep distinguishing context in Minimal');
  const sameContexts = discoveryRows(sameNames, [], { locations: { 'local.first': 'Editing', 'local.second': 'Editing' } });
  eq(sameContexts.map(row => row.description), ['Editing · local.first', 'Editing · local.second'], 'Matching names and contexts require stable IDs');
  eq(sameContexts.every(row => !row.optionalPresentation?.status), true);
  const noContexts = discoveryRows(sameNames, []);
  eq(noContexts.map(row => row.description), ['local.first', 'local.second'], 'Missing contexts do not leave identically named choices indistinguishable');
  eq(noContexts.every(row => !row.optionalPresentation?.status), true);
  eq(discoveryRows(sameNames, [], { locations: { 'local.first': 'Native editing' } }).map(row => row.description),
    ['Native editing', 'local.second'], 'A useful distinct context remains sufficient when the other choice lacks one');
  eq(discoveryRows([{ id: 'local.upper', name: 'Build' }, { id: 'local.lower', name: 'build' }], []).map(row => row.description),
    [undefined, undefined], 'Only exact matching display names trigger disambiguation');
  eq(discoveryRows([{ id: 'local.existing', name: saved[0].name }], saved).map(row => row.description),
    ['local.existing', 'User command'], 'Registered and saved commands share the same ambiguity check');
  const describedDuplicate = discoveryRows([{ ...sameNames[0], description: 'Changes the current selection' }, sameNames[1]], []);
  eq(describedDuplicate[0].optionalPresentation, { details: true }, 'Mandatory disambiguation does not promote an unrelated explanation');
  eq(describedDuplicate.map(row => row.id), ['local.first', 'local.second'], 'Review and invocation retain the original owned scalar IDs');

  const reason = 'Enable vscode-neovim to use this action';
  const blocked = discoveryRows([described], [], {
    locations: { [described.id]: 'Native editing' },
    availability(id, descriptor) { eq(id, described.id); eq(descriptor, described); return reason; }
  })[0];
  eq(blocked, { id: described.id, label: described.name, description: 'Native editing', detail: reason,
    unavailable: reason, inspectOnly: true, optionalPresentation: { status: true } });
  // Apply the service's information masking rules. A mode may remove optional
  // context but cannot remove the reason that makes this action unavailable.
  for (const mode of ['full', 'compact', 'minimal']) {
    const display = { ...blocked }, information = mode === 'full' ? { details: true, status: true } : { details: false, status: false };
    if (blocked.optionalPresentation.details && !information.details) delete display.detail;
    if (blocked.optionalPresentation.status && !information.status) delete display.description;
    eq(display.detail, reason, mode + ' preserves the availability reason');
    eq(display.inspectOnly, true, mode + ' does not turn a blocked action into an executable row');
  }
  eq(discoveryRows([described], [], { availability: () => '   ' })[0].detail, described.description);
  eq(discoveryRows([described], [], { availability: () => null })[0].inspectOnly, undefined);
  eq(discoveryRows([], [], {}), []);
  throws(() => discoveryRows([described, { ...described }], []), /Duplicate discovery command ID/);
  throws(() => discoveryRows([described], [{ ...described }]), /Duplicate discovery command ID/);
  throws(() => discoveryRows([{}], []), /stable IDs and display names/);
  throws(() => discoveryRows([{ id: 'local.empty', name: '  ' }], []), /stable IDs and display names/);
  throws(() => discoveryRows({}, []), /current command arrays/);
  throws(() => discoveryRows([], [], { availability: true }), /current command arrays/);
  throws(() => discoveryRows([described], [], { availability: () => ({ available: false }) }), /return a reason/);
  throws(() => discoveryRows([described], [], { locations: { [described.id]: '' } }), /nonempty labels/);
  const inherited = Object.create({ [described.id]: 'Inherited location' });
  eq(discoveryRows([described], [], { locations: inherited })[0].description, undefined, 'Only explicit own location declarations apply');
  const original = { id: 'local.owned', name: 'Original', description: 'Before' }, locations = { 'local.owned': 'Context' };
  const first = discoveryRows([original], [], { locations });
  original.name = 'Changed'; original.description = 'After'; locations['local.owned'] = 'Changed context';
  eq(first[0].label, 'Original'); eq(first[0].detail, 'Before'); eq(first[0].description, 'Context', 'Rows own their scalar display snapshot');
  first[0].optionalPresentation.details = false;
  eq(discoveryRows([original], [], { locations })[0].optionalPresentation.details, true, 'Projections do not share mutable presentation flags');
  return { checks, scope: 'Complete current discovery projection, explicit information hierarchy and mandatory unavailability reasons; no renderer or physical-key claim' };
}

if (require.main === module) run().then(result => console.log(JSON.stringify(result))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
