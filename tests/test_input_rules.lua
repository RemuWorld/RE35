-- Portable validation/availability is independent of editor or storage APIs.
local root = assert(vim.env.CE_TEST_ROOT)
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable modules allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local R = require('command_environment.core.input_rules')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local Editing = require('command_environment.core.editing')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function key(name, modifiers) return {kind='key',key=name,modifiers=modifiers or U.array()} end
local function text(value) return {kind='text',text=value} end
local function profile()
  return {version=1,id='user.input',name='My input',input_profile='neovim',
    owned_roots={normal={key('F6')},visual_character={key('F6')}},
    rules={ {id='user.move',name='Move',modes={'normal'},tokens={key('F6')},
      invoke={command='edit.move_words',args={count='1'}}},
      {id='user.upper',modes={'visual_character'},tokens={key('F6')},invoke={command='edit.uppercase_selection'}} }}
end
local manifest = {
  {id='edit.move_words',name='Move',arguments={{name='count',kind='text',required=true}}},
  {id='edit.uppercase_selection',name='Upper',arguments=U.array()},
}
local capabilities = {available=true,atomic_function_keys=true,modes={'normal','visual_character','visual_line'},text=false,prefix=false,counts=false}
local function refuses(value, reason)
  local prepared, why = R.validate(value)
  check(prepared == nil and type(why) == 'string' and (not reason or why:find(reason,1,true)), why or 'Expected refusal')
