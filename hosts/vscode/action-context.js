'use strict';
// Keep live editor handles in the host. Registered code receives source data.
const { source, current } = require('./editing-bridge');
const point = value => [value.line, value.character];
function createActionEnvironment({ getHost, owned, vscode, getPolicy, editorAvailable = () => ({ available: true }) }) {
  return ({ descriptor, context = {} }) => {
    const service = getHost(), policy = getPolicy(descriptor.id);
    const editor = context.source?.editor || context.editingSource?.editor || vscode.window.activeTextEditor;
    const receipt = policy.source === 'none' ? null : context.editingSource || source(editor);
    if (receipt && context.source && context.source.version !== receipt.version) throw new Error('The registered action source changed between steps');
    function check(phase) {
      owned(service); if (context.check) context.check();
      if (phase === 'before' && (context.stopSignal || context.signal)?.aborted) throw new Error('The registered action was stopped before a new effect');
      if (!receipt) return;
      if (receipt.document.isClosed || vscode.window.activeTextEditor !== receipt.editor || receipt.editor.document !== receipt.document) throw new Error('The registered action lost its original editor');
      if ((phase === 'before' || phase === 'preserve') && !current(vscode, receipt)) throw new Error('The registered action source, version or selection changed');
      if (phase === 'before' && policy.completion === 'observed') {
        const available = policy.observationEngine === 'editor' ? editorAvailable() : service.editingService().availability();
        if (!available.available) throw new Error(available.reason);
      }
    }
    return { source: receipt ? Object.freeze({ uri: receipt.uri, version: receipt.version, anchor: receipt.anchor, active: receipt.active }) : undefined,
      signal: context.stopSignal || context.signal, check,
      expectEditorChange: context.expectEditorChange,
      admit() { check('before'); if (context.onAdmit) context.onAdmit(); },
      async observe() {
        if (policy.observationEngine === 'editor') {
          check('after');
          const available = editorAvailable(); if (!available.available) throw new Error(available.reason);
          return { uri: receipt.uri, version: receipt.document.version, text: receipt.document.getText(), mode: 'editor',
            anchor: point(receipt.editor.selection.anchor), active: point(receipt.editor.selection.active) };
        }
        check('after'); const bridge = service.editingService();
        if (!bridge.boot) await bridge.connect(); check('after');
        const result = await bridge.synchronized(receipt.editor, () => check('after')); check('after');
        return { uri: receipt.uri, version: receipt.document.version, text: receipt.document.getText(), mode: result.snapshot.mode,
          anchor: point(receipt.editor.selection.anchor), active: point(receipt.editor.selection.active) };
      },
      refresh(observed) { check('after'); if (context.source) context.source.version = observed.version; }
    };
  };
}
module.exports = { createActionEnvironment };
