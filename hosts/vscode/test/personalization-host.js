'use strict';
// Actual Extension Host and public vscode-neovim transport. API invocation is
// deliberate: this fixture is not evidence for OS keystrokes, layout or IME.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const { emptyProfile } = require('../input-library');
const { expectedSelection } = require('../editing-bridge');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve,milliseconds));
const point = value => [value.line,value.character];
const plain = value => JSON.parse(JSON.stringify(value));
async function run({api,options,root}) {
  let checks=0,host,library,inputLibrary,savedLibrary,savedInput,savedPick,savedText,lease,serial=0;
  const documents=[],observations=[],outcomes=[];
  const eq=(actual,expected,label)=>{assert.deepEqual(actual,expected,label);++checks;};
  const timed=async(promise,label)=>{
    let timer;
    try{return await Promise.race([promise,new Promise((resolve,reject)=>{
      timer=setTimeout(()=>reject(new Error('Personalization host check did not settle: '+label)),30000);
    })]);}finally{clearTimeout(timer);}
  };
  const config=vscode.workspace.getConfiguration('re35'),names=['helperPath','luaRuntime','corePath'];
  const previous=new Map(names.map(name=>[name,config.inspect(name).globalValue]));
  const originalEditor=vscode.window.activeTextEditor;
  let bridge;
  const textOf=document=>document.getText().replace(/\r\n/g,'\n');
  async function prepare(content,label) {
    await api.pauseInput(host,'Preparing owned personalization fixture');
    await vscode.commands.executeCommand('vscode-neovim.send','<Esc>');
    const filename=path.join(root,'personalization-'+(++serial)+'-'+label+'.txt');
    await fs.writeFile(filename,content,{encoding:'utf8',flag:'wx'});
    const document=await vscode.workspace.openTextDocument(vscode.Uri.file(filename));documents.push(document);
    const editor=await vscode.window.showTextDocument(document,{preview:false});
    await bridge.synchronized(editor);
    await vscode.commands.executeCommand('vscode-neovim.lua',
      'vim.o.selection="inclusive";vim.o.startofline=false;vim.bo.iskeyword="@,48-57,_,192-255";vim.api.nvim_win_set_cursor(0,{1,0})');
    const captured=await bridge.synchronized(editor);
    eq(captured.snapshot.mode,'n',label+' starts in observed Normal mode');
    eq(captured.snapshot.cursor,{row1:1,byte0:0},label+' starts at the original cursor');
    eq(textOf(document),content,label+' original VS Code source');
    return{document,editor};
  }
  async function expectTextAndSelection(editor,content,label) {
    const captured=await bridge.synchronized(editor),selection=expectedSelection(captured.snapshot);
    eq(textOf(editor.document),content,label+' actual VS Code text');
    eq(captured.snapshot.lines.join('\n'),content,label+' actual Neovim text');
    eq(point(editor.selection.anchor),selection.anchor,label+' synchronized anchor');
    eq(point(editor.selection.active),selection.active,label+' synchronized cursor');
    return captured;
  }
  try {
    for(const name of names)await config.update(name,options[name],vscode.ConfigurationTarget.Global);
    const extension=vscode.extensions.getExtension('asvetliakov.vscode-neovim');
    assert(extension,'The isolated personalization run requires vscode-neovim');await extension.activate();
    host=api.getHost();await host.core();bridge=host.editingService();await bridge.connect();
    const presentation=host.presentationService();savedPick=presentation.pick;savedText=presentation.input;
    presentation.pick=async()=>undefined;
    presentation.input=async()=>{throw new Error('Personalization host fixture supplies every argument explicitly');};
    library=await api.getLibrary(host);savedLibrary=library.current().library;
    inputLibrary=await api.getInputLibrary(host);savedInput=inputLibrary.current().profile;
    const evidence=new WeakMap(),id='local.user.trim_line_end';
    lease=await api.registerAction({id,name:'Trim current line end',description:'Remove trailing spaces from the current line',
      type:'action',provider:'personalization-host-fixture',arguments:[]},{
      completion:'observed',source:'refresh',composable:true,
      async execute(args,ctx) {
        ctx.check();
        eq(Object.hasOwn(ctx,'host'),false,'A trusted action receives no internal Host');
        eq(Object.hasOwn(ctx,'editor'),false,'A trusted action receives no internal editor receipt');
        eq(Object.hasOwn(ctx,'frame'),false,'A trusted action receives no mutable composition frame');
        eq(Object.isFrozen(ctx.source),true,'Source identity is immutable data');
        const editor=vscode.window.activeTextEditor,document=editor.document;
        eq(ctx.source.uri,document.uri.toString(),'User action owns the originally selected document');
        eq(ctx.source.version,document.version,'The next user action receives the current source revision');
        const beforeVersion=document.version,row=editor.selection.active.line,line=document.lineAt(row).text;
        const match=/[ \t]+$/.exec(line);
        if(match)await api.applyEditorEdits([{range:{start:{line:row,character:match.index},end:{line:row,character:line.length}},text:''}],ctx);
        ctx.check();
        const expected={uri:document.uri.toString(),version:document.version,text:document.getText(),mode:'n',
          anchor:point(editor.selection.anchor),active:point(editor.selection.active)};
        evidence.set(ctx,expected);
        observations.push({initialVersion:beforeVersion,version:expected.version,changed:!!match,text:expected.text,
          anchor:expected.anchor,active:expected.active});
        return{status:'succeeded',changed:document.version!==beforeVersion,sourceVersion:document.version};
      },
      async observe(args,ctx){ctx.check();return evidence.get(ctx);}
    },{owner:'re35.personalization-host-fixture'});
    eq(lease.id,id,'A trusted extension registers its stable ID without changing core command lists');
    eq((await(await host.core()).call('get',{id})).id,id,'The actual core discovers the live registered action');
    const nativeAvailability=bridge.availability;
    let discovered;
    try {
      bridge.availability=()=>({available:false,reason:'Owned fixture: native observer unavailable'});
      presentation.pick=async(scene,items)=>{if(scene==='tree')discovered=items.find(item=>item.id===id);return undefined;};
      await vscode.commands.executeCommand('re35.open');
      eq(discovered?.detail.includes('Owned fixture: native observer unavailable'),true,
        'Discovery explains the actual native observer requirement for a registered source action');
    } finally {bridge.availability=nativeAvailability;presentation.pick=async()=>undefined;}
    let source=await prepare('one 한글😀 two   \nlast line','trim');
    const originalVersion=source.document.version;
    let result=await timed(api.execute({command:id,args:{}}),'registered Unicode trim');
    eq(result.status,'succeeded');eq(result.changed,true);
    eq(source.document.version>originalVersion,true,'The real edit advances the document revision');
    await expectTextAndSelection(source.editor,'one 한글😀 two\nlast line','Registered Unicode trim');
    const noOpVersion=source.document.version;
    result=await timed(api.execute({command:id,args:{}}),'registered trim no-op');
    eq(result.status,'succeeded');eq(result.changed,false);
    eq(source.document.version,noOpVersion,'No-op trimming preserves the actual revision');
    await expectTextAndSelection(source.editor,'one 한글😀 two\nlast line','Registered no-op');
    source=await prepare('one 한글😀 two   \nlast line','composition');
    await library.save({version:1,commands:[{id:'user.trim_then_move',name:'Trim line then move',inputs:[],steps:[
      {command:id,args:{}},{command:'edit.move_words',args:{count:{value:'1'}}}
    ]}]},library.current().revision);
    const beforeComposition=source.document.version;
    result=await timed(api.execute({command:'user.trim_then_move'}),'registered edit and native move composition');
    eq(result.status,'succeeded','A registered source-refresh action participates in the existing composition runner');
    eq(result.steps.map(step=>step.status),['succeeded','succeeded']);
    eq(source.document.version>beforeComposition,true);
    let captured=await expectTextAndSelection(source.editor,'one 한글😀 two\nlast line','Composition source refresh');
    eq(captured.snapshot.mode,'n');eq(captured.snapshot.cursor,{row1:1,byte0:4},'The following native step uses the refreshed source');
    outcomes.push({name:'registered_trim_then_move',status:result.status,steps:result.steps.map(step=>step.status)});
    source=await prepare('one two three\n한글😀 last','continuous');
    const profile=plain(emptyProfile('neovim'));profile.id='user.host_fixture';profile.name='Host fixture input';
    const token=key=>({kind:'key',key,modifiers:[]});
    profile.owned_roots={normal:[token('F9'),token('F10')],visual_character:[token('F6')]};
    profile.rules=[
      {id:'rule.select',name:'Select word',modes:['normal'],tokens:[token('F9')],invoke:{command:'edit.select_word',args:{}}},
      {id:'rule.upper',name:'Uppercase selection',modes:['visual_character'],tokens:[token('F6')],invoke:{command:'edit.uppercase_selection',args:{}}},
      {id:'rule.move',name:'Move word',modes:['normal'],tokens:[token('F10')],invoke:{command:'edit.move_words',args:{count:'1'}}}
    ];
    await inputLibrary.save(profile,inputLibrary.current().revision);
    eq(api.getInputState(host).ready || false,false,'Saving a profile does not activate editor keys');
    const report=await api.inspectInput(host,inputLibrary.current().profile);
    eq(report.available,true,'The actual registry and native availability permit the measured F-key scope');
    await timed(api.activateInput(host,inputLibrary.current().profile),'explicit atomic profile activation');
    eq(api.getInputState(host).ready,true,'Explicit activation owns the original editor');
    const unavailableEditor=plain(emptyProfile('vscode'));
    eq((await api.inspectInput(host,unavailableEditor)).available,false,'An active modal extension does not pretend to be ordinary editor input');
    await assert.rejects(api.activateInput(host,unavailableEditor));++checks;
    eq(api.getInputState(host).profile,profile.id,'Refused engine change preserves the native profile');
    eq(api.getInputState(host).ready,true);
    eq(api.getNativeInputTrace().ready,true,'The packaged native observer connects independently of function-key execution');
    const traceBefore=textOf(source.document);
    let traceSegment;
    for (const [keys,expected] of [['gg','gg'],['V','ggV'],['G','ggVG']]) {
      if (traceSegment) await delay(6100);
      await vscode.commands.executeCommand('vscode-neovim.send',keys);
      const traceDeadline=Date.now()+5000;
      while(api.getNativeInputTrace().text!==expected&&Date.now()<traceDeadline)await delay(10);
      const trace=api.getNativeInputTrace();
      eq(trace.text,expected,'Public native input accumulates without waiting for Enter');
      eq(trace.tokens.every(item=>item.observed===true&&!Object.hasOwn(item,'completed')),true,'Observed native keys are not declared completed commands');
      if (!traceSegment) traceSegment=trace.activeSegmentId;
      eq(trace.activeSegmentId,traceSegment,'Idle time beyond five seconds preserves the observation segment');
    }
    captured=await bridge.synchronized(source.editor);
    eq(captured.snapshot.mode,'V','Native ggVG retains line Visual semantics');
    eq(captured.snapshot.cursor.row1,source.document.lineCount,'Native ggVG still reaches the final line');
    eq(textOf(source.document),traceBefore,'Input observation does not mutate the document');
    await api.pauseInput(host,'Inspecting retained observation');
    eq(api.getNativeInputTrace().text,'','A paused observer exposes no active input');
    eq(api.getNativeInputTrace().history.at(-1).text,'ggVG','Paused display history retains the completed observation segment');
    await vscode.commands.executeCommand('re35.clearInputHistory');
    eq(api.getNativeInputTrace().history,[],'Explicit clearing removes retained native display history');
    eq(api.getNativeInputTrace().paused,true,'Clearing does not restart intentionally paused observation');
    eq(api.getInputState(host).suspended,true,'Clearing does not resume intentionally paused editor rules');
    await vscode.commands.executeCommand('re35.input.resume');
    eq(api.getNativeInputTrace().ready,true);
    outcomes.push({name:'native_ggVG_observation_without_completion_inference',status:'observed',physical:false});
    await vscode.commands.executeCommand('vscode-neovim.send','<Esc>');
    await vscode.commands.executeCommand('vscode-neovim.lua','vim.api.nvim_win_set_cursor(0,{1,0})');
    await bridge.synchronized(source.editor);
    const wrongMode=plain(profile);wrongMode.rules[1].modes=['normal'];wrongMode.owned_roots.normal.push(token('F6'));
    const refusedMode=await api.inspectInput(host,wrongMode);
    eq(refusedMode.available,false,'A known editing action cannot activate in the wrong native mode');
    eq(refusedMode.activation.length,0);
    await assert.rejects(api.activateInput(host,wrongMode));++checks;
    eq(api.getInputState(host).ready,true,'Refused mode configuration preserves the active valid profile');
    const inputPromises=['F9','F6','F10'].map(key=>vscode.commands.executeCommand('re35.input.key',key));
    const inputResults=await timed(Promise.all(inputPromises),'API select, uppercase, move without a final Enter');
    eq(inputResults.map(item=>item.status),['succeeded','succeeded','succeeded']);
    captured=await expectTextAndSelection(source.editor,'ONE two three\n한글😀 last','Consecutive API inputs');
    eq(captured.snapshot.mode,'n');eq(captured.snapshot.cursor,{row1:1,byte0:4});
    const deadline=Date.now()+15000;
    while(api.getInputState(host).busy&&Date.now()<deadline)await delay(20);
    eq(api.getInputState(host).busy,false,'Native barriers return before a new external editing action');
    await api.pauseInput(host,'Checking native Undo after the owned sequence');
    await vscode.commands.executeCommand('vscode-neovim.send','u');
    captured=await expectTextAndSelection(source.editor,'one two three\n한글😀 last','Native Undo after user input');
    eq(captured.snapshot.mode,'n');
    outcomes.push({name:'atomic_function_key_api_sequence',status:'succeeded',physical:false});
    source=await prepare('one two\nalpha beta\nlast line','native-fallback');
    await vscode.commands.executeCommand('vscode-neovim.lua',
      'vim.keymap.set("n","<F6>","<Cmd>normal! j<CR>",{desc="RE35 owned fixture native F6"})');
    try {
      await api.activateInput(host,profile,undefined,{allowNativeOverride:true});
      const fallback=await timed(Promise.all(['F6','F10'].map(key=>vscode.commands.executeCommand('re35.input.key',key))),
        'native F6 fallback before following RE35 word movement');
      eq(fallback.map(item=>item.status),['passthrough','succeeded']);
      eq(fallback[0].observed,false,'Native fallback is not a confirmed RE35 action');
      captured=await expectTextAndSelection(source.editor,'one two\nalpha beta\nlast line','Native mapping fallback');
      eq(captured.snapshot.cursor,{row1:2,byte0:6},'The native mapping runs before the following owned action');
      eq(api.getInputState(host).blocked,false,'A mode without a rule does not block the input connection');
      outcomes.push({name:'native_mapping_fallback_before_owned_action',status:'passthrough',physical:false});
    } finally {
      await api.pauseInput(host,'Retiring owned native fallback fixture');
      await vscode.commands.executeCommand('vscode-neovim.lua',
        'if vim.fn.maparg("<F6>","n",false,true).desc=="RE35 owned fixture native F6" then vim.keymap.del("n","<F6>") end');
    }
    const unresolved=plain(emptyProfile('neovim'));unresolved.id='user.retained';unresolved.name='Unavailable user rule';
    unresolved.owned_roots={normal:[token('F11')]};
    unresolved.rules=[{id:'rule.future',modes:['normal'],tokens:[token('F11')],invoke:{command:'ext.not_installed',args:{}}}];
    await inputLibrary.save(unresolved,inputLibrary.current().revision);
    const unavailable=await api.inspectInput(host,inputLibrary.current().profile);
    eq(unavailable.available,false);eq(unavailable.activation.length,0);
    eq(inputLibrary.current().profile.rules[0].invoke.command,'ext.not_installed','A missing external action remains in durable input data');
    const removalProfile=plain(unresolved);removalProfile.rules[0].invoke.command=id;
    await inputLibrary.save(removalProfile,inputLibrary.current().revision);
    eq((await api.inspectInput(host,inputLibrary.current().profile)).available,true);
    eq(await lease.dispose(),true,'The current registration lease removes its own action');lease=null;
    await assert.rejects((await host.core()).call('get',{id}),/unknown command/i);++checks;
    const removed=await api.inspectInput(host,inputLibrary.current().profile);
    eq(removed.available,false);eq(removed.activation.length,0);
    eq(inputLibrary.current().profile.rules[0].invoke.command,id,'Unregistering preserves the stored reference with an unavailable explanation');
    return{passed:true,checks,observations,outcomes,vscode:vscode.version,vscode_neovim:extension.packageJSON.version,
      physical_gestures_measured:false,scope:'Actual registered editor edit, Unicode source observation, no-op revision, composition source refresh, API-triggered atomic input sequence and native Undo; no OS/IME claim'};
  }finally{
    if(host&&!host.disposed){
      await api.pauseInput(host,'Personalization fixture cleanup');
      if(lease)await lease.dispose();
      if(library&&savedLibrary)await library.save(savedLibrary,library.current().revision);
      if(inputLibrary&&savedInput)await inputLibrary.save(savedInput,inputLibrary.current().revision);
      const view=host.presentationService();if(savedPick)view.pick=savedPick;if(savedText)view.input=savedText;
    }
    // Only fixture documents created in this supplied test root are saved and
    // closed. The initial editor and its contents are never written here.
    for(const document of documents){
      assert.equal(path.dirname(document.uri.fsPath).toLowerCase(),path.resolve(root).toLowerCase());
      if(!document.isClosed){
        await document.save();await vscode.window.showTextDocument(document,{preview:false});
        await vscode.commands.executeCommand('workbench.action.closeActiveEditor');
      }
    }
    for(const name of names)await config.update(name,previous.get(name),vscode.ConfigurationTarget.Global);
    if(originalEditor&&!originalEditor.document.isClosed)await vscode.window.showTextDocument(originalEditor.document,{preview:false});
  }
}
module.exports={run};