end
local function bad(change, reason) local value=profile(); change(value); refuses(value,reason) end
local prepared = assert(R.validate(profile()))
check(prepared.controls.cancel.key == 'Escape' and prepared.controls.backspace.key == 'Backspace', 'Default controls are explicit')
check(U.kind(prepared.rules[2].invoke.args) == 'object', 'Absent invocation arguments normalize to a JSON object')
local original = profile(); local normalized=assert(R.validate(original)); original.rules[1].invoke.args.count='99'
check(normalized.rules[1].invoke.args.count == '1', 'Normalized nested data does not share caller ownership')
local inspected = assert(R.inspect(prepared, manifest, capabilities))
check(inspected.available and #inspected.activation == 2, 'Measured atomic function-key scope has a plan')
check(inspected.activation[1].modes[1] == 'n' and inspected.activation[2].modes[1] == 'v', 'Activation projects canonical native modes')
check(inspected.rules[1].available and inspected.rules[1].reason == nil, 'Available status has no fallback failure reason')
local function diagnostic(report, code, rule)
  for _, entry in ipairs(report.diagnostics) do if entry.code == code and entry.rule == rule then return entry end end
end
local wrong_upper=profile(); wrong_upper.rules={wrong_upper.rules[2]}
wrong_upper.rules[1].modes={'normal'}; wrong_upper.owned_roots={normal={key('F6')}}
check(assert(R.validate(wrong_upper)).rules[1].modes[1] == 'normal', 'A mismatched built-in mode remains retained inert data')
local upper_report=assert(R.inspect(wrong_upper,Editing.descriptors(),capabilities))
check(not upper_report.available and #upper_report.activation == 0, 'Uppercase in Normal mode cannot acquire keys')
check(diagnostic(upper_report,'mode_unavailable',wrong_upper.rules[1].id) ~= nil, 'The finite operation explains its unsupported rule mode')
local wrong_delete=profile(); wrong_delete.rules={wrong_delete.rules[1]}
wrong_delete.rules[1].modes={'visual_line'}; wrong_delete.rules[1].invoke.command='edit.delete_lines'
wrong_delete.owned_roots={visual_line={key('F6')}}
check(assert(R.validate(wrong_delete)).rules[1].invoke.command == 'edit.delete_lines', 'An unavailable deletion rule is not removed or rewritten')
local delete_report=assert(R.inspect(wrong_delete,Editing.descriptors(),capabilities))
check(not delete_report.available and #delete_report.activation == 0
  and diagnostic(delete_report,'mode_unavailable',wrong_delete.rules[1].id) ~= nil, 'Visual deletion is refused before native admission')
local selection=profile(); selection.rules[1].invoke={command='edit.select_word'}
local selection_report=assert(R.inspect(selection,Editing.descriptors(),capabilities))
check(selection_report.available and #selection_report.activation == 2, 'Normal selection followed by Visual uppercase remains eligible')
check(selection_report.activation[1].modes[1] == 'n' and selection_report.activation[2].modes[1] == 'v', 'Semantic operation modes preserve the continuous transition')
local custom=profile(); custom.rules={custom.rules[1]}; custom.rules[1].invoke={command='ext.uppercase_selection'}
check(assert(R.inspect(custom,{{id='ext.uppercase_selection',name='Custom action'}},capabilities)).available,
  'Unknown custom action IDs do not inherit finite built-in mode restrictions')
local unknown=profile(); unknown.rules[1].invoke.command='ext.not_installed'
check(assert(R.validate(unknown)).rules[1].invoke.command == 'ext.not_installed', 'Unknown action IDs remain savable definitions')
local unavailable=assert(R.inspect(unknown,manifest,capabilities))
check(not unavailable.available and #unavailable.activation == 0 and not unavailable.rules[1].available, 'Missing registration blocks the whole activation transaction')
check(unavailable.rules[1].reason:find('not registered',1,true), 'Missing registration is explained')
local missing=U.clone(capabilities); missing.available=false; missing.reason='Neovim is not installed'
local disconnected=assert(R.inspect(profile(),manifest,missing))
check(not disconnected.available and not disconnected.rules[1].available and disconnected.rules[1].reason == missing.reason,
  'Unavailable engine cannot produce an apparently available rule')
local prefix=profile(); prefix.owned_roots.normal={text('a')}; prefix.rules={prefix.rules[1]}; prefix.rules[1].tokens={text('a'),text('b')}
check(assert(R.validate(prefix)).rules[1].tokens[2].text == 'b', 'Multi-token definitions are retained without physical activation')
local unsupported=assert(R.inspect(prefix,manifest,capabilities))
check(not unsupported.available and #unsupported.activation == 0, 'Unsupported physical prefix cannot silently degrade to an atomic key')
local advertised=U.clone(capabilities); advertised.text=true; advertised.prefix=true
check(not assert(R.inspect(prefix,manifest,advertised)).available, 'Advertising unsupported capture cannot turn it into implemented support')
local editor=profile(); editor.input_profile='vscode'; editor.rules={editor.rules[1]}; editor.rules[1].modes={'editor'}; editor.owned_roots={editor={key('F6')}}
check(assert(R.validate(editor)).input_profile == 'vscode' and not assert(R.inspect(editor,manifest,capabilities)).available,
  'The VS Code input preference is retained without claiming a native editing profile')
local unknown_argument=profile(); unknown_argument.rules[1].invoke.args.extra='x'
check(assert(R.validate(unknown_argument)) ~= nil and not assert(R.inspect(unknown_argument,manifest,capabilities)).available,
  'Host argument drift blocks activation without destroying definitions')
local required=profile(); required.rules[1].invoke.args={}
check(not assert(R.inspect(required,manifest,capabilities)).available, 'A required interactive input cannot auto-activate')
local wrong=profile(); wrong.rules[1].invoke.args.count=false
check(not assert(R.inspect(wrong,manifest,capabilities)).available, 'Argument types are checked against the live manifest')
local modified=profile(); modified.rules={modified.rules[1]}; modified.rules[1].tokens={key('F6',{'shift','ctrl'})}; modified.owned_roots.normal=modified.rules[1].tokens
local canonical=assert(R.validate(modified))
check(canonical.rules[1].tokens[1].modifiers[1] == 'ctrl', 'Modifier order normalizes deterministically')
check(not assert(R.inspect(modified,manifest,capabilities)).available, 'Unverified modified keys are not activated')
local unicode=profile(); unicode.rules={unicode.rules[1]}; unicode.rules[1].tokens={text('😀')}; unicode.owned_roots.normal=unicode.rules[1].tokens
check(assert(R.validate(unicode)).rules[1].tokens[1].text == '😀', 'One non-BMP scalar is a valid retained token')
unicode.rules[1].tokens[1].text='ab'; refuses(unicode,'exactly one')
local counted=profile(); counted.rules={counted.rules[1]}; counted.owned_roots.normal={key('F6')}
for index=1,9 do counted.owned_roots.normal[#counted.owned_roots.normal+1]=text(tostring(index)) end
counted.counts={modes={'normal'}}; counted.rules[1].invoke.args={}; counted.rules[1].count_binding={argument='count',encoding='decimal_text',default=1}
check(assert(R.validate(counted)).rules[1].count_binding.default == 1, 'Explicit count data keeps its integer default')
check(not assert(R.inspect(counted,manifest,capabilities)).available, 'Count definitions are retained but capture is unavailable')
local lost_root=U.clone(counted); table.remove(lost_root.owned_roots.normal); refuses(lost_root,'numeric root ownership')
local count_collision=U.clone(counted); count_collision.rules[1].invoke.args.count='1'; refuses(count_collision,'literal argument')
bad(function(p) p.version=2 end,'version')
bad(function(p) p.execute='return true' end,'Unknown')
bad(function(p) p.input_profile='native' end,'preference')
bad(function(p) p.controls=false end,'object')
bad(function(p) p.controls={cancel=false} end,'object')
bad(function(p) p.owned_roots=false end,'object')
bad(function(p) p.rules=U.object() end,'array')
bad(function(p) p.rules[1].tokens[1].modifiers={'ctrl','ctrl'} end,'Duplicate')
bad(function(p) p.rules[1].tokens[1].key='F25' end,'Unknown named')
bad(function(p) p.rules[1].tokens[1].kind='code' end,'Unknown named')
bad(function(p) p.rules[1].tokens[1].text='x' end,'Unknown named')
bad(function(p) p.rules[1].invoke.command='ex.delete' end,'runtime command')
bad(function(p) p.rules[1].invoke.callback=true end,'Unknown')
bad(function(p) p.rules[1].modes={'normal','normal'} end,'duplicate')
bad(function(p) p.rules[1].modes={'operator_pending'} end,'Unknown')
bad(function(p) p.rules[1].tokens={} end,'1 to 16')
bad(function(p) p.rules[1].tokens[1]=key('Escape') end,'control')
bad(function(p) p.controls={cancel=key('Backspace')} end,'collide')
bad(function(p) p.owned_roots.normal={} end,'ownership')
bad(function(p) p.rules[2].id=p.rules[1].id end,'Duplicate')
bad(function(p) p.rules[2].modes={'normal'} end,'prefix collision')
bad(function(p) p.owned_roots.editor={key('F6')}; p.rules[2].modes={'editor'} end,'prefix collision')
bad(function(p) p.rules[1].tokens[1].modifiers=function() end end,'JSON data')
bad(function(p) p.name='line\nwrap' end,'UTF-8')
bad(function(p) p.name=string.rep('x',129) end,'UTF-8')
bad(function(p) p.rules[1].invoke.args.count=math.huge end,'JSON contract')
bad(function(p) p.rules[1].invoke.args.self=p end,'cycles')
bad(function(p) p.rules[1].tokens={[2]=key('F6')} end,'strings')
local touched=0; local hostile=setmetatable({}, {__index=function() touched=touched+1 end})
refuses(hostile,'host objects'); check(touched == 0, 'Foreign metatables are refused without executing lookup callbacks')
local deep=profile(); local child=deep.rules[1].invoke.args
for _=1,20 do child.next={}; child=child.next end
refuses(deep,'depth')
local too_many=profile(); too_many.rules={}
for index=1,257 do too_many.rules[index]={id='rule'..index,modes={'normal'},tokens={key('F6')},invoke={command='edit.uppercase_selection'}} end
refuses(too_many,'256')
local ok,why=R.inspect(profile(),manifest,{atomic_function_keys=true,modes={'normal'},unexpected=true})
check(ok == nil and why:find('Unknown input capabilities',1,true), 'Unknown capability claims are rejected')
ok,why=R.inspect(profile(),manifest,{atomic_function_keys=true,modes=false})
check(ok == nil and why:find('array',1,true), 'False cannot masquerade as a missing mode capability')
local byte=profile(); byte.rules={byte.rules[1]}; byte.rules[1].invoke.args={data=''}
local overhead=#J.encode(assert(R.validate(byte))); byte.rules[1].invoke.args.data=string.rep('x',R.max_bytes-overhead)
check(#J.encode(assert(R.validate(byte))) == R.max_bytes, 'A normalized definition of exactly 64 KiB fits the contract')
byte.rules[1].invoke.args.data=byte.rules[1].invoke.args.data .. 'x'; refuses(byte,'64 KiB')
-- Exercise the actual JSON bridge as well; it has no key-install operation.
local module='command_environment.core.input_rules'; package.loaded[module]=nil
require('command_environment.core.bridge'); ce_bridge_init('input-rule-data')
local function bridge(op, request)
  return assert(J.decode(ce_bridge(op,J.encode(request or U.object()))))
end
local before=J.encode(bridge('snapshot').value)
check(package.loaded[module] == nil, 'Initializing an ordinary host leaves input rules unloaded')
local wired=bridge('input_rules_validate',{profile=profile()})
check(wired.ok and wired.value.controls.cancel.key == 'Escape', 'Wire validation returns normalized inert definitions')
local wired_inspection=bridge('input_rules_inspect',{profile=profile(),definitions=manifest,capabilities=capabilities})
check(wired_inspection.ok and wired_inspection.value.available and #wired_inspection.value.activation == 2,
  'Wire inspection consumes the supplied registry and capability manifest')
local denied=bridge('input_rules_inspect',{profile=profile(),definitions=manifest,
  capabilities={available=false,reason='Engine missing',modes=U.array()}})
check(denied.ok and not denied.value.available and #denied.value.activation == 0, 'Missing engine is data diagnostics, not a lost definition')
check(not bridge('input_rules_validate',{profile=profile(),activate=true}).ok, 'Wire validation rejects activation authority fields')
check(not bridge('input_rules_inspect',{profile=profile(),definitions=manifest,install=true}).ok,
  'Wire inspection cannot install anything through extra fields')
check(before == J.encode(bridge('snapshot').value), 'Validation and inspection do not mutate engine operations or navigation')
print('Input rule checks: ' .. checks)
