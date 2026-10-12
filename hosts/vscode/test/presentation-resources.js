'use strict';
// Actual Host/shared-helper resource work; controlled widget callbacks measure
// adapter preparation and in-place updates, without pixels or physical input.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { performance } = require('node:perf_hooks');
const { PresentationService } = require('../presentation');
const { createFacade } = require('./native-widget');
const SCENES = Object.freeze(['tree', 'search', 'input', 'review', 'tasks', 'results']);
const POLICY = Object.freeze({ uncached_six_scene_resolve_p95_ms: 500, cached_six_scene_resolve_p95_ms: 25,
  adapter_controlled_pick_p95_ms: 100, live_appearance_refresh_p95_ms: 250, retained_scene_cache: 6,
  heap_growth_bytes: 2 * 1024 * 1024, external_growth_bytes: 1024 * 1024,
  helper_private_growth_bytes: 2 * 1024 * 1024 });
function summary(samples) {
  const ordered = samples.slice().sort((a, b) => a - b);
  return { count: samples.length, p95_ms: ordered[Math.ceil(ordered.length * .95) - 1],
    median_ms: ordered[Math.floor(ordered.length / 2)], min_ms: ordered[0], max_ms: ordered[ordered.length - 1], samples_ms: samples };
}
const preset = revision => ({ version: 1, selected: 'resource', presets: {
  resource: { extends: 'minimal', name: `Resource ${revision}`, layout: { position: 'bottom-right', width: 64 },
    roles: { accent: { fg: '#34ab12' } }, scenes: {
      tree: { information: { help: false } }, search: { information: { details: false } },
      input: { information: { title: false } }, review: { information: { details: true } },
      tasks: { information: { status: true } }, results: { information: { details: false } }
    } }
} });
async function run({ api, options, gc, helperMemory }) {
  let host, service, core, maximumCache = 0, callbacks = 0, revision = 0, automaticAccept = true;
  let live = null, liveRefreshes = 0, lifecycleCancellations = 0;
  const outcomes = {}, checks = [];
  const items = Object.freeze(Array.from({ length: 24 }, (_, index) => Object.freeze({
    label: `Action ${index} 한글😀`, description: `Required state ${index}`, detail: `Required context ${index}`,
    optionalPresentation: Object.freeze({ status: false, details: false }), index
  })));
  const facade = createFacade({ onShow(widget) {
    if (!automaticAccept) return;
    queueMicrotask(() => {
      assert.equal(widget.disposed, false, 'The scheduled choice still owns a live widget');
      widget.select([widget.items[0]]); ++callbacks; widget.accept();
    });
  } });
  const native = { ...facade.ui, workspace: { isTrusted: true } };
  const settledWidget = () => {
    assert.equal(service.active, null, 'A settled native form releases its service owner');
    assert.equal(facade.stats.listeners, 0, 'A settled form retains no native event listeners');
    assert.equal(facade.stats.created, facade.stats.disposed, 'Every created native form is disposed');
    assert(facade.widgets.every(widget => widget.disposed && !widget.visible));
    // The fixture's historical registry is not a production cache. Keeping it
    // would retain every disposed display projection across memory samples.
    facade.widgets.length = 0;
  };
  const inspectCache = () => {
    maximumCache = Math.max(maximumCache, service.cache.size);
    assert(service.cache.size <= POLICY.retained_scene_cache);
    assert.equal(service.inflight.size, 0, 'Settled scene resolves retain no pending requests');
  };
  const resolveAll = () => Promise.all(SCENES.map(scene => service.resolve(scene)));
  const appearance = async () => {
    const candidate = preset(++revision), original = JSON.stringify(candidate);
    await host.updatePresentationOptions({ presentation: candidate });
    assert.equal(JSON.stringify(candidate), original, 'An appearance update never mutates caller data');
    assert.notEqual(host.options.presentation, candidate, 'A validated update owns its declaration copy');
    assert.equal(host.backend, core, 'Appearance changes keep the same actual helper');
    assert.equal(service.cache.size, service.active ? 1 : 0,
      'A validated revision retains only its refreshed active scene, if present');
  };
  const waitForLive = async pending => {
    const timeout = performance.now() + 5000;
    let terminalError;
    let terminal = false;
    pending.then(() => { terminal = true; }, error => { terminal = true; terminalError = error; });
    while (!service.active || !service.active.view.widget) {
      if (terminal) throw terminalError || new Error('The resource picker settled before controlled interaction');
      if (performance.now() >= timeout) throw new Error('The owned resource picker did not open');
      await new Promise(resolve => setTimeout(resolve, 1));
    }
  };
  const openLive = async () => {
    automaticAccept = false;
    let settled = false;
    const pending = service.pick('tasks', items, { title: 'Required Task #7',
      placeHolder: 'Required task context', activeItem: items[11], canPickMany: true }, { requiredTitle: true });
    pending.then(() => { settled = true; }, () => { settled = true; });
    await waitForLive(pending);
    const widget = service.active.view.widget;
    widget.type('Action 11 한글😀'); widget.activate([widget.items[11]]);
    widget.select([widget.items[5], widget.items[11]]);
    return { pending, widget, settled: () => settled };
  };
  const verifyLive = record => {
    assert.equal(record.settled(), false, 'Appearance work cannot accept or cancel its pending form');
    assert.equal(service.active.view.widget, record.widget, 'An appearance refresh keeps the same native widget');
    assert.equal(record.widget.value, 'Action 11 한글😀', 'A live Unicode query survives appearance refresh');
    const projection = service.active.view.projection;
    assert.deepEqual(record.widget.activeItems.map(row => projection.displays.get(row).original), [items[11]]);
    assert.deepEqual(record.widget.selectedItems.map(row => projection.displays.get(row).original), [items[5], items[11]]);
    assert.equal(record.widget.disposed, false); assert.equal(record.widget.busy, false);
  };
  const closeLive = async record => {
    record.widget.hide(); assert.equal(await record.pending, undefined, 'Controlled cancellation dispatches no choice');
    ++lifecycleCancellations; automaticAccept = true; settledWidget();
  };
  const memory = async () => {
    gc(); await new Promise(resolve => setTimeout(resolve, 25)); gc();
    const helper = await helperMemory(host.backend.child.pid);
    if (helper.private_bytes === null && process.platform === 'linux') {
      // Linux private resident pages are an explicit platform equivalent, not a
      // substituted zero for the Windows committed-private measurement.
      try {
        const value = await fs.readFile(`/proc/${host.backend.child.pid}/smaps_rollup`, 'utf8');
        const amount = name => {
          const match = value.match(new RegExp(`^${name}:\\s+(\\d+) kB$`, 'm'));
          return match ? Number(match[1]) * 1024 : null;
        };
        const clean = amount('Private_Clean'), dirty = amount('Private_Dirty'), huge = amount('Private_Hugetlb');
        if (clean !== null && dirty !== null) {
          helper.private_bytes = clean + dirty + (huge === null ? 0 : huge);
          helper.private_method = 'Linux /proc/PID/smaps_rollup private resident pages';
        }
      } catch (error) { helper.private_measurement_error = error.message; }
    }
    return { host: process.memoryUsage(), helper };
  };
  async function repeated(action, beforeEach = async () => {}) {
    for (let index = 0; index < 5; ++index) { await beforeEach(); await action(); inspectCache(); }
    const samples = [];
    for (let index = 0; index < 30; ++index) {
      await beforeEach();
      const started = performance.now(), value = await action();
      samples.push(performance.now() - started); inspectCache();
      if (Array.isArray(value) && value.length === SCENES.length) {
        for (const model of value) {
          assert.equal(model.requested.id, 'resource');
          assert.equal(model.requested.roles.accent.fg, '#34AB12', 'Actual shared declarations normalize role data');
        }
      }
    }
    return summary(samples);
  }
  try {
    host = new api.Host({ ...options });
    core = await host.core(); // Helper startup and registration are outside this new workload's timings.
    service = new PresentationService(host, native); host.presentation = service;
    const beforeOperations = await core.call('snapshot');
    const uncached = await repeated(resolveAll, appearance);
    outcomes.uncached_six_scene_resolve = uncached;
    const cached = await repeated(resolveAll);
    outcomes.cached_six_scene_resolve = cached;
    const pick = await repeated(async () => {
      const selected = await service.pick('tasks', items,
        { title: 'Required Task #7', placeHolder: 'Required task context' }, { requiredTitle: true });
      assert.equal(selected, items[0], 'The native adapter returns the original owned item');
      settledWidget();
      return selected;
    });
    outcomes.adapter_controlled_pick = pick;
    live = await openLive();
    const refresh = await repeated(async () => {
      await appearance(); await service.resolve('tasks'); verifyLive(live); ++liveRefreshes;
    });
    outcomes.live_appearance_refresh = refresh;
    await closeLive(live); live = null;
    for (const [metric, value] of [
      ['uncached_six_scene_resolve_p95_ms', uncached.p95_ms],
      ['cached_six_scene_resolve_p95_ms', cached.p95_ms],
      ['adapter_controlled_pick_p95_ms', pick.p95_ms],
      ['live_appearance_refresh_p95_ms', refresh.p95_ms]
    ]) checks.push({ metric, value, limit: POLICY[metric], passed: value <= POLICY[metric] });

    // Fixed lifecycle retention: every revision, six-scene cache and display
    // projection is disposed before the named collected-memory sample.
    service.dispose();
    let before, after;
    for (let cycle = 1; cycle <= 60; ++cycle) {
      service = new PresentationService(host, native); host.presentation = service;
      await appearance(); await resolveAll(); inspectCache();
      for (const scene of SCENES) {
        assert.equal(await service.pick(scene, items, { title: 'Required invocation context' }, { requiredTitle: true }), items[0]);
        settledWidget();
        inspectCache();
      }
      assert.equal(service.cache.size, SCENES.length);
      live = await openLive(); await appearance(); verifyLive(live); ++liveRefreshes;
      await closeLive(live); live = null;
      service.dispose();
      assert.equal(service.cache.size, 0); assert.equal(service.inflight.size, 0); assert.equal(service.epoch, null);
      assert.equal(service.active, null); assert.equal(facade.stats.listeners, 0); assert.equal(facade.widgets.length, 0);
      if (cycle === 20) before = await memory();
      if (cycle === 60) after = await memory();
    }
    const growth = { heap: after.host.heapUsed - before.host.heapUsed,
      external: after.host.external - before.host.external,
      helper_private: Number.isFinite(before.helper.private_bytes) && Number.isFinite(after.helper.private_bytes)
        ? after.helper.private_bytes - before.helper.private_bytes : null };
    for (const [field, metric] of [['heap', 'heap_growth_bytes'], ['external', 'external_growth_bytes'],
      ['helper_private', 'helper_private_growth_bytes']]) checks.push({ metric, value: growth[field],
      limit: POLICY[metric], passed: growth[field] !== null && growth[field] <= POLICY[metric] });
    checks.push({ metric: 'retained_scene_cache', value: maximumCache, limit: POLICY.retained_scene_cache,
      passed: maximumCache <= POLICY.retained_scene_cache });
    assert.deepEqual(await core.call('snapshot'), beforeOperations, 'Appearance work changes no core operations or execution authority');
    assert.equal(host.backend, core); assert.equal(host.review, null); assert.equal(host.previews.size, 0);
    outcomes.retention = { memory_before: before, memory_after: after, growth, maximum_scene_cache: maximumCache,
      final_scene_cache: service.cache.size, final_pending_scene_requests: service.inflight.size, appearance_revisions: revision,
      final_native_listeners: facade.stats.listeners, final_live_widgets: 0, created_widgets: facade.stats.created,
      disposed_widgets: facade.stats.disposed, maximum_native_listeners: facade.stats.maximumListeners,
      live_refreshes: liveRefreshes, controlled_cancellations: lifecycleCancellations };
    const unmeasured = growth.helper_private === null ? ['helper_private_growth_bytes'] : [];
    return { passed: checks.every(value => value.passed === true), policy: POLICY, outcomes, checks, unmeasured,
      evidence: 'Actual VS Code Host and shared Lua presentation contract; controlled native widget callbacks',
      ownership: { same_helper_retained: true, operation_snapshot_unchanged: true, scene_cache_cleared_after_disposal: true,
        returned_original_item_identity: true, caller_presentation_data_unchanged: true,
        same_live_widget_query_and_original_selection: true, native_listeners_cleared_after_settlement: true,
        appearance_refresh_does_not_accept: true },
      conditions: { scenes: SCENES, rows_per_pick: items.length, warmups: 5, timed_samples: 30, resolve_sample: 'all six scenes',
        retention_cycles: [20, 60], complete_lifecycle_cycles: 60, native_callback_completions: callbacks,
        helper_startup_in_new_timings: false, appearance_update_validation_in_uncached_timings: false,
        appearance_update_validation_in_live_refresh_timings: true, live_refresh_scene: 'tasks',
        live_refresh_selected_original_indices: [5, 11], live_refresh_active_original_index: 11,
        live_refresh_query: 'Action 11 한글😀',
        gc: 'two explicit collections before each memory sample, outside timed operations',
        native_callbacks: 'controlled widget events with scheduled selection and accept; explicit live-view cancellation', physical_gestures_measured: false,
        native_pixels_measured: false, rendered_ui_latency_measured: false } };
  } finally {
    if (live && !live.widget.disposed) live.widget.hide();
    if (service) service.dispose(); if (host) host.dispose();
    facade.widgets.length = 0;
  }
}
module.exports = { run };
