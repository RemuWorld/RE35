'use strict';
// Controlled forms exercise the current authoring seam, not an adopted final
// screen. No test here captures real keys, types into an editor or drives IME.
const assert = require('node:assert/strict');
const { ContextualLibrary, seedGrammar, KEY } = require('../contextual-library');
const { createContextualActions } = require('../contextual-ui');
const plain = value => JSON.parse(JSON.stringify(value));
function fixture(answers = [], options = {}) {
  let stored = options.saved ? {version:1,revision:options.revision ?? 1,profile:options.saved} : undefined, current;
  let enabled = options.active === true;
  const updates=[],attempts=[],forms=[],activations=[],stops=[];
  const respond = async(scene,rows,config) => {
    forms.push({scene,rows,config}); const answer=answers.shift();
    assert(answer,'Unexpected authoring form: '+config.title);
    if(answer.after) await answer.after();
    if(answer.inspect) answer.inspect(rows,config);
    if(answer.cancel) return undefined;
    if(!rows) return answer.input;
    const selected=rows.find(row=>answer.select ? answer.select(row)
      : Object.hasOwn(answer,'action') ? row.action===answer.action
        : answer.rule ? row.rule?.id===answer.rule
          : answer.context ? row.context?.id===answer.context
            : answer.command ? row.command?.id===answer.command
              : answer.id ? row.id===answer.id
                : answer.kind ? row.kind===answer.kind
                  : Object.hasOwn(answer,'required') ? row.required===answer.required
                    : Object.hasOwn(answer,'edit') ? row.edit===answer.edit
                      : Object.hasOwn(answer,'value') ? row.value===answer.value
                        : answer.label ? row.label===answer.label : false);
    assert(selected,'Missing choice '+JSON.stringify(answer)+' in '+config.title); return selected;
  };
  const host={uiEpoch:0,disposed:false,presentationService:()=>({pick:(scene,rows,config)=>respond(scene,rows,config),input:(scene,config)=>respond(scene,null,config)})};
  current=host;
  const library=new ContextualLibrary({storage:{get:()=>stored,async update(key,value){
    attempts.push({key,value}); if(options.failSave) throw new Error('Storage unavailable');
    stored=value;updates.push({key,value});
  }},live(){if(current!==host || host.disposed)throw new Error('Owner changed');}});
  const catalog=options.catalog || [
    {id:'editor.select_line',name:'Select line',arguments:[]},
    {id:'editor.uppercase_selection',name:'Uppercase selection',arguments:[]},
    {id:'local.trim',name:'Trim line',arguments:[]},
    {id:'local.decorate',name:'Decorate line',arguments:[
      {name:'suffix',kind:'text',required:true},
      {name:'flag',kind:'boolean',required:false},
      {name:'flavor',kind:'select',required:true,items:[{label:'Warm',value:'warm'},'cold']},
      {name:'count',kind:'number',required:true}
    ]}
  ];
  const actions=createContextualActions({getHost:()=>current,getLibrary:()=>library,catalog:()=>catalog,
    async activate(service,profile){assert.equal(service,host);if(options.activate)await options.activate();activations.push(plain(profile));enabled=true;},
    async deactivate(reason){stops.push(reason);enabled=false;},state:()=>({enabled}),
    owned(service){if(current!==service || service.disposed)throw new Error('Owner changed');}});
  return {host,library,answers,actions,updates,attempts,forms,activations,stops,stored:()=>stored,
    retire(){current={disposed:false,uiEpoch:0};},
    open:()=>actions['input.contexts_manage'](),
    settled(){assert.equal(answers.length,0,'Every intended authoring answer was consumed');}};
}
const addRule = ({id='rule.trim',name='Trim line',sequence='zz',command='local.trim',context='commands',next='Stay in this context'}={}) => [
  {action:'add'},{command},{input:id},{input:name},{id:context},{kind:'text'},{input:sequence},{label:next}
];
async function run() {
  let checks=0;
  const eq=(actual,expected,reason)=>{assert.deepEqual(actual,expected,reason);++checks;};
  const rejects=async(action,reason)=>{await assert.rejects(action,reason);++checks;};
  const seed=plain(seedGrammar());
  const idle=fixture([{action:'back',inspect(rows,config){eq(config.placeHolder.includes('not saved'),true);}}]);
  eq((await idle.open()).status,'cancelled');idle.settled();eq(idle.updates.length,0);eq(idle.activations.length,0);
  eq(idle.library.current().revision,0);
  const unsaved=fixture([{action:'activate'}]);await rejects(()=>unsaved.open(),/Save the example/);unsaved.settled();eq(unsaved.activations.length,0);
  const savedSeed=fixture([{action:'save'},{action:'back'}]);await savedSeed.open();savedSeed.settled();
  eq(savedSeed.updates.length,1);eq(savedSeed.updates[0].key,KEY);eq(savedSeed.activations.length,0,'Explicit save never activates input');
  eq(savedSeed.host.contextualDraft,undefined);
  const persisted=fixture([{action:'back'}],{saved:savedSeed.library.current().profile,revision:2});await persisted.open();persisted.settled();
  eq(persisted.activations.length,0,'Loading persisted definitions does not acquire keys');
  const activated=fixture([{action:'activate'}],{saved:seed});eq((await activated.open()).status,'succeeded');activated.settled();
  eq(activated.activations.length,1);eq(activated.updates.length,0,'Activation does not rewrite saved data');
  eq(activated.activations[0].rules[0].next_context,'selected');

  const added=fixture([...addRule(),{action:'save'},{action:'back'}],{saved:seed});await added.open();added.settled();
  eq(added.updates.length,1);eq(added.activations.length,0);eq(added.library.current().profile.rules.length,3);
  const addedRule=added.library.current().profile.rules.find(rule=>rule.id==='rule.trim');
  eq(plain(addedRule.invoke),{command:'local.trim',args:{}});eq(addedRule.tokens.map(token=>token.text),['z','z']);
  eq(added.library.current().profile.contexts[0].owned_roots.map(token=>token.text),['l','z'],'Root ownership is derived from authored rules');
  const editing=fixture([{rule:'rule.trim'},{edit:true},{command:'local.trim'},{input:'rule.trim'},{input:'Trim again'},{id:'commands'},
    {kind:'text'},{input:'yy'},{label:'Return to ordinary editor typing'},{action:'save'},{action:'back'}],{saved:added.library.current().profile});
  await editing.open();editing.settled();
  eq(editing.library.current().profile.rules.find(rule=>rule.id==='rule.trim').name,'Trim again');
  eq(editing.library.current().profile.rules.find(rule=>rule.id==='rule.trim').next_context,null);
  eq(editing.library.current().profile.contexts[0].owned_roots.map(token=>token.text),['l','y'],'Changing input releases the old root in the next saved definition');
  const removed=fixture([{rule:'rule.trim'},{edit:false},{action:'save'},{action:'back'}],{saved:editing.library.current().profile});
  await removed.open();removed.settled();eq(removed.library.current().profile.rules.length,2);
  eq(removed.library.current().profile.contexts[0].owned_roots.map(token=>token.text),['l']);eq(removed.activations.length,0);

  const rich=fixture([{action:'add'},{command:'local.decorate'},{input:'rule.decorate'},{input:'Decorate'},{id:'commands'},
    {kind:'key'},{label:'F8'},{input:'한글 😀'},{label:'Set flag'},{value:false},{value:'warm'},{input:'3.5'},
    {label:'Enter Selected line'},{action:'save'},{action:'back'}],{saved:seed});
  await rich.open();rich.settled();
  const decorated=rich.library.current().profile.rules.find(rule=>rule.id==='rule.decorate');
  eq(plain(decorated.tokens),[{kind:'key',key:'F8',modifiers:[]}]);
  eq(plain(decorated.invoke.args),{suffix:'한글 😀',flag:false,flavor:'warm',count:3.5});eq(decorated.next_context,'selected');
  const badNumber=fixture([{action:'add'},{command:'local.decorate'},{input:'rule.bad'},{input:'Bad number'},{id:'commands'},
    {kind:'key'},{label:'F8'},{input:'x'},{label:'Use default'},{value:'cold'},{input:'Infinity'}],{saved:seed});
  await rejects(()=>badNumber.open(),/finite number/);badNumber.settled();eq(badNumber.updates.length,0);
  const unavailable=fixture([{action:'add'},{command:'local.unavailable'}],{saved:seed,catalog:[{id:'local.unavailable',name:'Unavailable',unavailable:'Missing provider'}]});
  await rejects(()=>unavailable.open(),/Missing provider/);unavailable.settled();eq(unavailable.host.contextualDraft,undefined);

  const draft=fixture([...addRule(),{action:'back'}],{saved:seed});await draft.open();draft.settled();
  eq(draft.updates.length,0);eq(draft.host.contextualDraft.profile.rules.length,3,'Closing the manager retains the unsaved complete draft');
  const retained=plain(draft.host.contextualDraft);
  draft.answers.push({action:'add'},{command:'local.trim'},{input:'rule.cancelled'},{cancel:true},{action:'back'});
  await draft.open();draft.settled();eq(plain(draft.host.contextualDraft),retained,'Cancelling a new form never erases the earlier complete draft');
  draft.answers.push({action:'activate'});await rejects(()=>draft.open(),/Save or discard/);draft.settled();eq(draft.activations.length,0);
  draft.answers.push({action:'discard'},{action:'back'});await draft.open();draft.settled();eq(draft.host.contextualDraft,undefined);eq(draft.library.current().profile.rules.length,2);
  const cancelRemove=fixture([{rule:'line'},{cancel:true},{action:'back'}],{saved:seed});await cancelRemove.open();cancelRemove.settled();eq(cancelRemove.host.contextualDraft,undefined);
  const collision=fixture([...addRule({id:'rule.collision',sequence:'l'}),{action:'save'}],{saved:seed});
  await rejects(()=>collision.open(),/prefix collision/);collision.settled();eq(collision.updates.length,0);eq(collision.library.current().revision,1);
  eq(collision.host.contextualDraft.profile.rules.length,3,'A refused save keeps the correction draft and previous good definitions');
  const failed=fixture([...addRule(),{action:'save'}],{saved:seed,failSave:true});
  await rejects(()=>failed.open(),/Storage unavailable/);failed.settled();eq(failed.library.current().revision,1);eq(failed.library.current().profile.rules.length,2);
  eq(failed.host.contextualDraft.profile.rules.length,3);eq(failed.activations.length,0);

  const contexts=fixture([{action:'context'},{input:'extra'},{input:'Extra commands'},{required:true},{action:'back'}],{saved:seed});
  await contexts.open();contexts.settled();eq(contexts.host.contextualDraft.profile.contexts.length,3);eq(contexts.updates.length,0);
  contexts.answers.push({context:'extra'},{action:'edit'},{input:'Renamed context'},{required:false},{action:'save'},{action:'back'});
  await contexts.open();contexts.settled();
  const extra=contexts.library.current().profile.contexts.find(context=>context.id==='extra');
  eq(extra.name,'Renamed context');eq(extra.requires_selection,false);eq(extra.id,'extra','Renaming a label never changes stable context references');
  contexts.answers.push({action:'entry'},{context:'extra'},{action:'save'},{action:'back'});await contexts.open();contexts.settled();
  eq(contexts.library.current().profile.entry_context,'extra');
  contexts.answers.push({context:'extra'},{action:'remove'});await rejects(()=>contexts.open(),/another entry/);contexts.settled();
  eq(contexts.library.current().profile.contexts.length,3);
  contexts.answers.push({context:'commands'},{action:'entry'},{context:'extra'},{action:'remove'},{action:'save'},{action:'back'});
  await contexts.open();contexts.settled();eq(contexts.library.current().profile.contexts.length,2);eq(contexts.library.current().profile.entry_context,'commands');
  const referenced=fixture([{context:'selected'},{action:'remove'}],{saved:seed});
  await rejects(()=>referenced.open(),/still referenced/);referenced.settled();eq(referenced.updates.length,0);eq(referenced.library.current().profile.contexts.length,2);
  const only=fixture([{context:'only'},{action:'remove'}],{saved:{version:1,id:'one',name:'One',entry_context:'only',contexts:[{id:'only',owned_roots:[]}],rules:[]}});
  await rejects(()=>only.open(),/another entry/);only.settled();eq(only.updates.length,0);
  const requirement=fixture([{context:'selected'},{action:'edit'},{input:'Selection context'},{required:false},{action:'save'},{action:'back'}],{saved:seed});
  await requirement.open();requirement.settled();eq(requirement.library.current().profile.contexts[1].requires_selection,false);
  eq(requirement.library.current().profile.rules[0].next_context,'selected');eq(requirement.library.current().profile.rules[1].context,'selected');
  const removeReferenced=fixture([{rule:'line'},{edit:false},{rule:'capital'},{edit:false},{context:'selected'},{action:'remove'},{action:'save'},{action:'back'}],{saved:seed});
  await removeReferenced.open();removeReferenced.settled();eq(removeReferenced.library.current().profile.rules.length,0);eq(removeReferenced.library.current().profile.contexts.length,1);

  const epoch=fixture([{action:'add',after(){++epoch.host.uiEpoch;}}],{saved:seed});
  await rejects(()=>epoch.open(),error=>error.code==='RE35_UI_RETIRED');epoch.settled();eq(epoch.updates.length,0);eq(epoch.activations.length,0);
  const retired=fixture([{action:'add',after(){retired.retire();}}],{saved:seed});await rejects(()=>retired.open(),/Owner changed/);retired.settled();eq(retired.updates.length,0);
  const stale=fixture([...addRule(),{action:'back'}],{saved:seed});await stale.open();stale.settled();
  const oldDraft=plain(stale.host.contextualDraft), newer={...plain(seed),name:'Saved elsewhere'};
  await stale.library.save(newer,1);
  stale.answers.push({action:'back',inspect(rows,config){eq(config.title,'RE35 Draft Needs Review');eq(rows.some(row=>row.action==='activate'||row.action==='save'),false);}});
  await stale.open();stale.settled();eq(plain(stale.host.contextualDraft),oldDraft);eq(stale.library.current().profile.name,'Saved elsewhere');
  stale.answers.push({action:'discard'},{action:'back',inspect(rows,config){eq(config.title,'RE35 Command Contexts');}});
  await stale.open();stale.settled();eq(stale.host.contextualDraft,undefined);eq(stale.library.current().profile.name,'Saved elsewhere');
  const changed=fixture([{action:'save',after:async()=>{await changed.library.save(newer,1);}}],{saved:seed});
  await rejects(()=>changed.open(),/changed/);changed.settled();eq(changed.updates.length,1,'Only the independent newer save reaches storage');
  eq(changed.library.current().profile.name,'Saved elsewhere');
  const stopped=fixture([{action:'stop'}],{saved:seed,active:true});eq((await stopped.open()).status,'succeeded');stopped.settled();eq(stopped.stops,['Stopped by user']);eq(stopped.updates.length,0);
  const pendingActivation=fixture([{action:'activate'}],{saved:seed,activate:async()=>{++pendingActivation.host.uiEpoch;}});
  await rejects(()=>pendingActivation.open(),error=>error.code==='RE35_UI_RETIRED');pendingActivation.settled();
  return {passed:true,checks,scope:'Controlled authoring seam, draft/save/activation separation, rule/context editing, retired screens and failed persistence; no final UI adoption, physical keys or IME proof'};
}
if(require.main===module) run().then(value=>console.log(JSON.stringify(value)),error=>{console.error(error);process.exitCode=1;});
module.exports={run};
