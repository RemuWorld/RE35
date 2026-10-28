'use strict';
const { copyInvocation } = require('./invocation');
const { source, current } = require('./editing-bridge');
const IDS = ['edit.move_words', 'edit.select_word', 'edit.uppercase_selection', 'edit.delete_lines'];
function createEditingActions({ getHost, vscode, owned }) {
  const actions = {};
  function capture(frame = {}) {
    const receipt = frame.editingSource || source(vscode.window.activeTextEditor);
    if (!current(vscode, receipt)) throw new Error('The original editing source changed; invoke the command again');
    if (frame.source && (frame.source.editor !== receipt.editor || frame.source.version !== receipt.version)) {
      throw new Error('The original user command source changed before native editing');
    }
    return receipt;
  }
  async function environment(receipt, frame) {
    const service = getHost(); owned(service); if (frame.check) frame.check();
    const core = await service.core();
    const checkOwner = () => {
      owned(service); if (frame.check) frame.check();
      if (service.backend !== core || core.closed) throw new Error('Native editing core owner changed');
      if (frame.signal?.aborted) throw new Error('Native editing was cancelled');
    };
    const checkSource = () => {
      checkOwner();
      if (!current(vscode, receipt)) throw new Error('The source document, cursor or selection changed; invoke the edit again');
    };
    checkSource();
    const bridge = service.editingService(), available = bridge.availability();
    if (!available.available) throw new Error(available.reason);
    return { service, core, bridge, checkOwner, checkSource };
  }
  async function execute(command, supplied = {}, frame = {}, captured) {
    const invocation = copyInvocation({ command, args: supplied }), receipt = captured || capture(frame);
    const env = await environment(receipt, frame);
    let args = invocation.args;
    if (['edit.move_words', 'edit.delete_lines'].includes(command) && args.count === undefined) {
      const count = await env.service.presentationService().input('input', {
        title: command === 'edit.move_words' ? 'RE35 Move Words' : 'RE35 Delete Lines',
        prompt: 'Count from 1 to 1000', value: '1', ignoreFocusOut: false,
        validateInput: async value => {
          env.checkSource();
          try { await env.core.call('editing_normalize', { command, args: { count: value } }); env.checkSource(); return undefined; }
          catch (error) { env.checkSource(); return error.message; }
        }
      }, { requiredTitle: true });
      env.checkSource();
      if (count === undefined) return { status: 'cancelled', message: 'Editing count input cancelled' };
      args = { ...args, count };
    }
    const intent = await env.core.call('editing_normalize', { command, args }); env.checkSource();
    const result = await env.bridge.execute(intent.command, intent.args, {
      source: { editor: receipt.editor, version: receipt.version }, signal: frame.signal, check: env.checkOwner, onAdmit: frame.onAdmit
    });
    env.checkOwner();
    if (result.status === 'succeeded' && frame.source) frame.source.version = result.sourceVersion;
    return result;
  }
  for (const id of IDS) actions[id] = (args, frame) => execute(id, args, frame);
  actions['edit.guide'] = async (args = {}, frame = {}) => {
    const invocation = copyInvocation({ command: 'edit.guide', args });
    if (Object.keys(invocation.args).some(name => name !== 'keys')
      || (invocation.args.keys !== undefined && typeof invocation.args.keys !== 'string')) throw new Error('The editing guide accepts only a text keys argument');
    const receipt = capture(frame), env = await environment(receipt, frame);
    const classify = async text => {
      env.checkSource(); const parsed = await env.core.call('editing_guide', { text }); env.checkSource(); return parsed;
    };
    const value = invocation.args.keys === undefined ? await env.service.presentationService().input('input', {
      title: 'RE35 Editing Guide', prompt: 'w Move · s Select word · u Uppercase selection · d Delete lines; count before w/d',
      placeHolder: '3w or 2d', ignoreFocusOut: false,
      validateInput: async text => {
        const parsed = await classify(text);
        return parsed.state === 'ready' ? undefined : { message: parsed.message, severity: vscode.InputBoxValidationSeverity?.Error || 3 };
      }
    }, { requiredTitle: true }) : invocation.args.keys;
    env.checkSource();
    if (value === undefined) return { status: 'cancelled', message: 'Editing guide cancelled' };
    const parsed = await classify(value);
    if (parsed.state !== 'ready') {
      if (invocation.args.keys !== undefined) throw new Error(parsed.message);
      return { status: 'cancelled', message: parsed.message };
    }
    return execute(parsed.invocation.command, parsed.invocation.args, frame, receipt);
  };
  return actions;
}
module.exports = { createEditingActions };
