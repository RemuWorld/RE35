'use strict';
const assert = require('node:assert/strict');
const { ContextualLibrary, seedGrammar, KEY } = require('../contextual-library');
const { compile, validate, LIMITS } = require('../contextual-grammar');
const plain = value => JSON.parse(JSON.stringify(value));
const named = name => ({ ...plain(seedGrammar()), name });
function fixture(initial, options = {}) {
  let stored = initial, live = true;
  const writes = [], attempts = [], reads = [];
  const storage = { get(key) { reads.push(key); return stored; }, async update(key, value) {
    attempts.push({ key, value }); if (options.update) await options.update(value);
    stored = value; writes.push({ key, value });
  } };
  const library = new ContextualLibrary({ storage, live() { if (!live) throw new Error('Owner changed'); } });
  return { library, storage, writes, attempts, reads, stored: () => stored, replace: value => { stored = value; }, loseOwner: () => { live = false; } };
}
async function run() {
  let checks = 0;
  const eq = (actual, expected, reason) => { assert.deepEqual(actual, expected, reason); ++checks; };
  const rejects = async (action, reason) => { await assert.rejects(action, reason); ++checks; };
  const fresh = fixture();
  assert.throws(() => fresh.library.current(), /not loaded/); ++checks;
  const initial = await fresh.library.load();
  eq(initial.revision, 0); eq(initial.notice, null); eq(fresh.writes.length, 0);
  eq(initial.profile.rules.map(rule => rule.tokens.map(token => token.text).join('')), ['l', 'C']);
  eq(initial.profile.rules.map(rule => rule.invoke.command), ['editor.select_line', 'editor.uppercase_selection']);
  eq(compile(initial.profile).getState().active, false, 'Loading example definitions grants no input ownership');
  eq(Object.isFrozen(initial.profile.contexts[0].owned_roots), true);
  eq(fresh.reads.every(key => key === KEY), true, 'Contextual rules have their own durable key');
  await fresh.library.load(); eq(fresh.reads.length, 1, 'A loaded live instance does not replace data or reinstall input');
  const candidate = named('First saved profile'); await fresh.library.save(candidate, 0);
  candidate.name = 'Caller changed';
  eq(fresh.writes.length, 1); eq(fresh.writes[0].key, 're35.contextualRules.v1');
  eq(fresh.library.current().profile.name, 'First saved profile'); eq(fresh.library.current().revision, 1);
  eq(Object.keys(fresh.stored()), ['version', 'revision', 'profile'], 'Storage contains no source, active owner or in-flight prefix');
  const reload = new ContextualLibrary({ storage: fresh.storage }); await reload.load();
  eq(reload.current().profile.name, 'First saved profile'); eq(reload.current().revision, 1);
  eq(compile(reload.current().profile).getState().active, false, 'Restarting reloads definitions without automatically activating them');
  await rejects(() => reload.save(named('Wrong revision'), 0), /changed/);
  await reload.save(named('Other owner'), 1);
  await rejects(() => fresh.library.save(named('Stale owner'), 1), /another owner/);
  eq(fresh.stored().profile.name, 'Other owner', 'An already observed newer durable owner cannot be overwritten');
  const missing = named('Unavailable extension retained'); missing.rules[0].invoke.command = 'future.user_action';
  const portable = fixture({version:1,revision:5,profile:missing}); await portable.library.load();
  eq(portable.library.current().profile.rules[0].invoke.command, 'future.user_action');
  eq(portable.writes.length, 0, 'Loading does not delete definitions because their action is unavailable');

  const previous = {version:1,revision:7,profile:named('Previous good')}, failure = fixture(previous, {update:async()=>{throw new Error('Storage refused');}});
  await failure.library.load();
  await rejects(() => failure.library.save(named('Unsaved'), 7), /Storage refused/);
  eq(failure.library.current().revision, 7); eq(failure.library.current().profile.name, 'Previous good');
  eq(failure.stored(), previous); eq(failure.writes.length, 0); eq(failure.library.saving, false, 'Failure releases only the save guard');
  const collision = named('Colliding'); collision.rules.push({...plain(collision.rules[0]),id:'duplicate.root'});
  await rejects(() => failure.library.save(collision, 7), /prefix collision/);
  eq(failure.attempts.length, 1, 'Invalid rule data never reaches durable storage');
  eq(failure.library.current().profile.name, 'Previous good');
  const transition = named('Bad transition'); transition.rules[0].next_context='missing';
  await rejects(() => failure.library.save(transition,7),/next context/); eq(failure.library.current().revision,7);

  for (const corrupt of [null, {version:99,revision:2,profile:named('Unknown')}, {version:1,revision:-1,profile:named('Bad revision')},
    {version:1,revision:2,profile:named('Hidden authority'),active:true}, {version:1,revision:2},
    {version:1,revision:2,profile:{...named('Invalid'),rules:[] ,contexts:[]}}]) {
    const broken = fixture(corrupt); await broken.library.load();
    eq(broken.library.current().notice.includes('refused'), true); eq(broken.library.current().revision,0);
    eq(broken.writes.length,0); eq(broken.stored(),corrupt,'A malformed record is preserved until an explicit correction');
    await broken.library.save(named('Explicit correction'),0);
    eq(broken.library.current().profile.name,'Explicit correction'); eq(broken.library.current().notice,null);
  }
  let getters=0; const record={version:1,revision:1}; Object.defineProperty(record,'profile',{enumerable:true,get(){++getters;return named('Getter');}});
  const accessor=fixture(record); await accessor.library.load(); eq(getters,0); eq(accessor.library.current().notice.includes('refused'),true);
  await rejects(()=>accessor.library.save(named('Cannot compare an unsafe record'),0),/plain data/); eq(getters,0); eq(accessor.writes.length,0);
  const hidden={version:1,revision:0,profile:named('Hidden')}; Object.defineProperty(hidden,'execute',{value:()=>{}});
  const hiddenRecord=fixture(hidden); await hiddenRecord.library.load(); eq(hiddenRecord.library.current().notice.includes('refused'),true);
  const proxy=fixture(new Proxy({},{})); await proxy.library.load(); eq(proxy.library.current().notice.includes('refused'),true); eq(proxy.writes.length,0);

  let release; const gate=new Promise(resolve=>{release=resolve;});
  const pending=fixture(undefined,{update:()=>gate}); await pending.library.load();
  const saving=pending.library.save(named('Pending save'),0);
  eq(pending.library.current().revision,0,'Unresolved storage does not publish a new live revision');
  await rejects(()=>pending.library.save(named('Overlapping save'),0),/another save/);
  release(); await saving; eq(pending.library.current().revision,1); eq(pending.writes.length,1);
  const limit=fixture({version:1,revision:Number.MAX_SAFE_INTEGER,profile:named('Last revision')}); await limit.library.load();
  await rejects(()=>limit.library.save(named('Overflow'),Number.MAX_SAFE_INTEGER),/revision limit/); eq(limit.writes.length,0);
  const lost=fixture(); await lost.library.load(); lost.loseOwner();
  await rejects(()=>lost.library.save(named('Lost owner'),0),/Owner changed/); eq(lost.writes.length,0);
  let revoke; const ownershipGate=new Promise(resolve=>{revoke=resolve;});
  const changing=fixture(undefined,{update:()=>ownershipGate}); await changing.library.load();
  const write=changing.library.save(named('Durable but retired'),0); changing.loseOwner(); revoke();
  await rejects(()=>write,/Owner changed/);
  eq(changing.stored().profile.name,'Durable but retired','Owner loss after a completed write never rolls a durable record back');
  const nextOwner=new ContextualLibrary({storage:changing.storage}); await nextOwner.load(); eq(nextOwner.current().revision,1);

  const full=named('Full budget'); full.rules[0].invoke.args.padding='';
  full.rules[0].invoke.args.padding='x'.repeat(LIMITS.bytes-Buffer.byteLength(JSON.stringify(full),'utf8'));
  eq(Buffer.byteLength(JSON.stringify(validate(full)),'utf8'),LIMITS.bytes);
  const exact=fixture(); await exact.library.load(); await exact.library.save(full,0);
  eq(exact.stored().revision,1,'The revision envelope does not steal bytes from a valid 64 KiB profile');
  const fullReload=new ContextualLibrary({storage:exact.storage}); await fullReload.load();
  eq(Buffer.byteLength(JSON.stringify(fullReload.current().profile),'utf8'),LIMITS.bytes);
  full.rules[0].invoke.args.padding+='x'; await rejects(()=>exact.library.save(full,1),/64 KiB/);
  eq(exact.library.current().revision,1); eq(exact.writes.length,1);
  return {passed:true,checks,scope:'Controlled durable state, exact profile budget, inactive reload, revisions and refused writes; no physical input or editor execution proof'};
}
if(require.main===module) run().then(value=>console.log(JSON.stringify(value)),error=>{console.error(error);process.exitCode=1;});
module.exports={run};
