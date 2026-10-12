'use strict';

// Controlled native callbacks, not physical VS Code interaction. Setters emit
// native events; accept() never selects a row implicitly. Tests use exact items.
function createFacade({ onShow } = {}) {
  const widgets = [], stats = { created: 0, disposed: 0, listeners: 0, maximumListeners: 0 };
  let visible = null;
  function create(kind) {
    const handlers = new Map();
    const state = { items: [], activeItems: [], selectedItems: [], value: '' };
    const widget = { kind, visible: false, disposed: false, showCount: 0, disposeCount: 0,
      fire(name, value) { for (const handler of Array.from(handlers.get(name) || [])) handler(value); },
      show() {
        if (this.disposed) throw new Error('Disposed native widget cannot show');
        if (visible && visible !== this) visible.hide();
        visible = this; this.visible = true; ++this.showCount;
        if (onShow) onShow(this);
      },
      hide() { if (!this.visible) return; this.visible = false; if (visible === this) visible = null; this.fire('onDidHide'); },
      dispose() { if (this.disposed) throw new Error('Native widget disposed twice'); this.hide(); this.disposed = true; ++this.disposeCount; ++stats.disposed; },
      type(value) { this.value = value; },
      activate(rows) { this.activeItems = rows; },
      select(rows) { this.selectedItems = rows; },
      fireButton(button) { this.fire('onDidTriggerButton', button); },
      accept() { this.fire('onDidAccept'); }
    };
    for (const name of ['onDidHide', 'onDidAccept', 'onDidChangeActive', 'onDidChangeSelection', 'onDidChangeValue', 'onDidTriggerButton']) {
      handlers.set(name, new Set());
      widget[name] = handler => {
        if (widget.disposed) throw new Error('Disposed native widget cannot add a listener');
        handlers.get(name).add(handler); ++stats.listeners; stats.maximumListeners = Math.max(stats.maximumListeners, stats.listeners);
        return { dispose() { if (handlers.get(name).delete(handler)) --stats.listeners; } };
      };
    }
    for (const name of ['items', 'activeItems', 'selectedItems', 'value']) {
      Object.defineProperty(widget, name, { enumerable: true,
        get() { return state[name]; },
        set(value) {
          if (widget.disposed) throw new Error('Disposed native widget cannot change');
          state[name] = value;
          if (name === 'items') { widget.activeItems = []; widget.selectedItems = []; }
          if (name === 'activeItems') widget.fire('onDidChangeActive', value);
          if (name === 'selectedItems') widget.fire('onDidChangeSelection', value);
          if (name === 'value') widget.fire('onDidChangeValue', value);
        }
      });
    }
    widgets.push(widget); ++stats.created; return widget;
  }
  return { ui: { workspace: { isTrusted: true }, ThemeIcon: class ThemeIcon { constructor(id) { this.id = id; } },
    window: { createQuickPick: () => create('pick'), createInputBox: () => create('input') } },
    widgets, stats, get last() { return widgets[widgets.length - 1]; } };
}

module.exports = { createFacade };
