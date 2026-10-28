'use strict';
const assert = require('node:assert/strict');
const { NavigationMemory, MAX_VIEWS, MAX_TEXT_BYTES } = require('../navigation-memory');
const { PresentationService } = require('../presentation');
const { createFacade } = require('./native-widget');

async function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { ++checks; assert.deepEqual(actual, expected, message); };
  const same = (actual, expected, message) => { ++checks; assert.equal(actual, expected, message); };
  const throws = (callback, pattern) => { ++checks; assert.throws(callback, pattern); };
  const turn = () => new Promise(resolve => setImmediate(resolve));
  const memory = new NavigationMemory(), rows = [{ id: 'one', label: 'One', execute() {} }, { id: 'two', label: 'Two', proposal: {} }];
  let lease = memory.open('discovery', 'pick', rows, {});
  same(lease.checkpoint({ value: 'tw', activeItems: [rows[1]], accepted: false }), true);
  eq([...memory.views.values()], [{ kind: 'pick', ticket: 1, value: 'tw', active: 'id:two' }], 'Only bounded scalar facts survive closure');
  const current = [{ id: 'one', label: 'Renamed one' }, { id: 'two', label: 'Renamed two' }];
  lease = memory.open('discovery', 'pick', current, {});
  eq(lease.options.value, 'tw'); same(lease.options.activeItem, current[1], 'A new current row adopts semantic navigation, never its retired object');
  eq(lease.options.selectedItems, undefined, 'A restored active row is not an accepted selection');
  same(lease.checkpoint({ value: '', activeItems: [current[1]], accepted: true }), true);
  lease = memory.open('discovery', 'pick', [current[0]], {});
  eq(lease.options.activeItem, undefined, 'Removed commands cannot be resurrected');
  lease.checkpoint({ value: '', activeItems: [], accepted: false });

  const labels = [{ label: 'Same' }, { label: 'Same' }];
  memory.open('labels', 'pick', labels, {}).checkpoint({ value: 's', activeItems: [labels[0]], accepted: false });
  eq(memory.open('labels', 'pick', labels.map(row => ({ ...row })), {}).options.activeItem, undefined, 'Ambiguous fallback labels do not adopt a choice');
  const kinds = [{ command: { id: 'edit.copy' }, label: 'Copy' }, { input: { name: 'query' }, label: 'Query' },
    { action: 'back', label: 'Back' }, { key: 'F6', label: 'F6' }, { mode: 'normal', label: 'Normal' },
    { value: false, label: 'False' }, { label: 'Unique label' }];
  for (let index = 0; index < kinds.length; ++index) {
    const key = 'kind.' + index, fresh = { ...kinds[index] };
    memory.open(key, 'pick', [kinds[index]], {}).checkpoint({ value: '', activeItems: [kinds[index]], accepted: false });
    same(memory.open(key, 'pick', [fresh], {}).options.activeItem, fresh);
  }
  memory.open('foreign', 'pick', rows, {}).checkpoint({ value: '', activeItems: [{ ...rows[0] }], accepted: false });
  eq(memory.open('foreign', 'pick', current, {}).options.activeItem, undefined);
  const old = memory.open('reset', 'input', null, {});
  memory.clear(); same(old.checkpoint({ value: 'must not return', accepted: false }), false);
  eq(memory.open('reset', 'input', null, {}).options.value, undefined);
  const first = memory.open('newest', 'input', null, {}), second = memory.open('newest', 'input', null, {});
  second.checkpoint({ value: 'new', accepted: false }); same(first.checkpoint({ value: 'old', accepted: false }), false);
  eq(memory.open('newest', 'input', null, {}).options.value, 'new');
  memory.open('field', 'input', null, {}).checkpoint({ value: 'unfinished 한글😀', accepted: false });
  lease = memory.open('field', 'input', null, { value: 'saved authoring value' }); eq(lease.options.value, 'unfinished 한글😀');
  lease.checkpoint({ value: 'confirmed', accepted: true });
  eq(memory.open('field', 'input', null, { value: 'confirmed authoring value' }).options.value, 'confirmed authoring value', 'Accepted fields belong to authoring drafts, not navigation');
  memory.open('large', 'input', null, {}).checkpoint({ value: 'a'.repeat(MAX_TEXT_BYTES), accepted: false });
  eq(memory.open('large', 'input', null, {}).options.value.length, MAX_TEXT_BYTES);
  memory.open('large', 'input', null, {}).checkpoint({ value: 'a'.repeat(MAX_TEXT_BYTES + 1), accepted: false });
  eq(memory.open('large', 'input', null, {}).options.value, undefined);
  memory.open('invalid', 'input', null, {}).checkpoint({ value: '\ud800', accepted: false });
  eq(memory.open('invalid', 'input', null, {}).options.value, undefined);
  for (const excluded of [{ password: true }, { canPickMany: true }]) {
    memory.open('secret', 'input', null, {}).checkpoint({ value: 'old', accepted: false });
    lease = memory.open('secret', 'input', null, excluded); eq(lease.options.value, undefined);
    same(lease.checkpoint({ value: 'secret', accepted: false }), false); same(memory.views.has('secret'), false);
  }
  memory.setRoute('user.commands_manage'); eq(memory.getRoute(), 'user.commands_manage');
  const prefixOld = memory.open('other', 'input', null, {});
  memory.clear('composition.author.'); eq(memory.getRoute(), 'user.commands_manage');
  same(prefixOld.checkpoint({ value: 'old', accepted: false }), false, 'Even a prefix reset retires every open checkpoint');
  memory.clear(); eq(memory.getRoute(), 'discovery');
  throws(() => memory.setRoute('project.run_selected_recipe'), /not a resumable/);
  throws(() => memory.open('', 'pick', rows, {}), /bounded key/);
  throws(() => memory.open('x'.repeat(257), 'input', null, {}), /bounded key/);
  for (let index = 0; index <= MAX_VIEWS; ++index) memory.open('bounded.' + index, 'input', null, {}).checkpoint({ value: String(index), accepted: false });
  eq(memory.views.size, MAX_VIEWS); same(memory.views.has('bounded.0'), false);
  let reads = 0;
  const accessor = { label: 'Accessor' }; Object.defineProperty(accessor, 'id', { enumerable: true, get() { ++reads; return 'do not read'; } });
  memory.open('accessor', 'pick', [accessor], {}).checkpoint({ value: '', activeItems: [accessor], accepted: false }); eq(reads, 0);

  const facade = createFacade(), navigation = new NavigationMemory();
  const core = { closed: false, async call(operation) {
    assert.equal(operation, 'presentation_resolve');
    return { requested: { id: 'full', name: 'Full' }, effective: { information: { title: true, help: true, details: true, status: true } } };
  } };
  const owner = { disposed: false, options: {}, navigation, uiEpoch: 0, backend: core, async core() { return core; } };
  const service = new PresentationService(owner, facade.ui);
  let pending = service.pick('tree', rows, { title: 'Commands' }, { remember: 'discovery' }); await turn();
  const retired = facade.last; retired.type('tw'); retired.activate([retired.items[1]]); retired.select([retired.items[1]]); retired.hide();
  eq(await pending, undefined); eq(facade.stats.listeners, 0); eq(retired.disposeCount, 1);
  pending = service.pick('tree', current, { title: 'Commands' }, { remember: 'discovery' }); await turn();
  const reopened = facade.last; same(reopened !== retired, true); eq(reopened.value, 'tw'); same(reopened.activeItems[0], reopened.items[1]);
  eq(reopened.selectedItems, [], 'Hidden selected rows never become a new form confirmation');
  let accepted = false; const answer = pending.then(value => { accepted = true; return value; }); reopened.accept(); await turn(); eq(accepted, false);
  reopened.select([reopened.items[1]]); reopened.accept(); same(await answer, current[1]);
  eq(facade.stats.listeners, 0);
  for (const scene of ['review', 'tasks', 'results']) {
    pending = service.pick(scene, rows, {}, { remember: 'forbidden.' + scene }); await turn();
    facade.last.type('no cache'); facade.last.hide(); await pending; same(navigation.views.has('forbidden.' + scene), false);
  }
  pending = service.input('input', { password: true }, { remember: 'password' }); await turn(); facade.last.type('secret'); facade.last.hide(); await pending;
  same(navigation.views.has('password'), false);
  pending = service.input('input', { value: 'original' }, { remember: 'author.field' }); await turn(); facade.last.type('draft'); facade.last.hide(); await pending;
  pending = service.input('input', { value: 'original' }, { remember: 'author.field' }); await turn(); eq(facade.last.value, 'draft'); facade.last.accept(); eq(await pending, 'draft');
  same(navigation.views.has('author.field'), false);
  pending = service.pick('tree', rows, {}, { remember: 'expired' }); await turn(); facade.last.type('stale'); ++owner.uiEpoch; facade.last.hide(); await pending;
  same(navigation.views.get('expired').value, undefined, 'A retired entry cannot save a stale query');
  pending = service.pick('tree', current, {}, { remember: 'clear' }); await turn(); facade.last.type('reset'); navigation.clear(); facade.last.hide(); await pending;
  same(navigation.views.has('clear'), false);
  service.dispose(); eq(facade.stats.listeners, 0); eq(facade.stats.disposed, facade.stats.created);
  return { passed: true, checks, physicalAcceptance: false, observations: ['scalar bounded navigation memory',
    'fresh widget and current row adoption', 'reset retires callbacks', 'no review/password/confirmation persistence', 'native hide releases every listener'] };
}
module.exports = { run };
