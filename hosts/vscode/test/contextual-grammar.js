'use strict';
const assert = require('node:assert/strict');
const { validate, compile, normalizeToken, tokenKey, LIMITS } = require('../contextual-grammar');
const clone = value => JSON.parse(JSON.stringify(value));
const t = text => ({ kind: 'text', text });
const k = (key, modifiers = []) => ({ kind: 'key', key, modifiers });
function profile() {
  return { version: 1, id: 'user.grammar', name: 'My editor rules', entry_context: 'commands', contexts: [
    { id: 'commands', owned_roots: [t('s'), t('g'), k('F6')] },
    { id: 'selected', requires_selection: true, owned_roots: [t('c'), t('C')] }
  ], rules: [
    { id: 'user.select', context: 'commands', tokens: [t('s')], invoke: { command: 'editor.select_line' }, next_context: 'selected' },
    { id: 'user.start', context: 'commands', tokens: [t('g'), t('g')], invoke: { command: 'editor.document_start', args: {} } },
    { id: 'user.end', context: 'commands', tokens: [t('g'), t('e')], invoke: { command: 'editor.extend_to_end', args: {} } },
    { id: 'user.direct', context: 'commands', tokens: [k('F6')], invoke: { command: 'editor.uppercase_selection', args: {} } },
    { id: 'user.lower', context: 'selected', tokens: [t('c')], invoke: { command: 'local.lower', args: { title: '한글 😀' } }, next_context: null },
    { id: 'user.upper', context: 'selected', tokens: [t('C')], invoke: { command: 'editor.uppercase_selection', args: {} }, next_context: 'commands' }
  ] };
}
function run() {
  let checks = 0;
  const eq = (actual, expected, reason) => { assert.deepEqual(actual, expected, reason); ++checks; };
  const refuses = (action, expected) => { assert.throws(action, expected); ++checks; };
  const normalized = validate(profile());
  eq(normalized.contexts[0].requires_selection, false);
  eq(Object.isFrozen(normalized.rules[0].invoke.args), true);
  eq(JSON.stringify(validate(normalized)), JSON.stringify(normalized), 'Normalization is stable');
  eq(normalizeToken(k('F8', ['meta', 'ctrl', 'shift'])).modifiers, ['ctrl', 'shift', 'meta']);
  eq(tokenKey(t('c')) === tokenKey(t('C')), false, 'Literal case is not folded');
  eq(normalizeToken(t('😀')).text, '😀');
  eq(normalizeToken(t('한')).text, '한');
  eq(normalizeToken(t(' ')).text, ' ', 'Whitespace is declared explicitly rather than assigned automatically');
  for (const invalid of [t('ab'), t('e\u0301'), t('\ud800'), t('\n'), {kind:'text',text:'a',modifiers:[]},
    {kind:'key',key:'f6'}, k('F25'), k('F6',['ctrl','ctrl']), k('F6',['super']), {kind:'key',key:'F6',text:'x'}]) {
    refuses(() => normalizeToken(invalid), /token|Unicode|modifier|text/i);
  }
  const wrong = modify => { const value = profile(); modify(value); return value; };
  for (const [modify, expected] of [
    [value => { value.version = 2; }, /version/],
    [value => { value.input_profile = 'vscode'; }, /Unknown/],
    [value => { value.counts = {}; }, /Unknown/],
    [value => { value.id = 'bad id'; }, /identifier/],
    [value => { value.entry_context = 'missing'; }, /entry context/],
    [value => { value.contexts[0].requires_selection = 1; }, /boolean/],
    [value => { value.contexts[1].id = 'commands'; }, /Duplicate context/],
    [value => { value.contexts[0].owned_roots.push(t('s')); }, /Duplicate owned root/],
    [value => { value.contexts[0].owned_roots.push(k('Escape')); }, /control/],
    [value => { value.controls = {cancel:null}; }, /object/],
    [value => { value.controls = {cancel:k('Backspace')}; }, /collide/],
    [value => { value.rules[1].id = value.rules[0].id; }, /Duplicate/],
    [value => { value.rules[0].context = 'missing'; }, /rule context/],
    [value => { value.rules[0].next_context = 'missing'; }, /next context/],
    [value => { value.rules[0].next_context = false; }, /next context/],
    [value => { value.rules[0].tokens = []; }, /invalid size/],
    [value => { value.rules[0].tokens = Array(17).fill(t('s')); }, /invalid size/],
    [value => { value.rules[0].tokens = [t('x')]; }, /ownership/],
    [value => { value.rules[0].tokens.push(k('Backspace')); }, /control/],
    [value => { value.rules[1].tokens = [t('g')]; }, /prefix collision/],
    [value => { value.rules[2].tokens = clone(value.rules[1].tokens); }, /prefix collision/],
    [value => { value.rules[0].invoke.command = 'ex.hidden'; }, /runtime command/],
    [value => { value.rules[0].invoke.command = 'bad command'; }, /identifier/],
    [value => { value.rules[0].invoke.args = []; }, /object/],
    [value => { value.rules[0].invoke.args = null; }, /object/],
    [value => { value.rules[0].invoke.args = { code: () => 1 }; }, /plain JSON/],
    [value => { value.name = 'x'.repeat(LIMITS.bytes + 1); }, /Unicode|64 KiB/],
    [value => { value.contexts = Array.from({length:33}, (_,i) => ({id:'ctx'+i,owned_roots:[]})); }, /invalid size/],
    [value => { value.rules = Array(257).fill(value.rules[0]); }, /invalid size/]
  ]) refuses(() => validate(wrong(modify)), expected);
  const sparse = profile(); sparse.rules = Array(2); refuses(() => validate(sparse), /dense/);
  const cyclic = profile(); cyclic.rules[0].invoke.args = {cycle:cyclic}; refuses(() => validate(cyclic), /plain JSON/);
  const infinite = profile(); infinite.rules[0].invoke.args = {value:Infinity}; refuses(() => validate(infinite), /plain JSON/);
  const foreign = profile(); foreign.rules[0].invoke.args = new Date(); refuses(() => validate(foreign), /host objects/);
  const hidden = profile(); Object.defineProperty(hidden, 'secret', {value:1}); refuses(() => validate(hidden), /hidden keys/);
  const symbol = profile(); symbol[Symbol('hidden')] = 1; refuses(() => validate(symbol), /hidden keys/);
  let getters = 0; const accessor = profile(); Object.defineProperty(accessor, 'name', {enumerable:true,get(){++getters;return 'bad';}});
  refuses(() => validate(accessor), /accessors/); eq(getters, 0, 'Validation never executes an accessor');
  let traps = 0; const proxy = new Proxy(profile(), {getPrototypeOf(){++traps;return Object.prototype;}});
  refuses(() => validate(proxy), /plain JSON/); eq(traps, 0, 'Validation rejects proxies before introspection');
  const deep = profile(); let branch = deep.rules[0].invoke.args = {}; for(let i=0;i<20;++i) branch = branch.child = {};
  refuses(() => validate(deep), /depth/);
  const many = profile(); many.rules[0].invoke.args = {items:Array(8200).fill(0)}; refuses(() => validate(many), /limit/);
  const proto = profile(); proto.rules[0].invoke.args = JSON.parse('{"__proto__":{"sentinel":true},"constructor":1}');
  const prepared = validate(proto); eq(prepared.rules[0].invoke.args.__proto__.sentinel, true); eq({}.sentinel, undefined);

  const original = profile(), engine = compile(original);
  original.rules[0].invoke.command = 'local.replaced';
  eq(engine.getState().active, false, 'Loading a profile never activates capture');
  eq(engine.accept(t('s')).status, 'pass'); eq(engine.owns(t('s')), false);
  engine.activate(); eq(engine.getState().context, 'commands'); eq(engine.owns(t('s')), true); eq(engine.owns(t('x')), false);
  eq(engine.accept(t('x')).status, 'pass'); eq(engine.getState().active, true, 'An unowned root leaves writing alone');
  const selection = engine.accept(t('s'));
  eq(selection.status, 'invoke', 'A complete minimum action is emitted on its token without final Enter');
  eq(selection.invoke.command, 'editor.select_line', 'Later mutation of source definitions cannot retarget a compiled rule');
  eq(engine.getState().busy, true); eq(engine.accept(t('C')).status, 'busy', 'Tokens are not interpreted using old selection while a prior effect runs');
  eq(engine.getState().pending, []); eq(engine.owns(t('C')), false);
  eq(engine.owns(t('C'), {includeFutureContexts:true}), true);
  eq(engine.owns(t('s'), {includeFutureContexts:true}), false, 'Only the declared destination context owns a future root');
  refuses(() => engine.activate(), /admitted/);
  refuses(() => engine.complete(clone(selection.ticket), {status:'succeeded',observed:true,selection_nonempty:true}), /unowned/);
  eq(engine.getState().busy, true);
  const selected = engine.complete(selection.ticket, {status:'succeeded',observed:true,selection_nonempty:true});
  eq(selected.context, 'selected'); eq(engine.getState().busy, false);
  const upper = engine.accept(t('C')); eq(upper.invoke.command, 'editor.uppercase_selection');
  engine.complete(upper.ticket, {status:'completed',observed:true}); eq(engine.getState().context, 'commands');
  const direct = engine.accept(k('F6')); engine.complete(direct.ticket,{status:'succeeded',observed:true});
  eq(engine.getState().context,'commands','Absent next_context stays in the same explicitly owned scope');
  const startPrefix = engine.accept(t('g')); eq(startPrefix.status,'prefix'); eq(engine.getState().pending,[normalizeToken(t('g'))]);
  eq(engine.owns(t('g')),true); eq(engine.owns(t('x')),false,'An unknown suffix remains unowned for current-token-only host pass');
  const start = engine.accept(t('g')); eq(start.invoke.command,'editor.document_start');
  engine.complete(start.ticket,{status:'succeeded',observed:true});
  engine.accept(t('g')); const suffix = engine.accept(t('x'));
  eq(suffix.status,'rejected'); eq(suffix.consumed,false); eq(engine.getState().active,false,'Unknown suffix drops prefix and ends the scope, never replaying it');
  refuses(() => engine.complete(start.ticket,{status:'succeeded',observed:true}),/unowned/);
  engine.activate(); engine.accept(t('g')); const back = engine.accept(k('Backspace'));
  eq([back.status,back.control,back.target],['control','backspace','prefix']); eq(engine.getState().pending,[]);
  eq(engine.accept(k('Backspace')).consumed,false,'No pending prefix leaves normal editor deletion to the host');
  const cancelled = engine.accept(k('Escape')); eq([cancelled.status,cancelled.control],['control','cancel']);
  eq(engine.accept(k('Escape')).consumed,false,'Inactive scope does not own Escape');
  engine.activate(); const revoked = engine.accept(t('s')); engine.deactivate('source_changed'); engine.activate();
  refuses(() => engine.complete(revoked.ticket,{status:'succeeded',observed:true,selection_nonempty:true}),/unowned/);
  const second = engine.accept(t('s')); const transition = engine.complete(second.ticket,{status:'succeeded',observed:true,selection_nonempty:false});
  eq(transition.status,'completed','A failed context requirement does not deny an already observed effect');
  eq(transition.transition_refused,true); eq(engine.getState().active,false);
  refuses(() => engine.activate('selected'),/nonempty selection/);
  const activationFacts = {}; Object.defineProperty(activationFacts,'selection_nonempty',{enumerable:true,get(){++getters;return true;}});
  refuses(() => engine.activate('selected',activationFacts),/accessors/); eq(getters,0);
  engine.activate('selected',{selection_nonempty:true}); const lower = engine.accept(t('c'));
  eq(lower.invoke.command,'local.lower','Lowercase c and uppercase C remain distinct rules');
  eq(engine.owns(t('c'),{includeFutureContexts:true}),false,'An explicit exit destination never acquires a future root');
  const exited = engine.complete(lower.ticket,{status:'succeeded',observed:true}); eq(exited.context,null); eq(engine.getState().active,false);
  for (const outcome of [{status:'failed',observed:false},{status:'cancelled',observed:true},{status:'unknown',observed:false},{status:'succeeded',observed:false}]) {
    engine.activate(); const action = engine.accept(t('s'));
    eq(engine.complete(action.ticket,outcome).status,'stopped'); eq(engine.getState().active,false,'Failure or uncertainty never advances context');
  }
  engine.activate(); const pending = engine.accept(t('s'));
  refuses(() => engine.complete(pending.ticket,{status:'succeeded'}),/observed boolean/);
  eq(engine.getState().busy,true,'Malformed completion cannot advance or silently settle an admitted action');
  engine.accept(k('Escape')); refuses(() => engine.complete(pending.ticket,{status:'succeeded',observed:true}),/unowned/);
  engine.activate(); const snapshot = engine.getState(); refuses(() => snapshot.pending.push(t('s')),/extensible|read only/i);
  eq(engine.getState().pending,[]);
  const shared = profile(); shared.contexts[1].owned_roots.push(t('s')); shared.rules.push({id:'other.select',context:'selected',tokens:[t('s')],invoke:{command:'local.other'}});
  eq(validate(shared).rules.length,7,'The same sequence in disjoint explicit contexts is deterministic');
  const future = compile(profile()); future.activate(); const admitted = future.accept(k('F6'));
  const before = future.getState();
  eq(future.owns(t('e'),{includeFutureContexts:true,queued:[t('g')]}),true,'A busy predecessor may acquire the suffix of a queued explicit prefix');
  eq(future.owns(t('x'),{includeFutureContexts:true,queued:[t('g')]}),false,'Unknown future suffix is not owned');
  eq(future.owns(t('C'),{includeFutureContexts:true,queued:[t('s')]}),true,'Prospective ownership follows an explicit context transition');
  eq(future.owns(t('g'),{includeFutureContexts:true,queued:[t('s'),t('C')]}),true,'Further queued actions may have their own explicit next context');
  eq(future.owns(t('g'),{includeFutureContexts:true,queued:[t('s'),t('c')]}),false,'No ownership follows an explicit exit');
  eq(future.owns(t('g'),{includeFutureContexts:true,queued:[t('x')]}),false,'A malformed prospective path does not restart from root');
  eq(future.owns(t('s'),{includeFutureContexts:true,queued:[t('g'),k('Backspace')]}),true,'Prospective backspace only removes an unfinished prefix');
  eq(future.owns(t('s'),{includeFutureContexts:true,queued:[k('Escape')]}),false);
  refuses(()=>future.owns(t('g'),{includeFutureContexts:true,queued:Array(33).fill(t('g'))}),/invalid size/);
  eq(future.getState(),before,'Prospective inspection never changes actual prefix, context, admission or generation');
  future.complete(admitted.ticket,{status:'succeeded',observed:true});
  eq(future.accept(t('g')).status,'prefix'); const queuedEnd=future.accept(t('e'));
  eq(queuedEnd.invoke.command,'editor.extend_to_end','The same queued tokens are interpreted only after observed completion');
  const empty = {version:1,id:'user.empty',name:'Empty',entry_context:'none',contexts:[{id:'none',owned_roots:[]}],rules:[]};
  const inert = compile(empty); inert.activate(); eq(inert.owns(t('a')),false); eq(inert.accept(t('a')).consumed,false);
  return {passed:true,checks,scope:'Pure bounded contextual rule data/parser, deterministic prefixes and explicit observed transitions; no physical key acquisition, editor effects, persistence or IME proof'};
}
if (require.main === module) { try { console.log(JSON.stringify(run())); } catch(error) { console.error(error); process.exitCode=1; } }
module.exports = {run,profile};
