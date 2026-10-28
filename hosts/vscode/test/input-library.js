'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { InputLibrary, emptyProfile, MAX_BYTES, copy } = require('../input-library');
const plain = value => JSON.parse(JSON.stringify(value));
// Retained legacy declarations stay explicit when the new-user default changes.
const named = name => ({ ...plain(emptyProfile('neovim')), name, owned_roots: { normal: [{kind:'key',key:'F6',modifiers:[]}] },
  rules: [{id:'user.move',modes:['normal'],tokens:[{kind:'key',key:'F6',modifiers:[]}],
    invoke:{command:'ext.missing',args:{count:'1'}}}] });
async function run() {
  let checks = 0;
  const eq = (first, second, reason) => { assert.deepEqual(first, second, reason); ++checks; };
  async function refuses(action, pattern) { await assert.rejects(action, pattern); ++checks; }
  const validate = async profile => {
    if (!profile || profile.version !== 1 || !Array.isArray(profile.rules)
      || !['neovim','vscode'].includes(profile.input_profile)
      || Object.hasOwn(profile,'code')) throw new Error('Invalid shared input declaration');
    return profile;
  };
  function fixture(saved, options = {}) {
    let stored = saved, owner = true;
    const updates = [], keys = [];
    const storage = {get(key) { keys.push(key); return stored; }, async update(key,value) {
      if (options.update) await options.update(value);
      updates.push({key,value}); stored = value;
    }};
    const service = new InputLibrary({ storage, validate: options.validate || validate,
      live() { if (!owner) throw new Error('Owner changed'); } });
    return {service,storage,updates,keys,stored:()=>stored,loseOwner(){owner=false;},replace(value){stored=value;}};
  }
  const blank = fixture(); await blank.service.load();
  eq(blank.service.current().revision, 0);
  eq(blank.service.current().profile.input_profile, 'vscode', 'Fresh storage starts in the ordinary VS Code editor');
  eq(blank.service.current().profile.rules.length, 0, 'Loading does not install example keys');
  const draft = blank.service.draft();
  eq(Object.isFrozen(draft.profile.rules), true, 'A draft snapshot cannot mutate the persisted source');
  eq(blank.updates.length, 0, 'Creating a draft makes no durable or key-activation change');
  await blank.service.save(named('First'), draft.revision);
  eq(blank.stored().revision, 1, 'The revision is durable with its profile');
  eq(blank.stored().profile.rules[0].invoke.command, 'ext.missing', 'Missing external actions stay in saved data');
  eq(blank.updates[0].key, 're35.inputRules.v1', 'New input data is separate from the existing command library');
  const reload = new InputLibrary({storage:blank.storage,validate}); await reload.load();
  eq(reload.current().revision, 1, 'Reload preserves the durable revision');
  eq(reload.current().profile.name, 'First');
  await reload.save(named('Other owner'), 1);
  await refuses(() => blank.service.save(named('Stale owner'),1), /Saved input rules changed/);
  eq(blank.stored().profile.name, 'Other owner', 'A stale instance cannot overwrite an observed newer record');
  await refuses(() => reload.save(named('Stale revision'),1), /changed/);
  const retained = fixture({version:1,revision:7,profile:named('Unavailable')}); await retained.service.load();
  eq(retained.service.current().revision,7);
  eq(plain(retained.service.current().profile), named('Unavailable'), 'A saved legacy profile is data, not an implicit migration request');
  eq(retained.updates.length, 0, 'Loading legacy declarations does not save, replace or activate them');
  eq(retained.service.current().profile.rules[0].invoke.command,'ext.missing');
  const corrupt = fixture({version:99,revision:8,profile:named('Old')}); await corrupt.service.load();
  eq(corrupt.service.current().profile.rules.length,0);
  eq(corrupt.service.current().profile.input_profile,'vscode','A refused record falls back to an inert ordinary-editor draft');
  eq(corrupt.service.current().notice.includes('refused'),true);
  eq(corrupt.updates.length,0,'An invalid record is retained on disk for recovery');
  await corrupt.service.save(named('Explicit correction'),0);
  eq(corrupt.service.current().notice,undefined);
  eq(corrupt.stored().profile.name,'Explicit correction');
  const failed = fixture({version:1,revision:3,profile:named('Previous')},{update:async()=>{throw new Error('Disk refused');}});
  await failed.service.load();
  await refuses(()=>failed.service.save(named('Unsaved'),3),/Disk refused/);
  eq(failed.service.current().profile.name,'Previous','A rejected durable save keeps the prior profile');
  eq(failed.service.current().revision,3);
  eq(failed.updates.length,0);
  const invalid=named('Invalid'); invalid.code='return true';
  await refuses(()=>blank.service.save(invalid,1),/Invalid shared/);
  eq(blank.service.current().profile.name,'First','Validation failure preserves the live definition');
  let release; const gate=new Promise(resolve=>{release=resolve;});
  const concurrent=fixture(undefined,{update:()=>gate}); await concurrent.service.load();
  const saving=concurrent.service.save(named('Pending'),0);
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  await refuses(()=>concurrent.service.save(named('Other'),0),/already saving/);
  eq(concurrent.service.current().revision,0,'Pending storage does not preemptively change the revision');
  release(); await saving;
  eq(concurrent.service.current().revision,1);
  let getterCalls=0;
  const getter={}; Object.defineProperty(getter,'rules',{enumerable:true,get(){++getterCalls;return[];}});
  await refuses(async()=>copy(getter),/accessors/);
  eq(getterCalls,0,'Reading a profile cannot execute a getter');
  await refuses(async()=>copy(new Proxy({},{})),/plain JSON/);
  await refuses(async()=>copy({rules:[,]}),/dense/);
  await refuses(async()=>copy({text:'\ud800'}),/Unicode/);
  await refuses(async()=>copy({value:Infinity}),/plain JSON/);
  await refuses(async()=>copy({execute(){}}),/plain JSON/);
  const cycle={}; cycle.self=cycle; await refuses(async()=>copy(cycle),/plain JSON/);
  const unknownRecord=fixture({version:1,revision:2,profile:named('Unsafe'),activate:true}); await unknownRecord.service.load();
  eq(unknownRecord.service.current().notice.includes('refused'),true,'Unknown storage fields do not authorize execution');
  const recordGetter={version:1,revision:0}; Object.defineProperty(recordGetter,'profile',{enumerable:true,get(){++getterCalls;return named('Getter');}});
  const noGetter=fixture(recordGetter); await noGetter.service.load();
  eq(getterCalls,0,'Envelope validation also refuses accessors without calling them');
  eq(noGetter.service.current().profile.rules.length,0);
  const limit=fixture(); await limit.service.load();
  const exact=named('Exact'); exact.rules[0].invoke.args={data:''};
  exact.rules[0].invoke.args.data='x'.repeat(MAX_BYTES-Buffer.byteLength(JSON.stringify(exact),'utf8'));
  eq(Buffer.byteLength(JSON.stringify(exact),'utf8'),MAX_BYTES);
  await limit.service.save(exact,0);
  eq(limit.stored().revision,1,'The revision envelope does not reduce the 64 KiB profile budget');
  const fullReload=new InputLibrary({storage:limit.storage,validate}); await fullReload.load();
  eq(Buffer.byteLength(JSON.stringify(fullReload.current().profile),'utf8'),MAX_BYTES);
  exact.rules[0].invoke.args.data+='x'; await refuses(()=>limit.service.save(exact,1),/64 KiB/);
  const lost=fixture(); await lost.service.load(); lost.loseOwner();
  await refuses(()=>lost.service.save(named('Lost'),0),/Owner changed/); eq(lost.updates.length,0);
  const maxRevision=fixture({version:1,revision:Number.MAX_SAFE_INTEGER,profile:named('Last')}); await maxRevision.service.load();
  await refuses(()=>maxRevision.service.save(named('Overflow'),Number.MAX_SAFE_INTEGER),/revision limit/);
  eq(plain(emptyProfile('vscode')).input_profile,'vscode','A profile choice is saved preference data');
  await refuses(async()=>emptyProfile('other'),/preference/);
  const temporaryRoot=path.resolve(os.tmpdir()), folder=await fs.mkdtemp(path.join(temporaryRoot,'re35-input-library-'));
  try {
    const source=path.join(folder,'import.json'); await fs.writeFile(source,JSON.stringify(named('Import')));
    const imported=fixture(); await imported.service.load();
    const receipt=await imported.service.read(source);
    eq(imported.updates.length,0,'Import inspection cannot save or activate keys');
    eq(receipt.profile.rules[0].invoke.command,'ext.missing');
    await refuses(()=>imported.service.applyImport({...receipt}),/owned review/);
    await fs.writeFile(source,JSON.stringify(named('Changed after review')));
    await refuses(()=>imported.service.applyImport(receipt),/changed/);
    eq(imported.service.current().revision,0);
    const fresh=await imported.service.read(source); await imported.service.applyImport(fresh);
    eq(imported.service.current().profile.name,'Changed after review');
    eq(imported.service.current().revision,1);
    await refuses(()=>imported.service.applyImport(fresh),/changed/);
    const target=path.join(folder,'export.json'); await imported.service.export(target);
    const exported=JSON.parse(await fs.readFile(target,'utf8'));
    eq(exported.version,1); eq(exported.input_profile,'neovim');
    eq(exported.revision,undefined,'An exported profile does not smuggle in storage or activation authority');
    await refuses(()=>imported.service.export(target),/EEXIST/);
    await refuses(()=>imported.service.export(path.join(folder,'stale.json'),0),/changed/);
  } finally {
    assert.equal(path.dirname(folder),temporaryRoot); assert(path.basename(folder).startsWith('re35-input-library-'));
    await fs.rm(folder,{recursive:true,force:true});
  }
  return {checks};
}
if (require.main===module) run().then(result=>console.log(JSON.stringify(result)),error=>{console.error(error);process.exitCode=1;});
module.exports={run};
