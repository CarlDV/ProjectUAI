'use strict';
const $=id=>document.getElementById(id), md=UAIMarkdown.render;
const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
const button=(text,fn,cls)=>{const n=el('button',cls,text);n.type='button';n.onclick=fn;return n;};
const uuid=()=>crypto.randomUUID();
function stored(storage,key){try{return window[storage].getItem(key);}catch{return null;}}
const fromHash=location.hash.match(/(?:#|&)t=([a-f0-9]{64})/i);
let token=fromHash?.[1]||stored('sessionStorage','uai.token')||stored('localStorage','uai.token')||'';
if(fromHash)history.replaceState(null,'',location.pathname);
let state={},page='chat',stream,busy=false,connected=false,sending=false,sessionId=null,events=[],uploads=[];
let drafts={};try{const value=JSON.parse(stored('sessionStorage','uai.drafts')||'{}');if(value&&typeof value==='object'&&!Array.isArray(value))drafts=value;}catch{}
const tools=new Map(),live=new Map(),pendingCommands=new Map();
let toastTimer,storageWarning=false,renderingSnapshot=false;
function toast(text){$('toast').textContent=text;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,4500);}
async function api(path,body,method){const res=await fetch('/api'+path,{method:method||(body===undefined?'GET':'POST'),headers:{Authorization:'Bearer '+token,...(body===undefined?{}:{'content-type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});const text=res.status===204?'':await res.text();let data={};try{data=text?JSON.parse(text):{};}catch{throw Error(res.status===401?'Bridge token was refused. Reconnect with the token from the console.':`Bridge returned ${res.status}`);}if(!res.ok)throw Error(data.error||`Bridge returned ${res.status}`);return data;}
async function command(type,fields={}){
  const commandId=uuid(), payload={type,sessionId,...fields,commandId};
  let receipt;
  for(let i=0;i<2;i++){try{receipt=await api('/command',payload);break;}catch(err){if(i)throw err;}}
  const deadline=Date.now()+190000;
  while(Date.now()<deadline){let result;try{result=await api('/commands/'+receipt.id);}catch(err){if(err.name!=='TypeError'&&err.name!=='TimeoutError')throw err;await new Promise(r=>setTimeout(r,1000));continue;}if(!['queued','running'].includes(result.state)){if(result.result?.ok===false)throw Error(result.result.error);return result.result?.data;}await new Promise(r=>setTimeout(r,250));}
  throw Error('Command is still pending. Reconnect before retrying this action.');
}
function action(type,fields){return command(type,fields).catch(err=>toast(err.message));}
function modal(title,build){$('modalTitle').textContent=title;$('modalBody').replaceChildren();$('modalBody').className='';build($('modalBody'));if(!$('modal').open)$('modal').showModal();}
$('modalClose').onclick=()=>$('modal').close();
function field(parent,label,value,type='text'){const holder=el('label',null,label),input=el(type==='textarea'?'textarea':'input');if(type!=='textarea')input.type=type;input.value=value??'';holder.append(input);parent.append(holder);return input;}
function select(parent,label,values,value){const holder=el('label',null,label),input=el('select');for(const item of values){const pair=typeof item==='string'?[item,item]:item;const option=el('option',null,pair[1]);option.value=pair[0];input.append(option);}input.value=value;holder.append(input);parent.append(holder);return input;}
function persistDrafts(){
  try{sessionStorage.setItem('uai.drafts',JSON.stringify(drafts));}
  catch{if(!storageWarning){storageWarning=true;toast('Drafts are kept in this tab. Browser storage is unavailable or full.');}}
}
function saveDraft(){
  if(!sessionId)return;
  const previous=drafts[sessionId]||{},text=$('input').value;
  drafts[sessionId]={text,uploads:uploads.slice(),version:(previous.version||0)+(previous.text===text?0:1)};
  persistDrafts();
}
function changeSession(id){
  if(!id||id===sessionId)return;
  saveDraft();sessionId=id;
  $('input').value=typeof drafts[id]?.text==='string'?drafts[id].text:'';
  uploads=Array.isArray(drafts[id]?.uploads)?drafts[id].uploads.filter(f=>f&&typeof f.name==='string'&&typeof f.text==='string').map(f=>({...f,id:f.id||uuid()})):[];
  renderAttachments();grow();
}
function grow(){const input=$('input');input.style.height='auto';input.style.height=Math.min(input.scrollHeight,144)+'px';saveDraft();setBusy(busy);}
function renderAttachments(){
  $('attachments').replaceChildren();
  uploads.forEach((file,index)=>{
    const remove=button(file.name+' ×',()=>{uploads.splice(index,1);renderAttachments();saveDraft();});
    remove.title='Remove '+file.name;remove.setAttribute('aria-label',remove.title);$('attachments').append(remove);
  });
  setBusy(busy);
}
function setBusy(value){busy=!!value;$('stop').hidden=!busy;$('send').hidden=busy;$('send').disabled=sending||!connected||(!$('input').value.trim()&&!uploads.length);$('transcript').setAttribute('aria-busy',String(busy));}
function stick(){const t=$('transcript');return t.scrollHeight-t.scrollTop-t.clientHeight<120;}
function append(node){const pinned=stick();$('transcript').querySelector('.welcome')?.remove();$('transcript').append(node);if(pinned)$('transcript').scrollTop=$('transcript').scrollHeight;}
function message(who,text,model){const node=el('article','message '+who);const byline=el('div','byline');if(who==='agent'){const icon=el('img');icon.src='icon.svg';icon.alt='';byline.append(icon);}byline.append(el('span',null,who==='user'?(state.player||'you'):'Assistant'),el('small',null,model||''));const body=el('div','body');if(who==='user')body.textContent=text;else body.innerHTML=md(text);node.append(byline,body);append(node);return {node,body};}
function welcome(){if(events.some(e=>e.kind==='user'||e.kind==='assistant:text')||[...$('transcript').children].some(node=>!node.classList.contains('welcome')))return;const node=el('section','welcome');const icon=el('img');icon.src='icon.svg';icon.alt='';node.append(icon,el('h1',null,`What will we create, ${state.player||'you'}?`),el('p',null,'Your ideas. Your game. An agent to help make it happen.'));const grid=el('div','starters');for(const [title,detail,prompt] of starters){const card=button('',()=>insert(prompt),'starter');card.append(el('strong',null,title),el('small',null,detail));grid.append(card);}node.append(grid);const activity=el('details','activity');activity.append(el('summary',null,'Your activity'));const stats=el('div','card metrics');stats.append(metric(state.threads?.length||0,'Conversations'),metric(state.usage?.total||0,'Tokens'),metric(state.usage?.requests||0,'Requests'));activity.append(stats);node.append(activity);$('transcript').replaceChildren(node);}
const starters=[['Explore this game','Find your bearings in the world.','Explore this game. Inspect the workspace and tell me what is here, how it is organised, and what we could do next.'],['Create something','Turn an idea into a working script.','Help me build a Luau script for this game. First inspect the relevant game context, then ask what I would like to create.'],['Check performance','Understand FPS, memory, and latency.','Check client performance, memory usage, and network latency. Explain the results and suggest practical improvements.'],['Inspect my character',"See your character’s current state.",'Inspect my character and explain its position, humanoid state, and any useful attributes or attached scripts.']];
function insert(text){show('chat');$('input').value+=($('input').value?'\n\n':'')+text;grow();$('input').focus();}
function metric(value,label){const n=el('div');n.append(el('strong',null,typeof value==='number'?value.toLocaleString():value),el('small',null,label));return n;}
function thinking(text){const node=el('details','thinking');node.append(el('summary',null,'✳ Thinking'));const body=el('div','body');body.innerHTML=md(text);node.append(body);append(node);return body;}
function toolKey(e){return (e.kind?.startsWith('subagent:')?'child:'+e.id+':':'main:')+(e.callId||e.id||'')+':'+(e.name||'');}
function codeListing(text,label){
  const listing=el('div','code-block tool-listing'),head=el('div','code-head');
  const copy=button('Copy',()=>navigator.clipboard.writeText(text).then(()=>toast('Copied')).catch(()=>toast('Clipboard unavailable')));
  copy.setAttribute('aria-label','Copy '+label);head.append(el('span',null,label),copy);
  const pre=el('pre'),code=el('code',null,text);pre.tabIndex=0;pre.setAttribute('aria-label',label);pre.append(code);listing.append(head,pre);return listing;
}
function openTool(e){
  const wrapper=el('section','tool-call'),node=el('details','tool'),head=el('summary');
  const raw=typeof e.arguments==='string'?e.arguments:JSON.stringify(e.arguments||{});
  let args;try{args=JSON.parse(raw);}catch{}
  const preview=el('span','arguments',args?.path||args?.query||args?.url||raw);
  const verdict=el('small','tool-status','Running');verdict.setAttribute('role','status');
  head.append(el('strong',null,e.name||'Tool'),preview,verdict);node.append(head);
  const body=el('div','tool-body');body.append(codeListing(raw,'Arguments'));node.append(body);wrapper.append(node);
  if(state.settings?.ui?.showToolCode!==false){
    for(const [key,label]of [['code','Luau'],['source','Source'],['content','File contents'],['old_text','Before'],['new_text','After']]){
      if(typeof args?.[key]==='string')wrapper.append(codeListing(args[key],label));
    }
  }
  append(wrapper);tools.set(toolKey(e),{node,body,preview,verdict,restored:renderingSnapshot});
}
function finishTool(e){
  const key=toolKey(e),row=tools.get(key);
  if(!row)return;
  const stopped=e.error==='aborted'||e.data?.status==='aborted',timeout=e.error==='timeout'||e.data?.status==='timeout';
  const failed=e.kind==='tool:error'||e.ok===false;
  row.staleNote?.remove();
  row.node.dataset.status=stopped?'stopped':failed?'failed':'done';
  row.verdict.textContent=stopped?'Stopped':timeout?'Timed out':e.denied?'Declined':failed?'Failed':'Done';
  if(Number.isFinite(e.ms))row.verdict.textContent+=' · '+(e.ms<1000?Math.round(e.ms)+' ms':(e.ms/1000).toFixed(1)+' s');
  row.body.append(codeListing(e.text||e.summary||'(No output)',failed?'Execution details':'Result'));
  if(failed)row.node.open=true;
  tools.delete(key);
}
function renderEvent(e){
  if(e.sessionId&&sessionId&&e.sessionId!==sessionId)return;
  const pinned=stick();
  switch(e.kind){
    case 'user':message('user',e.text||'');break;
    case 'assistant:text':{const candidate=live.get(e.requestId);if(candidate?.body){candidate.body.innerHTML=md(e.text||'');candidate.node.classList.remove('streaming');candidate.committed=true;}else message('agent',e.text||'',e.model||state.agent?.model);if(e.requestId)live.set(e.requestId,{...candidate,sessionId,committed:true});break;}
    case 'assistant:reasoning':{const candidate=live.get(e.requestId);if(candidate?.reasonBody){candidate.reasonBody.innerHTML=md(e.text);candidate.reasonCommitted=true;}else if(e.text)thinking(e.text);if(e.requestId)live.set(e.requestId,{...candidate,sessionId,reasonCommitted:true});break;}
    case 'tool:call':case 'subagent:tool':openTool(e);break;
    case 'tool:result':case 'tool:error':case 'subagent:tool:done':finishTool(e);break;
    case 'tool:progress':{const row=tools.get(toolKey(e))||(!e.id&&tools.size===1?[...tools.values()][0]:null);if(row)row.preview.textContent=e.text||'';break;}
    case 'error':append(el('div','error',e.message||'Unknown error'));break;
    case 'status':$('status').textContent=e.text||'Ready';break;
    case 'turn:start':setBusy(true);break;case 'turn:end':case 'abort':setBusy(false);break;
    case 'cleared':events=[];live.clear();tools.clear();$('transcript').replaceChildren();welcome();break;
    case 'provider:switch':append(el('div','note','Switched provider to '+e.to));break;
    case 'request:retry':append(el('div','note',`Retrying ${e.provider||'provider'} · ${e.reason||''}`));break;
    case 'subagent:start':append(el('div','note','Subagent · '+(e.task||e.label||'')));break;
    case 'subagent:done':append(el('div','note','Subagent finished · '+(e.label||'')));break;
    case 'compact':append(el('div','note','Older context compacted'));break;
  }
  if(pinned)$('transcript').scrollTop=$('transcript').scrollHeight;
  $('latest').hidden=stick();
}
function delta(e){if(e.sessionId!==sessionId)return;let entry=live.get(e.id);if(!entry){entry={sessionId:e.sessionId,text:'',reasoning:''};live.set(e.id,entry);}const frame=e.frame||{},d=frame.choices?.[0]?.delta||{};let text=d.content||'',reason=d.reasoning_content||d.reasoning||'';if(frame.type==='content_block_delta'){text=frame.delta?.text||'';reason=frame.delta?.thinking||'';}if(reason&&!entry.reasonCommitted){entry.reasoning=(entry.reasoning||'')+reason;if(!entry.reasonBody)entry.reasonBody=thinking('');entry.reasonBody.innerHTML=md(entry.reasoning);}if(text&&!entry.committed){entry.text=(entry.text||'')+text;if(!entry.body){Object.assign(entry,message('agent','',frame.model||state.agent?.model));entry.node.classList.add('streaming');}const pinned=stick();entry.body.innerHTML=md(entry.text);if(pinned)$('transcript').scrollTop=$('transcript').scrollHeight;}}
function apply(e){
  if(typeof e.kind!=='string')return;
  if(e.kind==='bridge:reset'){events=[];live.clear();tools.clear();$('transcript').replaceChildren();welcome();return;}
  if(e.kind==='bridge:snapshot'){
    events=e.events||[];live.clear();tools.clear();$('transcript').replaceChildren();changeSession(e.sessionId);
    renderingSnapshot=true;
    try{for(const event of events)renderEvent(event);}finally{renderingSnapshot=false;}
    welcome();return;
  }
  if(e.kind==='bridge:state'){
    const next=e.state||{};changeSession(next.sessionId);state=next;renderState();
    if(!state.agent?.busy)for(const row of tools.values())if(row.restored){
      row.restored=false;row.verdict.textContent='No saved result';
      row.staleNote=el('p','muted','No result was kept in this transcript.');row.body.append(row.staleNote);
    }
    return;
  }
  if(e.kind==='bridge:game'){connected=e.connected;$('status').textContent=connected?(state.agent?.status||'Ready'):'Roblox disconnected';setBusy(state.agent?.busy);return;}
  if(e.kind==='inference:delta'){delta(e);return;}
  if(e.kind==='inference:done'){
    if(e.state!=='completed'){const item=live.get(e.id);if(item?.node){item.node.classList.remove('streaming');item.node.append(el('small','danger',e.error||'Request stopped'));item.committed=true;}}
    return;
  }
  if(e.kind.startsWith('bridge:')||e.kind==='inference:start')return;
  if(e.sessionId&&sessionId&&e.sessionId!==sessionId)return;
  events.push(e);renderEvent(e);
}
function renderState(){const colors=state.theme||{};for(const [name,value]of Object.entries(colors)){if(/^#[a-f0-9]{6}$/i.test(value))document.documentElement.style.setProperty('--'+name,value);}const ui=state.settings?.ui||{};document.documentElement.style.setProperty('--reading',({narrow:'640px',medium:'780px',wide:'1000px'})[ui.transcriptWidth]||'920px');document.body.style.fontSize=(14*Math.max(.85,Math.min(1.4,ui.fontScale||1)))+'px';document.body.dataset.motion=ui.reduceMotion==='on'?'off':'auto';$('playerName').textContent=state.player||'you';$('providerName').textContent=state.agent?.provider||'No provider connected';$('modelLabel').textContent=state.agent?.model||'Select model';$('runtimeBadge').textContent=state.runtime==='web'?'Web · streaming':'Game runtime';$('status').textContent=connected?(state.agent?.status||'Ready'):'Roblox disconnected';setBusy(state.agent?.busy);renderThreads();renderQuestions();renderStrips();if(page!=='chat'&&!$('panel').contains(document.activeElement))renderPanel();}
function renderThreads(){const search=$('threadSearch').value.toLowerCase(),root=$('threads');root.replaceChildren();const groups=new Map();for(const t of state.threads||[]){if(search&&!t.title.toLowerCase().includes(search))continue;const group=t.place||'Current game';if(!groups.has(group))groups.set(group,[]);groups.get(group).push(t);}for(const [name,list]of groups){root.append(el('div','place-heading',name));for(const thread of list){const row=el('div','thread'+(thread.active?' active':''));row.append(button((thread.busy?'◌ ':'')+(thread.title||'New chat'),()=>action('thread',{id:thread.id})),button('···',()=>threadMenu(thread),'thread-menu'));root.append(row);}}}
function threadMenu(thread){modal(thread.title||'Conversation',root=>{const name=field(root,'Title',thread.title);root.append(button('Rename',async()=>{await action('thread:rename',{id:thread.id,title:name.value});$('modal').close();}),button(thread.ephemeral?'Save conversation':'Make isolated',()=>action('thread:isolate',{sessionId:thread.id,value:!thread.ephemeral})),button('Delete',async()=>{if(confirm('Delete this conversation?')){await action('thread:delete',{id:thread.id});$('modal').close();}},'danger'));});}
function renderStrips(){const todos=state.todos||[];$('taskStrip').hidden=!todos.length;$('taskStrip').replaceChildren();if(todos.length){const d=el('details');d.append(el('summary',null,`${todos.filter(t=>t.status==='done').length}/${todos.length} tasks completed`));for(const t of todos)d.append(el('div',null,`${t.status==='done'?'✓':'○'} ${t.text}`));$('taskStrip').append(d);}const loops=(state.loops||[]).filter(l=>l.state==='running');$('loopStrip').hidden=!loops.length;$('loopStrip').replaceChildren();if(loops.length)$('loopStrip').append(button(`${loops.length} chat loop(s) running`,()=>show('loops')),button('Stop all',()=>action('loops:stop',{id:'all'}),'danger'));}
function renderQuestions(){const root=$('questions'), signature=JSON.stringify([state.pendingPermissions,state.questions]);if(root.dataset.signature===signature)return;root.dataset.signature=signature;root.replaceChildren();for(const req of state.pendingPermissions||[]){const card=el('section','question');card.append(el('strong',null,'Allow '+req.name+'?'),el('pre',null,JSON.stringify(req.args||{},null,2)));const remember=el('input');remember.type='checkbox';const label=el('label',null,'Remember this decision');label.prepend(remember);const row=el('div','row');for(const allowed of [true,false])row.append(button(allowed?'Allow':'Deny',()=>action('permission',{id:req.id,allow:allowed,remember:remember.checked}),allowed?'primary':'danger'));row.append(label);card.append(row);root.append(card);}for(const req of state.questions||[]){const card=el('section','question');card.append(el('strong',null,req.question),el('small',null,req.sessionTitle||''));const row=el('div','row');for(const option of req.options||[])row.append(button(option,()=>action('ask:answer',{id:req.id,text:option})));const input=el('input');input.type='text';input.placeholder='Or type an answer';row.append(input,button('Send',()=>action('ask:answer',{id:req.id,text:input.value}),'primary'),button('Dismiss',()=>action('ask:answer',{id:req.id,text:''})));card.append(row);root.append(card);}}
function show(next){page=next;document.body.classList.remove('sidebar-open');syncSidebar();$('chatPage').hidden=page!=='chat';$('panel').hidden=page==='chat';$('pageTitle').textContent=({chat:'Chat',cowork:'Cowork',agents:'Subagents',providers:'Providers',tools:'Tools',loops:'Chat loops',logs:'Logs & traces',settings:'Settings'})[page]||page;document.querySelectorAll('[data-page]').forEach(b=>{b.classList.toggle('selected',b.dataset.page===page);if(b.dataset.page===page)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});if(page==='chat')welcome();else renderPanel();}
function heading(root,title,control){const h=el('div','panel-heading');h.append(el('h1',null,title));if(control)h.append(control);root.append(h);}
function card(root,title){const n=el('section','card');if(title)n.append(el('h3',null,title));root.append(n);return n;}
let toolFilter='';
function renderPanel(){const root=$('panel');root.replaceChildren();
  if(page==='memory'){heading(root,'Memory & skills');const list=el('div','tool-grid');root.append(list);for(const tool of state.tools||[]){if(tool.name.startsWith('memory_')||tool.name.startsWith('skills_')){const c=card(list,tool.name);c.append(el('p','muted',tool.description),button('Open',()=>runTool(tool.name),'outline'));}}return;}
  if(page==='cowork'){heading(root,'Cowork');const c=card(root,'Inference runtime');c.append(el('p',null,'Web mode lets Node hold the AI connection and streams responses straight to this browser. Roblox keeps running tools, permissions, subagents, and memory.'));const modes=el('div','segments');for(const mode of ['game','web'])modes.append(button(mode==='web'?'Web · real streaming':'Game · direct HTTP',()=>action('runtime',{value:mode}),state.runtime===mode?'selected':''));c.append(modes,el('p','muted',connected?'Roblox connected · acknowledged long-poll delivery':'Enable the bridge in Roblox → Cowork, then paste the token from the Node console.'));const m=card(root,'Session accounting');m.classList.add('metrics');m.append(metric(state.usage?.total||0,'Tokens'),metric(state.usage?.requests||0,'Requests'),metric('$'+(state.usage?.cost||0).toFixed(4),'Estimated cost'));}
  else if(page==='providers'){heading(root,'Providers',button('＋ Add provider',()=>providerEditor(),'outline'));for(const p of state.providers||[]){const c=card(root,p.label),row=el('div','row');row.append(el('span','muted',p.baseUrl||''),el('span','spacer'),button(state.activeProvider===p.id?'Active':'Use',()=>action('provider',{id:p.id})),button('Edit',()=>providerEditor(p)));c.append(row,el('p',null,p.model||'No model selected'),el('small',null,`${p.health?.ok||0} successful · ${p.health?.fail||0} failed`));if(p.health?.lastError)c.append(el('p','danger',p.health.lastError));}}
  else if(page==='tools'){const filter=el('input');filter.placeholder='Search tools…';filter.value=toolFilter;filter.oninput=()=>{toolFilter=filter.value;renderToolCards(list);};heading(root,'Tools',filter);const list=el('div','tool-grid');root.append(list);renderToolCards(list);}
  else if(page==='agents'){heading(root,'Subagents');for(const a of state.subagents||[]){const c=card(root,a.label||a.id);c.append(el('p',null,a.task),el('small',null,a.status));if(a.report)c.append(el('pre','json-output',a.report));if(['running','queued'].includes(a.status))c.append(button('Stop',()=>action('subagent:stop',{id:a.id}),'danger'));}if(!state.subagents?.length)root.append(el('p','muted','Dispatch a subagent from chat to see its progress here.'));}
  else if(page==='loops'){heading(root,'Chat loops',button('Start chatbot',()=>runTool('chat_bot',{instructions:'Be friendly, casual, and helpful.'}),'outline'));for(const l of state.loops||[]){const c=card(root,`${l.kind==='bot'?'Chatbot':l.kind} · ${l.channel}`);c.append(el('p',null,`${l.state} · ${l.sent}/${l.count} sent`));if(l.reason)c.append(el('small',null,l.reason));for(const score of Object.values(l.scores||{}))c.append(el('div',null,`${score.name}: ${score.points}`));if(l.state==='running')c.append(button('Stop',()=>action('loops:stop',{id:l.id}),'danger'));}const row=el('div','row');for(const name of ['quiz_bot','auto_chat','auto_reply'])row.append(button(name,()=>runTool(name)));root.append(row);}
  else if(page==='logs'){heading(root,'Logs & traces',button('Clear logs',()=>action('logs:clear')));for(const r of [...(state.requests||[])].reverse()){const c=card(root,`${r.status||'Error'} · ${r.tag||r.method} · ${r.ms||0} ms`);c.append(el('small',null,`${r.via||''} · ${r.url||''}`));if(r.error)c.append(el('p','danger',r.error));}for(const entry of [...(state.logs||[])].reverse())root.append(el('pre','json-output',typeof entry==='string'?entry:JSON.stringify(entry)));}
  else if(page==='settings'){heading(root,'Settings');const permissions=card(root,'Permissions');const modes=el('div','segments');for(const mode of ['readonly','ask','auto','full'])modes.append(button(mode,()=>action('permission-mode',{mode}),state.permissions?.mode===mode?'selected':''));permissions.append(modes);for(const [section,values]of Object.entries(state.settings||{})){const details=el('details','card');details.append(el('summary',null,({ui:'Appearance',agent:'Agent',logs:'Logs',iy:'Infinite Yield',identity:'Provider identity'})[section]||section));for(const [key,value]of Object.entries(values)){if(['lastSeenVersion','panel'].includes(key))continue;const row=el('label','setting');row.append(el('span',null,key.replace(/([A-Z])/g,' $1').replace(/^./,c=>c.toUpperCase())));let input;if(typeof value==='boolean'){input=el('input');input.type='checkbox';input.checked=value;}else{input=el(key==='customInstructions'?'textarea':'input');if(input.tagName==='INPUT')input.type=typeof value==='number'?'number':'text';input.value=value;}input.onchange=()=>action('setting',{path:section+'.'+key,value:typeof value==='boolean'?input.checked:typeof value==='number'?Number(input.value):input.value});row.append(input);details.append(row);}root.append(details);}const extras=card(root,'Memory, skills & configuration');const row=el('div','row');for(const name of ['memory_list','skills_list','skills_write','skills_install'])if(state.tools?.some(t=>t.name===name))row.append(button(name,()=>runTool(name)));row.append(button('Export full config',async()=>{try{const data=await command('config:export');download('uai-config.json',data.text,'application/json');}catch(e){toast(e.message);}}),button('Import full config',()=>modal('Import configuration',body=>{const input=field(body,'Paste configuration JSON','','textarea');body.append(button('Import',async()=>{try{await command('config:import',{text:input.value});$('modal').close();toast('Configuration imported');}catch(e){toast(e.message);}},'primary'));})));extras.append(row);}
}
function renderToolCards(root){root.replaceChildren();for(const t of state.tools||[]){if(!`${t.name} ${t.description}`.toLowerCase().includes(toolFilter.toLowerCase()))continue;const c=card(root,t.name);c.append(el('p',null,t.description),el('span','pill',t.risk),el('small',null,t.available?'':' Unavailable on this executor'));const row=el('div','row');const rule=select(row,'Permission',['default','ask','allow','deny'],t.rule||'default');rule.onchange=()=>action('tool:rule',{name:t.name,rule:rule.value});row.append(button('Run…',()=>runTool(t.name)),button(t.enabled?'Disable group':'Enable group',()=>action('tool:group',{group:t.group,enabled:!t.enabled})));c.append(row);}}
function runTool(name,initial){
  const tool=state.tools?.find(t=>t.name===name);
  modal(name,root=>{
    root.append(el('p','muted',tool?.description||''));
    const form=el('form','tool-form'),fields=el('div','form-grid'),inputs={};
    const required=new Set(tool?.parameters?.required||[]);
    form.append(fields);root.append(form);
    for(const [key,schema]of Object.entries(tool?.parameters?.properties||{})){
      const value=initial?.[key]??schema.default,type=schema.type;
      const label=key.replace(/_/g,' ')+(required.has(key)?' *':'');
      let input;
      if(schema.enum||type==='boolean'){
        const choices=schema.enum||[true,false];
        input=select(fields,label,[['',required.has(key)?'Choose a value':'Use default'],...choices.map(v=>[String(v),String(v)])],value===undefined?'':String(value));
      }else{
        const multiline=['array','object'].includes(type)||/^(code|source|script|content|body|text|instructions|old_text|new_text|patch|diff)$/.test(key)||String(value||'').includes('\n');
        input=field(fields,label,value===undefined?'':typeof value==='object'?JSON.stringify(value,null,2):value,multiline?'textarea':['number','integer'].includes(type)?'number':'text');
        if(multiline){input.rows=key==='code'?9:4;input.spellcheck=false;input.classList.add('code-input');}
        if(type==='integer')input.step='1';else if(type==='number')input.step='any';
        if(schema.minimum!==undefined)input.min=schema.minimum;
        if(schema.maximum!==undefined)input.max=schema.maximum;
        if(schema.maxLength!==undefined)input.maxLength=schema.maxLength;
        if(schema.minLength!==undefined)input.minLength=schema.minLength;
      }
      input.name=key;input.dataset.parameter=key;
      input.required=required.has(key)&&(!!schema.enum||type!=='string'||schema.minLength>0);
      inputs[key]={input,schema};
      if(schema.description){const help=el('small','field-help',schema.description);help.id='tool-help-'+key;input.parentElement.append(help);input.setAttribute('aria-describedby',help.id);}
    }
    const output=el('p','form-error');output.setAttribute('role','alert');output.hidden=true;
    const run=el('button','primary','Run tool');run.type='submit';
    run.disabled=tool?.available===false||tool?.enabled===false||!connected;
    form.append(el('small','field-help','* Required parameter. Your current permissions apply.'),output,run);
    let running=false;
    form.onsubmit=async event=>{
      event.preventDefault();if(running)return;
      output.hidden=true;
      const args={};
      try{
        for(const [key,{input,schema}]of Object.entries(inputs)){
          const raw=input.value,type=schema.type;
          if(raw===''&&!required.has(key))continue;
          let value=raw;
          if(['array','object','boolean'].includes(type)){
            try{value=JSON.parse(raw);}catch{throw Error(key+': enter valid '+(type==='boolean'?'true or false':'JSON')+'.');}
            if(type==='array'&&!Array.isArray(value))throw Error(key+': enter a JSON array.');
            if(type==='object'&&(!value||typeof value!=='object'||Array.isArray(value)))throw Error(key+': enter a JSON object.');
            if(type==='boolean'&&typeof value!=='boolean')throw Error(key+': choose true or false.');
          }else if(['number','integer'].includes(type)){
            value=Number(raw);
            if(!raw.trim()||!Number.isFinite(value)||(type==='integer'&&!Number.isInteger(value)))throw Error(key+': enter a valid '+type+'.');
          }
          args[key]=value;
        }
      }catch(err){output.textContent=err.message;output.hidden=false;return;}
      running=true;run.disabled=true;
      const originSession=sessionId;
      // Approvals live in the transcript, so release the dialog before waiting.
      $('modal').close();show('chat');toast('Running '+name+'…');
      try{
        const result=await command('tool:run',{name,arguments:args});
        if(!$('modal').open&&sessionId===originSession&&page==='chat')modal(name+' result',body=>body.append(codeListing(result?.text||JSON.stringify(result,null,2),result?.ok===false?'Execution details':'Result')));
        else toast(name+' finished. Its result is in the conversation.');
      }catch(err){output.textContent=err.message;output.hidden=false;toast(err.message);}
      finally{running=false;run.disabled=false;}
    };
  });
}
function providerEditor(provider){modal(provider?'Edit provider':'Add provider',root=>{const form=el('div','form-grid');root.append(form);const preset=select(form,'Preset',(state.presets||[]).map(p=>[p.id,p.label]),provider?.preset||'custom');const label=field(form,'Name',provider?.label||''),url=field(form,'Base URL',provider?.baseUrl||''),apiStyle=select(form,'API',['openai','anthropic'],provider?.api||'openai'),auth=select(form,'Authentication',['bearer','api-key','none'],provider?.authStyle||'bearer'),key=field(form,provider?.hasKey?'API key (blank keeps current key)':'API key','','password'),model=field(form,'Model',provider?.model||'');preset.onchange=()=>{const p=state.presets?.find(p=>p.id===preset.value);if(p){label.value=p.label||'';url.value=p.baseUrl||'';apiStyle.value=p.api||'openai';auth.value=p.authStyle||'bearer';}};root.append(button('Save',async()=>{const fields={id:provider?.id,preset:preset.value,label:label.value,baseUrl:url.value,api:apiStyle.value,authStyle:auth.value,model:model.value};if(key.value)fields.apiKey=key.value;try{await command('provider:save',{provider:fields});$('modal').close();}catch(e){toast(e.message);}},'primary'));if(provider)root.append(button('Delete',async()=>{if(confirm('Delete this provider?')){await action('provider:remove',{id:provider.id});$('modal').close();}},'danger'));});}
function models(){modal('Models',root=>{const provider=select(root,'Provider',(state.providers||[]).map(p=>[p.id,p.label]),state.activeProvider);const search=field(root,'Search models','');const freeLabel=el('label','row'),free=el('input');free.type='checkbox';freeLabel.append(free,document.createTextNode('Free only'));root.append(freeLabel);const list=el('div','model-list');root.append(list);function paint(){list.replaceChildren();const p=state.providers?.find(p=>p.id===provider.value);for(const id of p?.models||[]){if(!id.toLowerCase().includes(search.value.toLowerCase())||(free.checked&&!/free|big-pickle/i.test(id)))continue;list.append(button(id,()=>action('model',{provider:p.id,model:id}),p.model===id?'selected':''));}}provider.onchange=paint;search.oninput=paint;free.onchange=paint;paint();const effort=select(root,'Reasoning effort',['low','medium','high','xhigh','max'],state.settings?.agent?.effort||'high');effort.onchange=()=>action('setting',{path:'agent.effort',value:effort.value});root.append(button('Refresh models',async()=>{await action('models:discover',{provider:provider.value});toast('Model discovery requested. Reopen this picker when complete.')}),button('Manage providers',()=>{$('modal').close();show('providers');}));});}
// Keep transport controls in Cowork, distinct from the browser connection itself.
const baseRenderPanel=renderPanel;
const originalRenderState=renderState;
renderState=function(){const ui=state.settings?.ui||{};document.body.dataset.reasoning=ui.showReasoning===false?'hidden':'visible';document.body.dataset.density=ui.density||'comfortable';document.body.dataset.codeTheme=ui.codeTheme||'dark';originalRenderState();};
renderPanel=function(){const root=$('panel'),position=root.scrollTop;const open=new Set([...root.querySelectorAll('details[open]')].map(d=>d.querySelector('summary')?.textContent));baseRenderPanel();if(page==='cowork'){
  const c=card(root,'Provider deadline');const timeout=field(c,'Seconds per provider request',state.relayTimeout||180,'number');timeout.min=10;timeout.max=86400;timeout.onchange=()=>action('setting',{path:'bridge.requestTimeout',value:Number(timeout.value)});
  c.append(el('small',null,'The executor only submits and polls short requests. Node owns the long connection. Stop cancels it.'));
}else if(page==='providers'){
  const c=card(root,'Provider diagnostics');for(const p of state.providers||[])c.append(button('Test '+p.label,async()=>{try{const result=await command('provider:test',{id:p.id});toast(result.text+' · '+result.ms+' ms');}catch(e){toast(e.message);}}));
}for(const details of root.querySelectorAll('details'))if(open.has(details.querySelector('summary')?.textContent))details.open=true;root.scrollTop=position;};
async function submit(){
  if(sending||busy||!connected)return;
  const text=$('input').value;if(!text.trim()&&!uploads.length)return;
  saveDraft();
  const original=$('input').value,files=uploads.slice(),sentSession=sessionId,sentVersion=drafts[sessionId]?.version;
  sending=true;setBusy(busy);
  try{
    const encode=new TextEncoder(),limit=state.attachments?.inlineLimit||8000;
    const parts=[],references=[];
    const attach=async(text,name)=>{const file=await uploadText(text,name,sentSession);references.push({path:file.path,bytes:file.bytes});return file.reference;};
    if(encode.encode(text).length>limit)parts.push(await attach(text,'pasted-input.txt'),'Read the file for the complete user input, including any request at the end.');
    else parts.push(text.trim()||'Please read the attached input.');
    for(const file of files){
      if(encode.encode(file.text).length>limit)parts.push(await attach(file.text,file.name));
      else parts.push(`[Attached: ${file.name}]\n${file.text}`);
    }
    await command('send',{text:parts.join('\n\n'),files:references,sessionId:sentSession});
    if(sessionId===sentSession)saveDraft();
    const current=drafts[sentSession]||{},sentIds=new Set(files.map(f=>f.id));
    const clear=current.version===sentVersion&&current.text===original;
    drafts[sentSession]={text:clear?'':current.text||'',version:(current.version||0)+(clear?1:0),uploads:(current.uploads||[]).filter(f=>!sentIds.has(f.id))};
    if(sessionId===sentSession){$('input').value=drafts[sentSession].text;uploads=drafts[sentSession].uploads;renderAttachments();grow();}
    else persistDrafts();
  }catch(e){toast(e.message);}
  finally{sending=false;setBusy(busy);}
}
async function uploadText(text,name,target){
  const encode=new TextEncoder(),max=state.attachments?.maxBytes||2*1024*1024;
  if(encode.encode(text).length>max)throw Error(name+' exceeds 2 MiB. Split it into smaller files.');
  const uploadId=uuid();let offset=0,result;
  for(let at=0;at<text.length;){
    let end=Math.min(at+32768,text.length);
    if(end<text.length&&text.charCodeAt(end-1)>=0xd800&&text.charCodeAt(end-1)<=0xdbff)end--;
    const content=text.slice(at,end);
    result=await command('attachment:upload',{sessionId:target,uploadId,name,offset,content,final:end===text.length});
    offset+=encode.encode(content).length;at=end;
  }
  if(!result?.reference||!result.path||result.bytes!==offset)throw Error('The saved attachment could not be verified. Your draft was kept.');
  return result;
}
function pasteInput(event){
  const text=event.clipboardData?.getData('text/plain');
  if(!text||!sessionId||new TextEncoder().encode(text).length<=(state.attachments?.inlineLimit||8000))return;
  event.preventDefault();
  if(new TextEncoder().encode(text).length>(state.attachments?.maxBytes||2*1024*1024)){toast('This paste exceeds 2 MiB. Split it into smaller files.');return;}
  const input=$('input');input.setRangeText('',input.selectionStart,input.selectionEnd,'end');
  uploads.push({id:uuid(),name:'pasted-input.txt',text});renderAttachments();grow();
}
async function attachFiles(){
  const selected=Array.from($('fileInput').files),target=sessionId;
  $('fileInput').value='';
  if(!target){toast('Connect to Roblox before attaching files.');return;}
  saveDraft();
  for(const file of selected){
    if(file.size>(state.attachments?.maxBytes||2*1024*1024)){toast(file.name+' exceeds 2 MiB');continue;}
    if(/^(image|audio|video)\//.test(file.type)){toast(file.name+': attach a text or code file.');continue;}
    try{
      const text=await file.text();
      if(text.includes('\0')){toast(file.name+': binary files are not supported.');continue;}
      const item={id:uuid(),name:file.name,text};
      if(sessionId===target){uploads.push(item);renderAttachments();saveDraft();setBusy(busy);}
      else{const draft=drafts[target]||{text:'',version:0,uploads:[]};drafts[target]={...draft,uploads:[...(draft.uploads||[]),item]};persistDrafts();}
    }catch(err){toast('Could not read '+file.name+': '+err.message);}
  }
}
function download(name,text,type){const url=URL.createObjectURL(new Blob([text],{type}));const a=el('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
$('send').onclick=submit;$('stop').onclick=()=>action('abort');$('clear').onclick=()=>{if(confirm('Clear this conversation?'))action('clear');};
$('input').oninput=grow;
$('input').onpaste=pasteInput;
$('input').onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing&&e.keyCode!==229){e.preventDefault();submit();}};
$('newThread').onclick=$('newConversation').onclick=()=>action('thread:new');$('modelButton').onclick=models;
$('attach').onclick=()=>$('fileInput').click();$('fileInput').onchange=attachFiles;
$('options').onclick=()=>modal('Conversation options',root=>{root.className='stack';root.append(button('Model and effort',models),button('Permissions',()=>{$('modal').close();show('settings');}),button('Chat loops',()=>{$('modal').close();show('loops');}));for(const [title,,prompt]of starters)root.append(button(title,()=>{$('modal').close();insert(prompt);}));root.append(button('Export JSON',()=>download('uai-events.json',JSON.stringify(events,null,2),'application/json')));});
$('sidebarToggle').onclick=()=>{document.body.classList.toggle(innerWidth<=700?'sidebar-open':'sidebar-hidden');syncSidebar();};
$('closeSidebar').onclick=()=>{document.body.classList.remove('sidebar-open');syncSidebar();};
$('searchThreads').onclick=()=>{$('threadSearch').hidden=!$('threadSearch').hidden;$('searchThreads').setAttribute('aria-expanded',String(!$('threadSearch').hidden));if(!$('threadSearch').hidden)$('threadSearch').focus();};
$('threadSearch').oninput=renderThreads;document.querySelectorAll('[data-page]').forEach(b=>b.onclick=()=>show(b.dataset.page));
$('latest').onclick=()=>{$('transcript').scrollTop=$('transcript').scrollHeight;};$('transcript').onscroll=()=>$('latest').hidden=stick();
$('exportChat').onclick=()=>download('uai-transcript.md',events.filter(e=>['user','assistant:text'].includes(e.kind)).map(e=>`### ${e.kind==='user'?'You':'Assistant'}\n\n${e.text}\n`).join('\n'),'text/markdown');
document.addEventListener('click',e=>{const b=e.target.closest('.copy-code');if(b)navigator.clipboard.writeText(decodeURIComponent(b.dataset.code)).then(()=>toast('Copied')).catch(()=>toast('Clipboard unavailable'));});
function syncSidebar(){const open=innerWidth<=700?document.body.classList.contains('sidebar-open'):!document.body.classList.contains('sidebar-hidden');$('sidebarToggle').setAttribute('aria-expanded',String(open));}
window.addEventListener('resize',syncSidebar);syncSidebar();
async function enter(){await api('/hello');try{sessionStorage.setItem('uai.token',token);localStorage.removeItem('uai.token');}catch{}$('gate').hidden=true;$('app').hidden=false;welcome();if(stream)stream.close();stream=new EventSource('/api/stream?token='+encodeURIComponent(token));stream.onmessage=e=>{try{apply(JSON.parse(e.data));}catch(err){console.error(err);toast('Could not render bridge update: '+err.message);}};stream.onerror=()=>{$('status').textContent='Bridge reconnecting…';connected=false;setBusy(busy);};}
$('gate-form').onsubmit=async e=>{e.preventDefault();token=$('gate-token').value.trim();try{await enter();}catch(err){$('gate-error').textContent=err.message;}};
(async()=>{try{if(!token)throw Error('');await enter();}catch{$('gate').hidden=false;$('app').hidden=true;}})();
