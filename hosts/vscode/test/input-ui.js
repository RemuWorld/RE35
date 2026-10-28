'use strict';
// Controlled native forms exercise authoring and persistence. They do not prove
// physical input acquisition or execute an editing engine.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { InputLibrary, emptyProfile } = require('../input-library');
const { createInputActions } = require('../input-ui');
const plain = value => JSON.parse(JSON.stringify(value));
// These retained records exercise old user data, not the new-user default.
const sample = name => ({...plain(emptyProfile('neovim')),name,owned_roots:{normal:[{kind:'key',key:'F6',modifiers:[]}]},
  rules:[{id:'rule.move',name:'Move',modes:['normal'],tokens:[{kind:'key',key:'F6',modifiers:[]}],
    invoke:{command:'edit.move_words',args:{count:'1'}}}]});
async function run() {
  let checks=0;
  const eq=(actual,expected,label)=>{assert.deepEqual(actual,expected,label);++checks;};
  function fixture(answers,options={}) {
    let stored=options.saved && {version:1,revision:options.revision || 0,profile:options.saved};
    let currentHost;
    const forms=[],updates=[],messages=[],activations=[],pauses=[],inspections=[];
    const ui={workspace:{isTrusted:true},window:{
      async showInformationMessage(text){messages.push({level:'info',text});},
      async showErrorMessage(text){messages.push({level:'error',text});},
      async showOpenDialog(){return options.files;},async showSaveDialog(){return options.file;}
    }};
    const respond=async(scene,rows,native)=>{
      forms.push({scene,rows,native}); const answer=answers.shift();
      assert(answer,'Unexpected form: '+native.title);
      if(answer.after) await answer.after();
      if(answer.inspect) answer.inspect(rows,native);
      if(answer.cancel) return undefined;
      if(!rows) return answer.input;
      const chosen=rows.find(row=>answer.action!==undefined?row.action===answer.action
        :answer.command?row.command?.id===answer.command
          :answer.key?row.key===answer.key
            :answer.mode?row.mode===answer.mode
              :Object.hasOwn(answer,'value')?row.value===answer.value
                :answer.label?row.label===answer.label:row.index===answer.index);
      assert(chosen,'Choice missing: '+JSON.stringify(answer)+' in '+native.title);return chosen;
    };
    const host={disposed:false,uiEpoch:0,presentationService:()=>({pick:(scene,rows,native)=>respond(scene,rows,native),
      input:(scene,native)=>respond(scene,null,native)})};currentHost=host;
    const validate=async profile=>{
      // Full schema/host validation has its own portable fixtures. This narrow
      // injected boundary only checks the fields that these UI scenarios edit.
      if(profile.version!==1 || !Array.isArray(profile.rules) || !['neovim','vscode'].includes(profile.input_profile)) throw new Error('Invalid input declaration');
      const ids=new Set(),keys=new Set();
      for(const rule of profile.rules){
        if(!rule.id || ids.has(rule.id) || !rule.tokens.length || !rule.modes.length) throw new Error('Invalid input rule');ids.add(rule.id);
        for(const mode of rule.modes){
          const identity=mode+':'+JSON.stringify(rule.tokens);if(keys.has(identity))throw new Error('Rule collision');keys.add(identity);
          if(!(profile.owned_roots[mode] || []).some(token=>JSON.stringify(token)===JSON.stringify(rule.tokens[0]))) throw new Error('Missing root ownership');
        }
      }
      return profile;
    };
    const library=new InputLibrary({storage:{get:()=>stored,async update(key,value){
      if(options.failSave)throw new Error('Storage unavailable');updates.push({key,value});stored=value;
    }},validate,live(){if(currentHost!==host || host.disposed || !ui.workspace.isTrusted)throw new Error('Owner changed');}});
    const actions=createInputActions({getHost:()=>currentHost,getLibrary:()=>library,
      getCatalog:()=>options.catalog || [
        {id:'editor.move_words',name:'Move words',arguments:[{name:'count',kind:'text',required:true}]},
        {id:'edit.move_words',name:'Legacy move words',arguments:[{name:'count',kind:'text',required:true}]}
      ],
      async inspect(service,profile){
        inspections.push(plain(profile));
        return options.report || {available:true,diagnostics:[]};
      },
      async activate(service,profile,report,config){
        activations.push({profile:plain(profile),report,config});
        if(options.conflict && !config?.allowNativeOverride)throw Object.assign(new Error('Native F6 mapping exists'),{code:'mapping-conflict'});
      },
      async pause(service,reason){pauses.push(reason);},state:()=>options.state || {status:'inactive',message:'Editor keys inactive'},vscode:ui});
    return{actions,library,host,ui,forms,updates,messages,activations,pauses,inspections,stored:()=>stored,
      retire(){currentHost={disposed:false};},settled(){eq(answers.length,0,'The controlled UI consumed every intended answer');}};
  }
  const add=[{action:'add'},{command:'editor.move_words'},{input:'Next word'},{input:'rule.next_word'},
    {key:'F6'},{mode:'editor'},{input:'1'}];
  const create=fixture([...add,{action:'save'},{action:'back'}]);
  await create.actions['input.rules_manage']();create.settled();
  eq(create.updates.length,1,'Only an explicit save writes newly authored rules');
  eq(create.updates[0].key,'re35.inputRules.v1');
  eq(create.library.current().profile.input_profile,'vscode','New authoring uses the ordinary editor without choosing an engine');
  eq(plain(create.library.current().profile.rules[0].invoke),{command:'editor.move_words',args:{count:'1'}});
  eq(plain(create.library.current().profile.owned_roots.editor),[{kind:'key',key:'F6',modifiers:[]}],
    'The authored function key has an explicit root-ownership declaration');
  eq(create.activations.length,0,'Saving is separate from key activation');
  eq(create.pauses.length,1,'A saved definition replaces no live key meaning without an explicit activation');
  eq(create.messages.some(message=>message.level==='info'&&message.text.includes('saved')),true);
  const implicitText=fixture([...add,{action:'save'},{action:'back'}],{catalog:[
    {id:'editor.move_words',name:'Move words',arguments:[{name:'count',required:true}]}
  ]});
  await implicitText.actions['input.rules_manage']();implicitText.settled();
  eq(plain(implicitText.library.current().profile.rules[0].invoke),{command:'editor.move_words',args:{count:'1'}},
    'An omitted argument kind uses the same text default as registration and invocation');
  eq(implicitText.messages.some(message=>message.level==='error'),false);
  for(const [state,expected] of [
    [{enabled:true,ready:true},'Active'],[{enabled:true,ready:true,busy:true},'Running'],
    [{enabled:true,suspended:true},'Paused'],[{enabled:true,blocked:true},'Needs inspection'],
    [{enabled:true,ready:false},'Waiting']
  ]){
    const status=fixture([{action:'back',inspect(rows){
      eq(rows.find(row=>row.action==='pause').description,expected,'The input row reflects the connection flags');
    }}],{state});
    await status.actions['input.rules_manage']();status.settled();
  }
  const separate=fixture([...add,{action:'save'},{action:'activate'},{action:'activate'}]);
  await separate.actions['input.rules_manage']();separate.settled();
  eq(separate.updates.length,1);eq(separate.activations.length,1);
  eq(separate.activations[0].profile.rules[0].id,'rule.next_word');
  eq(separate.inspections.length,1,'Explicit activation first inspects the stored definition');
  const cancelled=fixture([{action:'add'},{command:'editor.move_words'},{input:'Unused'},{input:'rule.unused'},
    {cancel:true},{action:'back'}]);
  await cancelled.actions['input.rules_manage']();cancelled.settled();
  eq(cancelled.updates.length,0);eq(cancelled.activations.length,0);
  eq(cancelled.host.inputDraft.rules.length,0,'Cancelling a partially authored rule does not append it');
  const failed=fixture([...add,{action:'save'},{action:'back',inspect(rows,native){
    eq(native.placeHolder.startsWith('Unsaved draft'),true,'A failed save is still visibly a draft');
    eq(rows.find(row=>row.index===0).description,'rule.next_word');
  }}],{failSave:true});
  await failed.actions['input.rules_manage']();failed.settled();
  eq(failed.library.current().profile.rules.length,0,'Failed persistence keeps the previous saved profile');
  eq(failed.host.inputDraft.rules[0].id,'rule.next_word','The unsaved candidate remains available to correct or retry');
  eq(failed.activations.length,0);eq(failed.pauses.length,0);
  eq(failed.messages.some(message=>message.level==='error'&&message.text.includes('Storage unavailable')),true);
  const continued=fixture([...add,{action:'back'},{action:'save',inspect(rows){
    eq(rows.some(row=>row.description==='rule.next_word'),true,'Reopening restores the session draft');
  }},{action:'back'}]);
  await continued.actions['input.rules_manage']();
  eq(continued.updates.length,0,'Closing the draft does not persist it');
  await continued.actions['input.rules_manage']();continued.settled();
  eq(continued.updates.length,1);eq(continued.activations.length,0);
  const freshChoice=fixture([{action:'profile'},{value:'vscode',inspect(rows){
    eq(rows.map(row=>row.value),['vscode'],'Fresh authoring offers the current editor profile without creating legacy native input');
  }},{action:'back'}]);
  await freshChoice.actions['input.rules_manage']();freshChoice.settled();
  eq(freshChoice.updates.length,0);eq(freshChoice.activations.length,0);
  const legacy=sample('Legacy preference');
  const legacyChoice=fixture([{action:'profile'},{value:'neovim',inspect(rows){
    eq(rows.map(row=>row.value),['vscode','neovim'],'Existing legacy data keeps a visible ordinary-editor alternative');
    eq(rows[1].label,'Existing Neovim profile (legacy)');
  }},{action:'back'}],{saved:legacy});
  await legacyChoice.actions['input.rules_manage']();legacyChoice.settled();
  eq(plain(legacyChoice.library.current().profile),legacy,'Reviewing a legacy profile does not translate modes or command IDs');
  eq(legacyChoice.updates.length,0);eq(legacyChoice.activations.length,0);
  const preset=fixture([{action:'profile'},{value:'vscode'},{action:'save'},{action:'activate'},
    {cancel:true,inspect(rows,native){eq(native.title,'RE35 Input Unavailable');eq(rows[0].detail.includes('not supported'),true);}}],
    {report:{available:false,diagnostics:[{code:'mode_unsupported',reason:'The current editor input is not supported in this owned fixture'}]}});
  await preset.actions['input.rules_manage']();preset.settled();
  eq(preset.library.current().profile.input_profile,'vscode','An unsupported preference remains saved and editable');
  eq(preset.activations.length,0,'A preference choice does not invent physical editor-mode support');
  const saved=sample('Existing');
  const change=fixture([{index:0},{action:'edit'},{command:'edit.move_words'},{input:'Renamed'},
    {key:'F7'},{mode:'normal'},{input:'2'},{action:'save'},{action:'back'}],{saved});
  await change.actions['input.rules_manage']();change.settled();
  eq(change.library.current().profile.rules[0].id,'rule.move','Renaming or rebinding preserves the stable rule ID');
  eq(change.library.current().profile.rules[0].name,'Renamed');
  eq(change.library.current().profile.owned_roots.normal[0].key,'F7','Rebinding does not leave an old-key alias');
  eq(change.activations.length,0);
  const retained=sample('Retained count data');
  const countRoots=Array.from({length:9},(_,index)=>({kind:'text',text:String(index+1)}));
  retained.counts={modes:['normal']};
  retained.owned_roots.normal.push(...countRoots,{kind:'key',key:'F12',modifiers:[]});
  const retainedChange=fixture([{index:0},{action:'edit'},{command:'edit.move_words'},{input:'Rebound'},
    {key:'F7'},{mode:'normal'},{input:'2'},{action:'save'},{action:'back'}],{saved:retained});
  await retainedChange.actions['input.rules_manage']();retainedChange.settled();
  const retainedProfile=plain(retainedChange.library.current().profile);
  eq(retainedProfile.counts,{modes:['normal']},'An atomic rule edit retains unsupported count declarations');
  eq(retainedProfile.owned_roots.normal.filter(token=>token.kind==='text'),countRoots,
    'Count ownership roots survive unrelated rule edits');
  eq(retainedProfile.owned_roots.normal.some(token=>token.key==='F12'),true,'Unreferenced explicit ownership is retained');
  eq(retainedProfile.owned_roots.normal.some(token=>token.key==='F6'),false,'Only the explicitly rebound rule root is retired');
  eq(retainedProfile.owned_roots.normal.some(token=>token.key==='F7'),true);
  const unchangedRoots=fixture([{index:0},{action:'back'},{action:'back'}],{saved:retained});
  await unchangedRoots.actions['input.rules_manage']();unchangedRoots.settled();
  eq(unchangedRoots.host.inputDraft,retained,'Backing out of a rule menu preserves exact retained ownership order');
  const discard=fixture([...add,{action:'discard'},{action:'back'}]);
  await discard.actions['input.rules_manage']();discard.settled();
  eq(discard.host.inputDraft.rules.length,0);eq(discard.updates.length,0);
  const denied=fixture([{action:'activate'},{action:'activate'},{action:'back'}],{saved,conflict:true});
  await denied.actions['input.rules_manage']();denied.settled();
  eq(denied.activations.length,1,'A mapping-conflict response alone cannot authorize replacement');
  eq(denied.activations[0].config,undefined);
  const override=fixture([{action:'activate'},{action:'activate'},{action:'override'}],{saved,conflict:true});
  await override.actions['input.rules_manage']();override.settled();
  eq(override.activations.length,2);eq(override.activations[1].config,{allowNativeOverride:true});
  eq(override.updates.length,0,'A session override is not silently persisted');
  const foreign=fixture([{action:'activate'},{cancel:true,inspect(rows){eq(rows[0].detail,'External action is not installed');}}],
    {saved,report:{available:false,diagnostics:[{rule:'rule.move',code:'command_unavailable',reason:'External action is not installed'}]}});
  await foreign.actions['input.rules_manage']();foreign.settled();
  eq(foreign.activations.length,0);eq(foreign.library.current().profile.name,'Existing');
  const retired=fixture([{cancel:true,after(){retired.retire();}}]);
  await assert.rejects(()=>retired.actions['input.rules_manage'](),/owner changed/i);++checks;
  eq(retired.updates.length,0,'A stale form cannot save a profile');
  const resumeAnswers=[{action:'add'},{command:'editor.move_words'},{input:'Resumed word'},{input:'rule.resume'},
    {key:'F7'},{mode:'editor'}];
  const resumeRule=fixture(resumeAnswers);
  resumeAnswers.push({cancel:true,after(){++resumeRule.host.uiEpoch;}});
  await assert.rejects(()=>resumeRule.actions['input.rules_manage'](),error=>error.code==='RE35_UI_RETIRED');++checks;
  eq(resumeRule.host.inputRuleDraft.name,'Resumed word','An accepted rule name survives UI retirement');
  eq(resumeRule.host.inputRuleDraft.stage,'arguments');
  eq(resumeRule.updates.length,0);
  resumeAnswers.push({input:'3',inspect(rows,native){eq(native.title,'RE35 count','A reopened rule resumes the unanswered field');}},
    {action:'save'},{action:'back'});
  await resumeRule.actions['input.rules_manage']();resumeRule.settled();
  eq(plain(resumeRule.library.current().profile.rules[0]),{id:'rule.resume',name:'Resumed word',modes:['editor'],
    tokens:[{kind:'key',key:'F7',modifiers:[]}],invoke:{command:'editor.move_words',args:{count:'3'}}});
  eq(resumeRule.activations.length,0,'Authoring restoration never activates editor keys');
  const changingCatalog=[{id:'editor.move_words',name:'Move words',arguments:[
    {name:'count',kind:'text',required:true},{name:'scope',kind:'text',required:true}]}];
  const schemaAnswers=[{action:'add'},{command:'editor.move_words'},{input:'Keep answers'},{input:'rule.schema'},
    {key:'F8'},{mode:'editor'},{input:'2'}];
  const changedSchema=fixture(schemaAnswers,{catalog:changingCatalog});
  schemaAnswers.push({cancel:true,after(){++changedSchema.host.uiEpoch;}});
  await assert.rejects(()=>changedSchema.actions['input.rules_manage'](),error=>error.code==='RE35_UI_RETIRED');++checks;
  eq(plain(changedSchema.host.inputRuleDraft.args),{count:'2'});
  changingCatalog[0].arguments.reverse();
  schemaAnswers.push({action:'discardRule',inspect(rows,native){
    eq(native.title,'RE35 Input Rules','Changed schemas return to safe authoring controls without asking a shifted field');
    eq(plain(changedSchema.host.inputRuleDraft.args),{count:'2'},'A changed schema cannot reinterpret or overwrite accepted answers');
  }},{action:'back'});
  await changedSchema.actions['input.rules_manage']();changedSchema.settled();
  eq(changedSchema.messages.some(message=>message.level==='error'&&message.text.includes('unfinished rule arguments changed')),true);
  eq(changedSchema.updates.length,0);eq(changedSchema.activations.length,0);
  const temporaryRoot=path.resolve(os.tmpdir()),folder=await fs.mkdtemp(path.join(temporaryRoot,'re35-input-ui-'));
  try{
    const file=path.join(folder,'input.json'),imported=sample('Imported');imported.rules[0].invoke.command='ext.future';
    await fs.writeFile(file,JSON.stringify(imported));
    const files=[{scheme:'file',fsPath:file}];
    const importing=fixture([{action:'import'},{action:'save'},{action:'back'}],{saved,files});
    await importing.actions['input.rules_manage']();importing.settled();
    eq(importing.library.current().profile.name,'Imported');
    eq(importing.library.current().profile.rules[0].invoke.command,'ext.future','Imported unavailable actions retain their IDs');
    eq(importing.updates.length,1);eq(importing.activations.length,0,'Reviewed import cannot install or activate input');
    eq(importing.pauses.length,1);
    const cancelImport=fixture([{action:'import'},{action:'back'},{action:'back'}],{saved,files});
    await cancelImport.actions['input.rules_manage']();cancelImport.settled();
    eq(cancelImport.updates.length,0);eq(cancelImport.library.current().profile.name,'Existing');
    const changedImport=fixture([{action:'import'},{action:'save',after:async()=>{await fs.writeFile(file,JSON.stringify(sample('Changed after review')));}},{action:'back'}],{saved,files});
    await changedImport.actions['input.rules_manage']();changedImport.settled();
    eq(changedImport.updates.length,0);eq(changedImport.library.current().profile.name,'Existing');
    eq(changedImport.messages.some(message=>message.level==='error'&&message.text.includes('changed')),true);
    const output=path.join(folder,'export.json');
    const exporting=fixture([{action:'export'},{action:'back'}],{saved,files,file:{scheme:'file',fsPath:output}});
    await exporting.actions['input.rules_manage']();exporting.settled();
    eq(JSON.parse(await fs.readFile(output,'utf8')).name,'Existing');eq(exporting.activations.length,0);
  }finally{
    assert.equal(path.dirname(folder),temporaryRoot);assert(path.basename(folder).startsWith('re35-input-ui-'));
    await fs.rm(folder,{recursive:true,force:true});
  }
  return{checks,scope:'Controlled native authoring forms with real InputLibrary; no physical acquisition claim'};
}
if(require.main===module)run().then(result=>console.log(JSON.stringify(result)),error=>{console.error(error);process.exitCode=1;});
module.exports={run};
