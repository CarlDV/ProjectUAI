'use strict';
const $=id=>document.getElementById(id), md=UAIMarkdown.render;
const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
const button=(text,fn,cls,key)=>{const n=el('button',cls,text);n.type='button';n.onclick=fn;if(key)n.dataset.focusKey=key;return n;};
function icon(name){const n=document.createElementNS('http://www.w3.org/2000/svg','svg'),use=document.createElementNS(n.namespaceURI,'use');n.classList.add('icon');n.setAttribute('aria-hidden','true');use.setAttribute('href','icons.svg#'+name);n.append(use);return n;}
const uuid=()=>crypto.randomUUID();
function stored(storage,key){try{return window[storage].getItem(key);}catch{return null;}}
const fromHash=location.hash.match(/(?:#|&)t=([a-f0-9]{64})(?:$|&)/i);
let token=fromHash?.[1]?.toLowerCase()||stored('sessionStorage','uai.token')||stored('localStorage','uai.token')||'';
if(fromHash)history.replaceState(null,'',location.pathname);
let state={},page='chat',stream,busy=false,connected=false,sending=false,sessionId=null,events=[],uploads=[],instance=stored('sessionStorage','uai.instance');
let drafts={};try{const value=JSON.parse(stored('sessionStorage','uai.drafts')||'{}');if(value&&typeof value==='object'&&!Array.isArray(value))drafts=value;}catch{}
const tools=new Map(),dirtyDrafts=new Set();
let toastTimer,draftTimer,storageWarning=false,renderingSnapshot=false,eventBytes=0,sendOperation=null,connectionRetry,readingFiles=0,modalRefresh=null,panelRefreshPending=false,panelPointerActive=false,panelPointerTimer;
const draftLoads=new Map();
const MAX_DRAFT_BYTES=8*1024*1024,MAX_EVENTS_BYTES=8*1024*1024;
// Explicit operation state machine (contract): the visible/label state is derived
// from link + sendPhase + busy rather than a tangle of loose booleans.
document.body.dataset.page='chat';
let link='connecting';               // disconnected|connecting|online|offline
let sendPhase='idle';                // idle|reading|uploading|submitting|awaiting-turn
let awaitTurnTimer=null;
let lastSend=null;                   // {text,files,pictureIds,sessionId} for retry
// Stable random per-tab browser id (NOT authentication; identifies the upload owner).
let browserId=stored('sessionStorage','uai.browserId')||uuid();try{sessionStorage.setItem('uai.browserId',browserId);}catch{}
// Picture staging lives in pictures.js (UAI.pictures), instantiated once the DOM is ready.
const OP_LABEL={reading:'Reading files…',uploading:'Uploading files…',submitting:'Sending…','awaiting-turn':'Waiting for the agent…',stopping:'Stopping…',uncertain:'Checking message delivery…'};
function toast(text){
  clearTimeout(toastTimer);
  if($('modal').open){$('toast').hidden=true;$('modalNotice').textContent=text;$('modalNotice').scrollIntoView({block:'nearest'});return;}
  $('toast').textContent=text;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,4500);
}
function announce(text){if($('status').textContent!==text)$('status').textContent=text;}
// Surface the bridge's real reason: 401/403/405 return plain-text bodies, so read
// res.text() and only fall back to a generic message when there is nothing useful.
async function api(path,body,method){
  const res=await fetch('/api'+path,{method:method||(body===undefined?'GET':'POST'),headers:{Authorization:'Bearer '+token,'X-UAI-Browser-Id':browserId,...((body?.sessionId||sessionId)?{'X-UAI-Session-Id':body?.sessionId||sessionId}:{}),...(body===undefined?{}:{'content-type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  const raw=res.status===204?'':await res.text();
  let data,parsed=false;try{data=raw?JSON.parse(raw):{};parsed=true;}catch{data={};}
  if(!res.ok){
    const plain=(!parsed&&raw&&raw.length<=300)?raw.trim():'';
    const error=Error(res.status===401?'This token no longer works. Open the latest bridge link or paste its new token.':data.error||plain||`Bridge returned ${res.status}`);
    error.status=res.status;error.code=data.code;if(res.status===401)showGate(error.message);throw error;
  }
  return data;
}
async function command(type,fields={}){
  if(!connected)throw Error('Connect Roblox in Cowork before using this action.');
  const commandId=fields.commandId||uuid(), payload={type,sessionId,...fields,commandId};
  let receipt;
  for(let i=0;i<2;i++){try{receipt=await api('/command',payload);break;}catch(err){if(err.status||i){if(!err.status)err.uncertain=true;throw err;}}}
  if(!receipt?.id){const error=Error('The bridge did not confirm this action. Check delivery before trying again.');error.uncertain=true;throw error;}
  const deadline=Date.now()+190000;
  while(Date.now()<deadline){let result;try{result=await api('/commands/'+receipt.id);}catch(err){if(err.name!=='TypeError'&&err.name!=='TimeoutError'){err.uncertain=true;throw err;}await new Promise(r=>setTimeout(r,1000));continue;}if(!['queued','running'].includes(result.state)){if(result.result?.ok===false){const error=Error(result.result.error||'The game could not complete this action.');error.uncertain=!!result.result.uncertain;throw error;}return result.result?.data;}await new Promise(r=>setTimeout(r,250));}
  const error=Error('This action is still pending. Check delivery before sending it again.');error.uncertain=true;throw error;
}
function action(type,fields){return command(type,fields).catch(err=>toast(err.message));}
function modal(title,build){
  modalRefresh=null;$('modalTitle').textContent=title;$('modalNotice').textContent='';$('modalBody').replaceChildren();$('modalBody').className='';
  build($('modalBody'));if(!$('modal').open)$('modal').showModal();$('modal').scrollTop=0;$('modal').scrollLeft=0;
  const first=$('modalBody').querySelector('input:not([type="hidden"]):not(:disabled),select:not(:disabled),textarea:not(:disabled),button:not(:disabled),[tabindex="0"]');
  (first||$('modalClose')).focus({preventScroll:true});
}
async function modalCommand(type,fields){try{await command(type,fields);$('modal').close();}catch(error){toast(error.message);}}
$('modalClose').onclick=()=>$('modal').close();
$('modal').addEventListener('close',()=>{if(!$('modal').open){modalRefresh=null;$('modalNotice').textContent='';queueMicrotask(flushPanelRefresh);}});
function field(parent,label,value,type='text'){const holder=el('label',null,label),input=el(type==='textarea'?'textarea':'input');if(type!=='textarea')input.type=type;input.value=value??'';holder.append(input);parent.append(holder);return input;}
function select(parent,label,values,value){const holder=el('label',null,label),input=el('select');input.setAttribute('aria-label',label);for(const item of values){const pair=typeof item==='string'?[item,item]:item;const option=el('option',null,pair[1]);option.value=pair[0];input.append(option);}input.value=value;holder.append(input);parent.append(holder);return input;}
function persistDrafts(){
  clearTimeout(draftTimer);
  // Small recovery text is synchronous; file bodies and full drafts use IndexedDB.
  const recent=Object.entries(drafts).sort((a,b)=>(b[1].updatedAt||0)-(a[1].updatedAt||0)).slice(0,20);
  const small=Object.fromEntries(recent.map(([id,draft])=>{
    const complete=Array.isArray(draft.uploads)&&!draftLoads.has(id);
    const fileIds=complete?draft.uploads.map(f=>f.id):Array.isArray(draft.fileIds)?[...new Set([...draft.fileIds,...(draft.uploads||[]).map(f=>f.id)])]:undefined;
    return [id,{text:(draft.text||'').slice(0,16000),textLength:draft.textLength??draft.text?.length??0,fileIds,version:draft.version||0,updatedAt:draft.updatedAt}];
  }));
  try{sessionStorage.setItem('uai.drafts',JSON.stringify(small));}catch{}
  for(const id of dirtyDrafts){
    // Wait for old file bodies before saving a recovery copy or newly typed text.
    if(draftLoads.has(id))continue;
    dirtyDrafts.delete(id);const value=drafts[id];
    if(value)UAI.drafts.save(id,value).then(ok=>{if(!ok&&!storageWarning){storageWarning=true;toast('Browser storage is unavailable. Keep this tab open to retain attached files.');}});
  }
}
function saveDraft(){
  if(!sessionId)return;
  const previous=drafts[sessionId]||{},text=$('input').value;
  const oldFiles=previous.uploads||[];
  if((previous.text||'')===text&&oldFiles.length===uploads.length&&oldFiles.every((file,i)=>file.id===uploads[i].id))return;
  drafts[sessionId]={...previous,text,textLength:text.length,uploads:uploads.slice(),version:(previous.version||0)+(previous.text===text?0:1),updatedAt:Date.now()};
  dirtyDrafts.add(sessionId);clearTimeout(draftTimer);draftTimer=setTimeout(persistDrafts,450);
}
function changeSession(id){
  if(!id||id===sessionId)return;
  saveDraft();persistDrafts();if(sessionId)renderer.dropSession(sessionId);sessionId=id;
  $('input').value=typeof drafts[id]?.text==='string'?drafts[id].text:'';
  uploads=Array.isArray(drafts[id]?.uploads)?drafts[id].uploads.filter(f=>f&&typeof f.name==='string'&&typeof f.text==='string').map(f=>({...f,id:f.id||uuid()})):[];
  if(window.UAI&&UAI.pictures)UAI.pictures.showSession();
  renderAttachments();resizeComposer();refresh();
  if(draftLoads.has(id)||Array.isArray(drafts[id]?.uploads))return;
  const loading=UAI.drafts.load(id).then(saved=>{
    const current=drafts[id],newer=current&&(!saved||(current.updatedAt||0)>=(saved.updatedAt||0));
    let files=Array.isArray(saved?.uploads)?saved.uploads.filter(f=>f&&typeof f.name==='string'&&typeof f.text==='string').map(f=>({...f,id:f.id||uuid()})):[];
    if(newer&&Array.isArray(current.fileIds))files=files.filter(f=>current.fileIds.includes(f.id));
    for(const file of current?.uploads||[])if(!files.some(f=>f.id===file.id))files.push(file);
    // The synchronous copy may contain only the start of a long draft. Keep its
    // full stored body when both copies identify the same text.
    const truncated=newer&&current.textLength>current.text?.length&&saved?.text?.length===current.textLength&&saved.text.startsWith(current.text);
    const text=newer&&!truncated?current.text||'':saved?.text||current?.text||'';
    drafts[id]={...(newer?current:saved),text,textLength:text.length,uploads:files};delete drafts[id].fileIds;
    if(sessionId===id){$('input').value=text;uploads=files.slice();renderAttachments();resizeComposer();}
  }).finally(()=>{draftLoads.delete(id);if(dirtyDrafts.has(id))persistDrafts();refresh();});draftLoads.set(id,loading);refresh();
}
function resizeComposer(){const input=$('input');const cap=parseFloat(getComputedStyle(input).maxHeight)||230;input.style.height='auto';input.style.height=Math.min(input.scrollHeight,cap)+'px';}
function grow(){resizeComposer();saveDraft();refresh();}
function renderAttachments(){
  const active=document.activeElement,focused=$('attachments').contains(active),focusId=active?.dataset.fileId,index=[...$('attachments').children].indexOf(active);
  $('attachments').replaceChildren();
  uploads.forEach((file,index)=>{
    const remove=button(file.name+' ×',()=>{uploads.splice(index,1);renderAttachments();saveDraft();});
    remove.dataset.fileId=file.id;remove.title='Remove '+file.name;remove.setAttribute('aria-label',remove.title);$('attachments').append(remove);
  });
  if(focused){const remaining=[...$('attachments').children];(remaining.find(n=>n.dataset.fileId===focusId)||remaining[Math.min(index,remaining.length-1)]||$('attach')).focus({preventScroll:true});}
  setBusy(busy);
}
function hasContent(){return !!$('input').value.trim()||uploads.length>0||!!(window.UAI&&UAI.pictures&&UAI.pictures.hasStaged());}
function picturesBusy(){return !!(window.UAI&&UAI.pictures&&UAI.pictures.busy());}
function setBusy(value){busy=!!value;refresh();}
function refresh(){
  const generating=busy;
  $('stop').hidden=!generating;$('send').hidden=generating;
  $('stop').disabled=sendPhase==='stopping'||!connected;
  const blocked=sending||sendPhase!=='idle'||readingFiles>0||draftLoads.has(sessionId)||!connected||picturesBusy()||UAI.pictures?.hasErrors();
  $('send').disabled=blocked||!hasContent();
  $('attachPictures').hidden=!UAI.pictures?.enabled();
  $('transcript').setAttribute('aria-busy',String(generating||sendPhase!=='idle'));
  document.body.dataset.op=generating?'generating':(sendPhase!=='idle'?sendPhase:'idle');
  document.body.dataset.link=link;document.body.dataset.game=connected?'connected':'disconnected';
  $('connectionLabel').textContent=connected?'Game connected':link==='online'?'Connect your game':'Bridge reconnecting';
  $('localConnection').textContent=link==='online'?'Connected locally':'Draft kept here';
  $('connectionBanner').hidden=connected||page==='cowork';
  $('connectionMessage').textContent=link==='online'?'One last step: connect Roblox to this bridge.':'Connection interrupted. Keep the bridge terminal open; your draft is safe here.';
  $('composerHint').textContent=UAI.pictures?.hasErrors()?'Retry or remove the picture that could not be attached.':picturesBusy()?'Preparing picture previews…':readingFiles?'Reading attached files…':draftLoads.has(sessionId)?'Restoring your draft…':sendPhase!=='idle'?(OP_LABEL[sendPhase]||'Working…'):'Enter to send · Shift+Enter for a new line';
  $('deliveryNotice').hidden=sendPhase!=='uncertain';
  $('deliveryMessage').textContent=sendOperation?.lost?'Delivery could not be confirmed. Review your conversation before sending again.':'Still waiting for a delivery receipt. Your draft is safe.';
  $('deliveryReview').hidden=!sendOperation?.lost;
  if(sendPhase!=='idle')announce(OP_LABEL[sendPhase]||'Working…');
  else if(link==='offline'||link==='disconnected')announce('Bridge reconnecting…');
  else if(!connected)announce('Game offline');
  else announce(state.agent?.status||'Ready');
}
function setPhase(phase){sendPhase=phase;refresh();}
function armAwaitTurn(operation){
  clearTimeout(awaitTurnTimer);
  if(operation.sawTurn||sessionId!==operation.sessionId){setPhase('idle');return;}
  sendPhase='awaiting-turn';refresh();
  awaitTurnTimer=setTimeout(()=>{if(sendPhase==='awaiting-turn'){setPhase('idle');toast('The message was delivered. Roblox has not started a turn yet.');}},10000);
}
function copyText(text){
  if(navigator.clipboard&&window.isSecureContext){return navigator.clipboard.writeText(text).then(()=>toast('Copied')).catch(()=>fallbackCopy(text));}
  return Promise.resolve(fallbackCopy(text));
}
function fallbackCopy(text){
  try{const area=el('textarea');area.value=text;area.setAttribute('readonly','');area.style.position='fixed';area.style.opacity='0';document.body.append(area);area.select();const ok=document.execCommand('copy');area.remove();toast(ok?'Copied':'Clipboard unavailable');}
  catch{toast('Clipboard unavailable');}
}
// Two-step arm/confirm for destructive actions (replaces raw confirm()).
function armButton(btn,confirmLabel,fn){
  const original=[...btn.childNodes].map(n=>n.cloneNode(true)),label=btn.getAttribute('aria-label'),title=btn.getAttribute('title');let armed=false,timer;
  const reset=()=>{armed=false;btn.replaceChildren(...original.map(n=>n.cloneNode(true)));btn.classList.remove('armed');for(const [name,value]of [['aria-label',label],['title',title]]){if(value===null)btn.removeAttribute(name);else btn.setAttribute(name,value);}};
  btn.onclick=()=>{
    if(!armed){armed=true;btn.textContent=confirmLabel;btn.setAttribute('aria-label',confirmLabel);btn.title=confirmLabel;btn.classList.add('armed');timer=setTimeout(reset,4000);return;}
    clearTimeout(timer);reset();fn();
  };
}
function stick(){const t=$('transcript');return t.scrollHeight-t.scrollTop-t.clientHeight<120;}
function append(node){const pinned=stick();const root=$('transcript');root.querySelector('.welcome')?.remove();root.append(node);while(root.children.length>450){const old=root.firstElementChild;if(old.contains(document.activeElement))break;old.remove();}if(pinned)root.scrollTop=root.scrollHeight;}
function message(who,text,model){const node=el('article','message '+who),byline=el('div','byline');if(who==='agent'){const mark=el('img');mark.src='icon.svg';mark.alt='';byline.append(mark);}byline.append(el('span',null,who==='user'?(state.player||'You'):'UAI'),el('small','message-model',model||''));const body=el('div','body');if(who==='user')body.textContent=text;else body.innerHTML=md(text);node.append(byline,body);const result={node,body};if(who==='user')decorateMessage(result,text);append(node);return result;}
function decorateMessage(message,text,model){
  message.node._uaiText=text;
  if(model)message.node.querySelector('.message-model').textContent=model;
  if(message.node.querySelector('.message-actions'))return;
  const actions=el('span','message-actions'),copy=button('',()=>copyText(message.node._uaiText),'icon-button');copy.append(icon('copy'));copy.title='Copy message';copy.setAttribute('aria-label','Copy message');actions.append(copy);message.node.querySelector('.byline').append(actions);
}
function welcome(){
  if(events.some(e=>e.kind==='user'||e.kind==='assistant:text')||[...$('transcript').children].some(node=>!node.classList.contains('welcome')))return;
  const signature=JSON.stringify([state.player,state.place?.name,state.providers?.length,connected]);
  const previous=$('transcript').querySelector('.welcome');if(previous?.dataset.signature===signature||previous?.contains(document.activeElement))return;
  const node=el('section','welcome'),mark=el('div','welcome-mark'),logo=el('img');logo.src='icon.svg';logo.alt='';
  node.dataset.signature=signature;
  mark.append(logo,el('span','eyebrow',state.player?'YOUR WORKSPACE, '+state.player.toUpperCase():'YOUR ROBLOX WORKSPACE'));
  node.append(mark,el('h1',null,'What will we create?'),el('p','welcome-lead','Explore your game, build something useful, or work through an idea. A little context is all you need to get started.'));
  if(state.place?.name){const context=el('div','welcome-context');context.append(el('span','status-dot'),el('span',null,state.place.name));node.append(context);}
  const grid=el('div','starters');starters.forEach(([title,detail,prompt],index)=>{const item=button('',()=>insert(prompt),'starter'),copy=el('span');copy.append(el('strong',null,title),el('small',null,detail));item.append(icon(['explore','spark','activity','player'][index]),copy);grid.append(item);});node.append(grid);
  if(!connected)node.append(button('Connect your Roblox game →',()=>show('cowork'),'welcome-action'));
  else if(!state.providers?.length)node.append(button('Add your first AI provider →',()=>providerEditor(),'welcome-action'));
  else node.append(el('p','welcome-context','Tools and permissions stay connected to your game.'));
  $('transcript').replaceChildren(node);
}
const starters=[['Explore this game','Find your bearings in the world.','Explore this game. Inspect the workspace and tell me what is here, how it is organised, and what we could do next.'],['Create something','Turn an idea into a working script.','Help me build a Luau script for this game. First inspect the relevant game context, then ask what I would like to create.'],['Check performance','Understand FPS, memory, and latency.','Check client performance, memory usage, and network latency. Explain the results and suggest practical improvements.'],['Inspect my character',"See your character’s current state.",'Inspect my character and explain its position, humanoid state, and any useful attributes or attached scripts.']];
function insert(text){show('chat');$('input').value+=($('input').value?'\n\n':'')+text;grow();$('input').focus();}
function metric(value,label){const n=el('div');n.append(el('strong',null,typeof value==='number'?value.toLocaleString():value),el('small',null,label));return n;}
function thinking(text){const node=el('details','thinking');node.append(el('summary',null,'✳ Thinking'));const body=el('div','body');body.innerHTML=md(text);node.append(body);append(node);return body;}
function toolKey(e){return (e.kind?.startsWith('subagent:')?'child:'+e.id+':':'main:')+(e.callId||e.id||'')+':'+(e.name||'');}
function codeListing(text,label){
  const listing=el('div','code-block tool-listing'),head=el('div','code-head');
  const copy=button('Copy',()=>copyText(text));
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
    case 'user':{const m=message('user',e.text||'');if(window.UAI&&UAI.pictures)UAI.pictures.correlateUser(m,e);break;}
    case 'assistant:text':renderer.commitText(e);break;
    case 'assistant:reasoning':renderer.commitReasoning(e);break;
    case 'tool:call':case 'subagent:tool':openTool(e);break;
    case 'tool:result':case 'tool:error':case 'subagent:tool:done':finishTool(e);break;
    case 'tool:progress':{const row=tools.get(toolKey(e))||(!e.id&&tools.size===1?[...tools.values()][0]:null);if(row)row.preview.textContent=e.text||'';break;}
    case 'error':append(el('div','error',e.message||'Unknown error'));break;
    case 'status':announce(e.text||'Ready');break;
    case 'turn:start':if(sendOperation&&sendOperation.sessionId===sessionId)sendOperation.sawTurn=true;clearTimeout(awaitTurnTimer);if(sendPhase!=='uncertain')sendPhase='idle';setBusy(true);break;
    case 'turn:end':case 'abort':if(sendOperation&&sendOperation.sessionId===sessionId)sendOperation.sawTurn=true;clearTimeout(awaitTurnTimer);if(sendPhase!=='uncertain')sendPhase='idle';renderer.endTurn(sessionId,e.kind==='abort');setBusy(false);break;
    case 'cleared':events=[];renderer.reset();tools.clear();if(window.UAI&&UAI.pictures)UAI.pictures.clearSession(sessionId);$('transcript').replaceChildren();welcome();break;
    case 'provider:switch':append(el('div','note','Switched provider to '+e.to));break;
    case 'request:retry':append(el('div','note',`Retrying ${e.provider||'provider'} · ${e.reason||''}`));break;
    case 'subagent:start':append(el('div','note','Subagent · '+(e.task||e.label||'')));break;
    case 'subagent:done':append(el('div','note','Subagent finished · '+(e.label||'')));break;
    case 'subagent:text':{const report=el('details','subagent-report'),body=el('div','body');report.append(el('summary',null,(e.label||'Subagent')+' · report'));body.innerHTML=md(e.text||'');report.append(body);append(report);break;}
    case 'compact':append(el('div','note','Older context compacted'));break;
  }
  if(pinned)$('transcript').scrollTop=$('transcript').scrollHeight;
  $('latest').hidden=stick();
}
function scrollToEnd(){$('transcript').scrollTop=$('transcript').scrollHeight;}
function resendLast(target){
  if(target&&target!==sessionId){toast('Open the original conversation to retry.');return;}
  show('chat');
  if(lastSend&&lastSend.sessionId===sessionId&&typeof lastSend.text==='string'){
    if(!$('input').value.trim()){$('input').value=lastSend.text;if(!uploads.length)uploads=(lastSend.files||[]).map(f=>({...f,id:uuid()}));renderAttachments();}
  }else if(lastSend&&lastSend.sessionId!==sessionId){toast('Switch back to that conversation to retry.');}
  grow();$('input').focus();
}
const renderer=window.UAIStreamRenderer.create({
  md, escape:UAIMarkdown.escape,
  createAgentMessage:model=>message('agent','',model),
  createThinking:text=>thinking(text||''),
  getSession:()=>sessionId,
  defaultModel:()=>state.agent?.model,
  isPinned:stick,
  scrollToEnd,
  onActivity:active=>{document.body.dataset.streaming=active?'on':'off';},
  onRetry:resendLast,
  onFinal:decorateMessage,
});
UAI.pictures=UAI.createPictures({token,browserId,getSession:()=>sessionId,api,toast,tray:$('pictureTray'),input:$('pictureInput'),pickerButton:$('attachPictures'),dropZone:$('composer'),onTextFiles:attachFiles,onChange:refresh});
function apply(e){
  if(typeof e.kind!=='string')return;
  if(e.kind==='bridge:reset'){events=[];eventBytes=0;renderer.reset();tools.clear();UAI.pictures.resetMessages();$('transcript').replaceChildren();welcome();if(e.resync)toast('Connection restored. Reloaded the latest saved conversation.');return;}
  if(e.kind==='bridge:snapshot'){
    events=[];eventBytes=0;for(const event of Array.isArray(e.events)?e.events:[])retainEvent(event);
    renderer.reset();tools.clear();UAI.pictures.resetMessages();$('transcript').replaceChildren();changeSession(e.sessionId);
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
  if(e.kind==='bridge:game'){const changed=connected!==!!e.connected;connected=!!e.connected;setBusy(state.agent?.busy);welcome();if(changed&&page==='cowork')requestPanelRefresh();return;}
  if(e.kind==='inference:start'){renderer.start(e);return;}
  if(e.kind==='inference:delta'){renderer.delta(e);return;}
  if(e.kind==='inference:done'){renderer.done(e);return;}
  if(e.kind==='inference:resync'){renderer.resync(e);return;}
  if(e.kind==='bridge:picture'){if(window.UAI&&UAI.pictures)UAI.pictures.handleEvent(e);return;}
  if(e.kind.startsWith('bridge:'))return;
  if(e.sessionId&&sessionId&&e.sessionId!==sessionId)return;
  retainEvent(e);renderEvent(e);
}
function retainEvent(e){
  if(!e||typeof e.kind!=='string')return;
  const bytes=new TextEncoder().encode(JSON.stringify(e)).length;
  if(bytes>MAX_EVENTS_BYTES)return;
  events.push(e);eventBytes+=bytes;
  while(events.length>400||eventBytes>MAX_EVENTS_BYTES){eventBytes-=new TextEncoder().encode(JSON.stringify(events.shift())).length;}
}
const appliedThemeVars=new Set();
// Apply the game-provided #rrggbb theme, clearing any var that has disappeared so
// the stylesheet default returns; reject invalid values. Runtime model colour is
// kept in --model-accent so it never overwrites the structural accent roles.
function applyTheme(colors){
  const next=new Set();
  const allowed=new Set(['canvas','sidebar','surface','surfaceRaised','surfaceActive','border','text','textSecondary','textTertiary','accent','accentHot','solid','onSolid']);
  for(const [name,value]of Object.entries(UAI.theme.get()==='game'?(colors||{}):{})){
    if(!allowed.has(name))continue;
    if(typeof value==='string'&&/^#[a-f0-9]{6}$/i.test(value)){document.documentElement.style.setProperty('--'+name,value);next.add(name);}
  }
  for(const name of appliedThemeVars)if(!next.has(name))document.documentElement.style.removeProperty('--'+name);
  appliedThemeVars.clear();for(const n of next)appliedThemeVars.add(n);
  if(/^#[a-f0-9]{6}$/i.test(colors?.canvas||'')){const rgb=colors.canvas.slice(1).match(/../g).map(v=>parseInt(v,16));UAI.theme.game((rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722)<128);}
  const mc=colors?.modelAccent||colors?.['model-accent']||state.agent?.accent||state.agent?.color;
  if(typeof mc==='string'&&/^#[a-f0-9]{6}$/i.test(mc))document.documentElement.style.setProperty('--model-accent',mc);
  else document.documentElement.style.removeProperty('--model-accent');
}
function renderState(){
  applyTheme(state.theme||{});
  const ui=state.settings?.ui||{};
  document.documentElement.style.setProperty('--reading',({narrow:'640px',medium:'780px',wide:'920px'})[ui.transcriptWidth]||'860px');
  document.body.style.fontSize=(14*Math.max(.85,Math.min(1.4,ui.fontScale||1)))+'px';
  document.body.dataset.motion=ui.reduceMotion==='on'?'off':'auto';
  document.body.dataset.reasoning=ui.showReasoning===false?'hidden':'visible';document.body.dataset.density=ui.density||'comfortable';document.body.dataset.codeTheme=ui.codeTheme||UAI.theme.resolved();
  $('playerName').textContent=state.player||'you';$('providerName').textContent=state.agent?.provider||'No provider connected';$('modelLabel').textContent=state.agent?.model||'Select model';$('runtimeBadge').textContent=state.runtime==='web'?'Web · streaming':'Game runtime';
  $('modelButton').setAttribute('aria-label',state.agent?.model?'Select model, current model '+state.agent.model:'Select model');
  $('runtimeBadge').dataset.runtime=state.runtime||'game';$('playerInitial').textContent=(state.player||'U').slice(0,1).toUpperCase();
  const permission=({readonly:'Read only',ask:'Ask first',auto:'Auto',full:'Allow all'})[state.permissions?.mode]||'Ask first';$('permissionBadge').querySelector('span').textContent=permission;
  setBusy(state.agent?.busy);
  renderThreads();renderQuestions();renderStrips();welcome();if($('modal').open)modalRefresh?.();if(page!=='chat')requestPanelRefresh();
}
function renderThreads(){
  const search=$('threadSearch').value.toLowerCase(),root=$('threads'),signature=JSON.stringify([search,state.threads]);
  if(root.dataset.signature===signature)return;root.dataset.signature=signature;
  const focused=document.activeElement?.closest('.thread'),focusId=focused?.dataset.id,menu=document.activeElement?.classList.contains('thread-menu');
  root.replaceChildren();const groups=new Map();
  for(const t of state.threads||[]){if(search&&!String(t.title||'New chat').toLowerCase().includes(search))continue;const group=t.place||'Current game';if(!groups.has(group))groups.set(group,[]);groups.get(group).push(t);}
  for(const [name,list]of groups){root.append(el('div','place-heading',name));for(const thread of list){
    const row=el('div','thread'+(thread.active?' active':''));row.dataset.id=thread.id;
    const open=button((thread.busy?'◌ ':'')+(thread.title||'New chat'),()=>openConversation(thread.id));open.title=thread.title||'New chat';if(thread.active)open.setAttribute('aria-current','true');
    const more=button('···',()=>threadMenu(thread),'thread-menu');more.setAttribute('aria-label','Options for '+(thread.title||'New chat'));row.append(open,more);root.append(row);
    if(thread.id===focusId)(menu?more:open).focus({preventScroll:true});
  }}
  if(!groups.size)root.append(el('p','history-empty',search?'No matching conversations.':'Your conversations will appear here.'));
}
function threadMenu(thread){modal(thread.title||'Conversation',root=>{const name=field(root,'Title',thread.title);const del=button('Delete',()=>{},'danger');armButton(del,'Confirm delete?',()=>modalCommand('thread:delete',{id:thread.id}));root.append(button('Rename',()=>modalCommand('thread:rename',{id:thread.id,title:name.value})),button(thread.ephemeral?'Save conversation':'Make isolated',()=>modalCommand('thread:isolate',{sessionId:thread.id,value:!(state.threads?.find(t=>t.id===thread.id)||thread).ephemeral})),del);});}
function renderStrips(){
  const todos=state.todos||[],root=$('taskStrip'),signature=JSON.stringify([sessionId,todos]);root.hidden=!todos.length;
  if(root.dataset.signature!==signature){
    let details=root.querySelector('details');
    if(!details){details=el('details');details.append(el('summary'),el('div','task-list'));root.append(details);}
    if(root.dataset.session!==sessionId)details.open=false;
    details.querySelector('summary').textContent=`${todos.filter(t=>t.status==='done').length}/${todos.length} tasks completed`;
    details.querySelector('.task-list').replaceChildren(...todos.map(t=>el('div',null,`${t.status==='done'?'✓':'○'} ${t.text}`)));
    root.dataset.signature=signature;root.dataset.session=sessionId||'';
  }
  const loops=(state.loops||[]).filter(l=>l.state==='running'),strip=$('loopStrip');strip.hidden=!loops.length;
  if(!strip.children.length)strip.append(button('',()=>show('loops')),button('Stop all',()=>action('loops:stop',{id:'all'}),'danger'));
  strip.firstElementChild.textContent=`${loops.length} chat loop(s) running`;
}
function renderQuestions(){
  const root=$('questions'),entries=[...(state.pendingPermissions||[]).map(req=>({type:'permission',req})),...(state.questions||[]).map(req=>({type:'question',req}))];
  for(const entry of entries){const req=entry.req;entry.key=entry.type+':'+req.id;entry.context=req.sessionTitle||state.threads?.find(t=>t.id===req.sessionId)?.title||req.sessionId||'Current conversation';}
  const signature=JSON.stringify(entries);if(root.dataset.signature===signature)return;root.dataset.signature=signature;
  const focused=root.contains(document.activeElement)?document.activeElement:null,selection=focused&&typeof focused.selectionStart==='number'?[focused.selectionStart,focused.selectionEnd,focused.selectionDirection]:null;
  const existing=new Map([...root.children].map(card=>[card.dataset.requestKey,card])),keys=new Set(entries.map(entry=>entry.key));
  for(const [key,card]of existing)if(!keys.has(key))card.remove();
  entries.forEach(({type,req,key,context},index)=>{
    let card=existing.get(key);
    if(!card){
      card=el('section','question');card.dataset.requestKey=key;
      const title=el('strong'),caption=el('small','question-context');title.id='request-title-'+uuid();caption.id=title.id+'-context';
      card.setAttribute('aria-labelledby',title.id);card.setAttribute('aria-describedby',caption.id);card.append(title,caption);card._title=title;card._context=caption;
      if(type==='permission'){
        const args=el('pre');args.tabIndex=0;card._args=args;card.append(args);
        const remember=el('input');remember.type='checkbox';const label=el('label',null,'Remember this decision');label.prepend(remember);
        const row=el('div','row');
        for(const allowed of [true,false])row.append(button(allowed?'Allow':'Deny',()=>{const current=card._request;return action('permission',{id:current.id,allow:allowed,remember:remember.checked,...(current.sessionId?{sessionId:current.sessionId}:{})});},allowed?'primary':'danger'));
        row.append(label);card.append(row);
      }else{
        const form=el('form','row'),options=el('div','row question-options'),input=el('input'),send=el('button','primary','Send');input.type='text';input.required=true;input.placeholder='Or type an answer';input.setAttribute('aria-labelledby',title.id);input.setAttribute('aria-describedby',caption.id);send.type='submit';
        form.onsubmit=event=>{event.preventDefault();action('ask:answer',{id:card._request.id,text:input.value});};
        form.append(options,input,send,button('Dismiss',()=>action('ask:answer',{id:card._request.id,text:''})));card.append(form);card._options=options;
      }
    }
    card._request=req;card._title.textContent=type==='permission'?'Allow '+req.name+'?':req.question;card._context.textContent='Conversation: '+context;
    if(type==='permission'){card._args.textContent=JSON.stringify(req.args||{},null,2);card._args.setAttribute('aria-label','Arguments for '+req.name);}
    else{const optionsSignature=JSON.stringify(req.options||[]);if(card._options.dataset.signature!==optionsSignature){card._options.replaceChildren(...(req.options||[]).map(option=>button(option,()=>action('ask:answer',{id:card._request.id,text:option}))));card._options.dataset.signature=optionsSignature;}}
    if(root.children[index]!==card)root.insertBefore(card,root.children[index]||null);
  });
  if(focused){const target=focused.isConnected?focused:root.querySelector('button,input,[tabindex="0"]')||$('input');if(document.activeElement!==target)target.focus({preventScroll:true});if(selection&&target===focused)focused.setSelectionRange(...selection);}
}
function show(next){page=next;document.body.dataset.page=page;closeSidebar();$('chatPage').hidden=page!=='chat';$('panel').hidden=page==='chat';$('pageTitle').textContent=({chat:'Chat',cowork:'Cowork',agents:'Subagents',providers:'Providers',tools:'Tools',loops:'Chat loops',logs:'Logs & traces',memory:'Memory & skills',settings:'Settings'})[page]||page;document.querySelectorAll('button[data-page]').forEach(b=>{b.classList.toggle('selected',b.dataset.page===page);if(b.dataset.page===page)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});if(page==='chat'){welcome();resizeComposer();}else{renderPanel();$('panel').classList.remove('panel-enter');requestAnimationFrame(()=>$('panel').classList.add('panel-enter'));}refresh();(page==='chat'?$('input'):$('panel')).focus({preventScroll:true});}
async function openConversation(id){
  try{await command(id?'thread':'thread:new',id?{id}:{});show('chat');}catch(error){toast(error.message);}
}
function heading(root,title,control){const h=el('div','panel-heading');h.append(el('h1',null,title));if(control)h.append(control);root.append(h);}
function card(root,title){const n=el('section','card');if(title)n.append(el('h3',null,title));root.append(n);return n;}
let toolFilter='';
function buildPanel(root){root.replaceChildren();
  if(page==='memory'){heading(root,'Memory & skills');const list=el('div','tool-grid');root.append(list);for(const tool of state.tools||[]){if(tool.name.startsWith('memory_')||tool.name.startsWith('skills_')){const c=card(list,tool.name);c.append(el('p','muted',tool.description),button('Open',()=>runTool(tool.name),'outline'));}}return;}
  if(page==='cowork'){renderCowork(root);}
  else if(page==='providers'){
    heading(root,'Providers',button('＋ Add provider',()=>providerEditor(),'outline','provider:add'));
    for(const p of state.providers||[]){const c=card(root,p.label),row=el('div','row'),use=button(state.activeProvider===p.id?'Active':'Use',()=>action('provider',{id:p.id}),null,'provider:'+p.id+':use');use.setAttribute('aria-pressed',String(state.activeProvider===p.id));row.append(el('span','muted',p.baseUrl||''),el('span','spacer'),use,button('Edit',()=>providerEditor(p),null,'provider:'+p.id+':edit'));c.append(row,el('p',null,p.model||'No model selected'),el('small',null,`${p.health?.ok||0} successful · ${p.health?.fail||0} failed`));if(p.health?.lastError)c.append(el('p','danger',p.health.lastError));}
  }
  else if(page==='tools'){const filter=el('input');filter.placeholder='Search tools…';filter.setAttribute('aria-label','Search tools');filter.value=toolFilter;filter.oninput=()=>{toolFilter=filter.value;renderToolCards(list);};heading(root,'Tools',filter);const list=el('div','tool-grid');root.append(list);renderToolCards(list);}
  else if(page==='agents'){heading(root,'Subagents');for(const a of state.subagents||[]){const c=card(root,a.label||a.id);c.append(el('p',null,a.task),el('small',null,a.status));if(a.report)c.append(el('pre','json-output',a.report));if(['running','queued'].includes(a.status))c.append(button('Stop',()=>action('subagent:stop',{id:a.id}),'danger'));}if(!state.subagents?.length)root.append(el('p','muted','Dispatch a subagent from chat to see its progress here.'));}
  else if(page==='loops'){heading(root,'Chat loops',button('Start chatbot',()=>runTool('chat_bot',{instructions:'Be friendly, casual, and helpful.'}),'outline'));for(const l of state.loops||[]){const c=card(root,`${l.kind==='bot'?'Chatbot':l.kind} · ${l.channel}`);c.append(el('p',null,`${l.state} · ${l.sent}/${l.count} sent`));if(l.reason)c.append(el('small',null,l.reason));for(const score of Object.values(l.scores||{}))c.append(el('div',null,`${score.name}: ${score.points}`));if(l.state==='running')c.append(button('Stop',()=>action('loops:stop',{id:l.id}),'danger'));}const row=el('div','row');for(const name of ['quiz_bot','auto_chat','auto_reply'])row.append(button(name,()=>runTool(name)));root.append(row);}
  else if(page==='logs'){heading(root,'Logs & traces',button('Clear logs',()=>action('logs:clear')));for(const r of [...(state.requests||[])].reverse()){const c=card(root,`${r.status||'Error'} · ${r.tag||r.method} · ${r.ms||0} ms`);c.append(el('small',null,`${r.via||''} · ${r.url||''}`));if(r.error)c.append(el('p','danger',r.error));}for(const entry of [...(state.logs||[])].reverse())root.append(el('pre','json-output',typeof entry==='string'?entry:JSON.stringify(entry)));}
  else if(page==='settings'){renderSettings(root);}
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
function providerEditor(provider){modal(provider?'Edit provider':'Add provider',root=>{const form=el('div','form-grid');root.append(form);const preset=select(form,'Preset',(state.presets||[]).map(p=>[p.id,p.label]),provider?.preset||'custom');const label=field(form,'Name',provider?.label||''),url=field(form,'Base URL',provider?.baseUrl||''),apiStyle=select(form,'API',['openai','anthropic'],provider?.api||'openai'),auth=select(form,'Authentication',['bearer','api-key','none'],provider?.authStyle||'bearer'),key=field(form,provider?.hasKey?'API key (blank keeps current key)':'API key','','password'),model=field(form,'Model',provider?.model||'');preset.onchange=()=>{const p=state.presets?.find(p=>p.id===preset.value);if(p){label.value=p.label||'';url.value=p.baseUrl||'';apiStyle.value=p.api||'openai';auth.value=p.authStyle||'bearer';}};root.append(button('Save',async()=>{const fields={id:provider?.id,preset:preset.value,label:label.value,baseUrl:url.value,api:apiStyle.value,authStyle:auth.value,model:model.value};if(key.value)fields.apiKey=key.value;try{await command('provider:save',{provider:fields});$('modal').close();}catch(e){toast(e.message);}},'primary'));if(provider){const del=button('Delete',()=>{},'danger');armButton(del,'Confirm delete?',()=>modalCommand('provider:remove',{id:provider.id}));root.append(del);}});}
function models(){modal('Models',root=>{
  const provider=select(root,'Provider',(state.providers||[]).map(p=>[p.id,p.label]),state.activeProvider),search=field(root,'Search models','');
  const freeLabel=el('label','row'),free=el('input');free.type='checkbox';freeLabel.append(free,document.createTextNode('Free only'));root.append(freeLabel);
  const list=el('div','model-list');root.append(list);
  function paint(){
    const p=state.providers?.find(p=>p.id===provider.value),ids=(p?.models||[]).filter(id=>id.toLowerCase().includes(search.value.toLowerCase())&&(!free.checked||/free|big-pickle/i.test(id)));
    const focused=list.contains(document.activeElement)?document.activeElement:null,existing=new Map([...list.children].map(n=>[n.dataset.model,n])),wanted=new Set(ids);
    for(const [id,node]of existing)if(!wanted.has(id))node.remove();
    ids.forEach((id,index)=>{const node=existing.get(id)||button(id,()=>action('model',{provider:provider.value,model:id}));node.dataset.model=id;node.classList.toggle('selected',p.model===id);node.setAttribute('aria-pressed',String(p.model===id));if(list.children[index]!==node)list.insertBefore(node,list.children[index]||null);});
    if(focused&&document.activeElement!==focused)(focused.isConnected?focused:search).focus({preventScroll:true});
  }
  provider.onchange=paint;search.oninput=paint;free.onchange=paint;paint();
  const effort=select(root,'Reasoning effort',['low','medium','high','xhigh','max'],state.settings?.agent?.effort||'high');effort.onchange=()=>action('setting',{path:'agent.effort',value:effort.value});
  modalRefresh=()=>{paint();if(document.activeElement!==effort)effort.value=state.settings?.agent?.effort||'high';};
  root.append(button('Refresh models',async()=>{try{await command('models:discover',{provider:provider.value});paint();toast('Model discovery requested. The list updates when ready.');}catch(error){toast(error.message);}}),button('Manage providers',()=>{$('modal').close();show('providers');}));
});}
function emptyState(root,symbol,title,detail,control){const n=el('section','empty-state');n.append(icon(symbol),el('h2',null,title),el('p',null,detail));if(control)n.append(control);root.append(n);}
function panelIsEditing(){
  if($('modal').open||panelPointerActive)return true;
  const root=$('panel'),active=document.activeElement;if(root.querySelector('.setting[data-state="saving"]')||(root.contains(active)&&active.matches('input,textarea,select')))return true;
  const selection=document.getSelection();return !!selection&&!selection.isCollapsed&&(root.contains(selection.anchorNode)||root.contains(selection.focusNode));
}
function requestPanelRefresh(){panelRefreshPending=true;flushPanelRefresh();}
function flushPanelRefresh(){if(panelRefreshPending&&page!=='chat'&&!$('app').hidden&&!panelIsEditing())renderPanel();}
function renderPanel(){
  const root=$('panel'),position=root.scrollTop,active=root.contains(document.activeElement)?document.activeElement:null,focusKey=active?.dataset.focusKey,open=new Set([...root.querySelectorAll('details[open]')].map(d=>d.querySelector('summary')?.textContent));panelRefreshPending=false;
  const errors=new Map([...root.querySelectorAll('.setting[data-state="error"]')].map(row=>{const input=row.querySelector('[data-setting]');return [input.dataset.setting,{value:input.value,checked:input.checked,message:row.querySelector('.save-status').textContent}];}));
  buildPanel(root);
  for(const input of root.querySelectorAll('[data-setting]')){const error=errors.get(input.dataset.setting);if(error){input.value=error.value;if(input.type==='checkbox')input.checked=error.checked;const row=input.closest('.setting');row.dataset.state='error';row.querySelector('.save-status').textContent=error.message;}}
  if(page==='providers'){
    if(!state.providers?.length)emptyState(root,'providers','Choose who you think with.','Connect an AI provider and choose a model to start working in your game.',button('Add provider',()=>providerEditor(),'primary'));
    else{const c=card(root,'Check your connection');c.append(el('p','muted','Send a small test request to check each provider.'));for(const p of state.providers)c.append(button('Test '+p.label,async()=>{try{const result=await command('provider:test',{id:p.id});toast(result.text+' · '+result.ms+' ms');}catch(e){toast(e.message);}},'outline'));}
  }
  if(page==='agents'&&!state.subagents?.length){root.querySelector(':scope > p')?.remove();emptyState(root,'agents','Extra hands, when you need them.','Ask UAI to split a larger task into smaller parts. Your subagents and their progress will appear here.',button('Back to chat',()=>show('chat'),'outline'));}
  if(page==='memory'&&!root.querySelector('.tool-grid .card'))emptyState(root,'memory','A place for what matters.','Connect your game to see the memory and skill tools available in this workspace.');
  if(page==='tools'&&!state.tools?.length)emptyState(root,'tools','Your game’s tools, within reach.','Connect Roblox to browse available tools, review permissions, and run an action.');
  if(page==='logs'&&!state.logs?.length&&!state.requests?.length)emptyState(root,'logs','A clear view of your activity.','Connection checks, requests, and diagnostic messages will appear here as you work.');
  if(page==='loops'&&!state.loops?.length)emptyState(root,'loop','Keep the conversation going.','Start a chatbot or use the chat tools above. Running loops and their Stop controls appear here.');
  for(const details of root.querySelectorAll('details'))if(open.has(details.querySelector('summary')?.textContent))details.open=true;
  for(const control of root.querySelectorAll('button,summary'))if(!control.dataset.focusKey){const scope=control.closest('.card,.setup-step,.setup-faq details,.panel-heading,.empty-state')||root,heading=scope.querySelector('h1,h2,summary,h3')?.textContent||scope.className,index=[...scope.querySelectorAll('button,summary')].indexOf(control);control.dataset.focusKey='panel:'+page+':'+heading+':'+index;}
  if(active){const replacement=focusKey&&[...root.querySelectorAll('[data-focus-key]')].find(n=>n.dataset.focusKey===focusKey);(replacement&&!replacement.disabled?replacement:root).focus({preventScroll:true});}
  root.scrollTop=position;
}

let installSource=stored('localStorage','uai.installSource')||'executor';
function renderCowork(root){
  const title=el('div','setup-heading');title.append(el('span','eyebrow','COWORK / YOUR LOCAL BRIDGE'),el('h1',null,connected?'Your workspace is connected.':'A clear path to your game.'),el('p',null,connected?'You’re ready. Keep Roblox and your bridge terminal open, then make yourself at home.':'The bridge connects this browser to UAI in Roblox. Set it up once, then pick up the same conversation in either window.'));root.append(title);
  const path=el('div','connection-path');path.setAttribute('aria-label','Browser, bridge, and Roblox connection status');
  for(const [name,detail,symbol,ready]of [['This browser','Open and ready','chat',true],['Local bridge',link==='online'?'Running on port '+location.port:'Reconnecting…','bridge',link==='online'],['Roblox',connected?(state.place?.name||'Connected'):'Waiting to connect','player',connected]]){
    const n=el('div','connection-node');n.dataset.ready=String(ready);const glyph=el('span','connection-symbol');glyph.append(icon(symbol));const copy=el('div');copy.append(el('strong',null,name),el('small',null,detail));n.append(glyph,copy);path.append(n);
  }root.append(path,el('h2','section-heading','Three steps to start'));
  const steps=el('div','setup-steps');root.append(steps);
  function step(number,title,complete){const n=el('section','setup-step');n.dataset.complete=String(complete);n.append(el('span','step-number',complete?'✓':String(number)),el('h3',null,title));steps.append(n);return n;}
  const one=step(1,'Start the bridge',link==='online');
  one.append(el('p',null,'Install Node.js 18+ on this computer. Download the bridge in Roblox → UAI → Cowork, then open a terminal in your executor workspace.'));
  const source=select(one,'Your installation',[['executor','Downloaded in Roblox'],['repo','Git checkout']],installSource);
  const code=el('code',null,installSource==='repo'?'node bridge/server.js':'node UAI/bridge/start.txt');
  source.onchange=()=>{installSource=source.value;code.textContent=installSource==='repo'?'node bridge/server.js':'node UAI/bridge/start.txt';try{localStorage.setItem('uai.installSource',installSource);}catch{}};
  one.append(code,button('Copy start command',()=>copyText(code.textContent),'outline'),el('small','setup-detail','Keep this terminal open. No npm install or file renaming needed.'));
  const two=step(2,'Connect Roblox',connected);
  two.append(el('p',null,'In Roblox, open UAI → Cowork. Paste the bridge token, set the port below, then turn Enabled on.'),el('code',null,'Port '+location.port),button('Copy bridge token',()=>copyText(token),'outline'),el('small','setup-detail','The token is the long code from the terminal. It changes whenever the bridge restarts.'));
  const three=step(3,'Open your workspace',connected);
  three.append(el('p',null,'Open the browser link printed by the terminal. Choose a provider and model, then send your first message. Your game stays in control of tools and permissions.'));
  three.append(button(connected?'Open chat →':'Check connection',async()=>{if(connected){show('chat');$('input').focus();return;}try{const hello=await api('/hello');connected=!!hello.connected;refresh();renderPanel();if(!connected)toast('Still waiting. Paste the token into Roblox’s Cowork panel and turn Enabled on.');}catch(e){toast(e.message);}},connected?'primary':'outline'));
  three.append(el('small','setup-detail',connected?'Browser and Roblox share the active conversation.':'Your connection status updates automatically.'));
  root.append(el('h2','section-heading','Choose how responses arrive'));
  const modes=el('div','runtime-options');
  for(const [value,name,badge,copy]of [['web','Web runtime','LIVE IN YOUR BROWSER','Get responses as they arrive when your provider supports streaming. Roblox still runs your tools and saves the conversation.'],['game','Game runtime','DIRECT FROM ROBLOX','Use the provider connection from your game. The browser shows the response once Roblox receives it.']]){
    const n=button('',()=>action('runtime',{value}),'runtime-option'+(state.runtime===value?' selected':''),'runtime:'+value);n.setAttribute('aria-pressed',String(state.runtime===value));n.setAttribute('aria-label',name);n.disabled=!connected||busy||state.subagents?.some(a=>a.status==='running')||state.loops?.some(l=>l.state==='running');const head=el('div');head.append(el('strong',null,name),el('span','pill',badge));n.append(head,el('p',null,copy));modes.append(n);
  }root.append(modes,el('p','runtime-note','Switch modes when work is idle. Keep both Roblox and the bridge running in either mode.'));
  const usage=card(root,'This session');usage.classList.add('metrics');usage.append(metric(state.usage?.total||0,state.usage?.estimated?'Tokens · estimated':'Tokens'),metric(state.usage?.requests||0,'Requests'),metric('$'+(state.usage?.cost||0).toFixed(4),'Estimated cost'));
  const faq=el('div','setup-faq');
  for(const [question,answer]of [
    ['Roblox is still waiting to connect','Keep Roblox and the terminal open on the same computer. Match the port shown above, paste the latest token, and turn Enabled on in UAI → Cowork. After a bridge restart, both windows need the new token.'],
    ['Node or the start file cannot be found','Install Node.js, then reopen your terminal. Open it in your executor’s workspace folder—the one containing UAI. If you downloaded this repository instead, choose Git checkout in step 1 and run its command from the repository folder.'],
    ['Can the AI see attached pictures?','Not yet. PNG, JPEG, and WebP pictures are local previews. The game receives a [PICTURE] text marker. Describe the parts that matter in your message. Text and code attachments can be read by the AI.'],
    ['What happens if I refresh or close the browser?','Refreshing reconnects to the conversation. Drafts are saved in this browser when storage is available. Closing the browser does not stop work in Roblox. Use Stop to cancel a turn. Pictures expire after 15 minutes of inactivity and are cleared when the bridge stops.']
  ]){const detail=el('details');detail.append(el('summary',null,question),el('p',null,answer));faq.append(detail);}root.append(faq);
  const advanced=el('details','card');advanced.append(el('summary',null,'Advanced connection settings'));
  const timeout=field(advanced,'Provider timeout in seconds',state.relayTimeout||180,'number');timeout.min=10;timeout.max=86400;timeout.step=1;
  timeout.onchange=()=>{if(timeout.reportValidity())action('setting',{path:'bridge.requestTimeout',value:Number(timeout.value)});};
  advanced.append(el('small','setup-detail','How long Web runtime waits for a provider response. The default is 180 seconds. Stop cancels it immediately.'));root.append(advanced);
}

// Mirrors the choices enforced by net/bridge_commands.lua for protocol-2 clients.
const SETTING_CHOICES={
  'ui.density':['comfortable','compact'],'ui.accent':['claude','aurora','indigo','amber','rose'],
  'ui.reduceMotion':[['auto','Follow system'],['on','Reduce motion'],['off','Normal motion']],
  'ui.layout':['auto','sheet','panel','window','tv'],'ui.codeTheme':['dark','light'],'ui.transcriptWidth':['narrow','medium','wide'],
  'iy.mode':['off','hidden','visible'],'agent.effort':['low','medium','high','xhigh','max']
};
const SETTING_RANGES={'ui.fontScale':[.85,1.4,.05],'agent.temperature':[0,2,.1],'agent.toolConcurrency':[1,8,1],
  'agent.maxTurns':[1,1000,1],'agent.toolTimeout':[1,86400,1],'agent.requestTimeout':[1,86400,1],'agent.retries':[1,10,1],
  'agent.contextTokens':[1000,2000000,1],'agent.contextFraction':[.3,.95,.05],'agent.maxTokens':[1,1000000,1]};
function renderSettings(root){
  heading(root,'Make it yours');root.append(el('p','panel-description','Appearance for this browser, and the settings shared with your Roblox workspace.'));
  const appearance=card(root,'Browser appearance');
  const theme=select(appearance,'Theme',[['system','Follow this computer'],['light','Light'],['dark','Dark'],['game','Match Roblox']],UAI.theme.get());theme.onchange=()=>UAI.theme.set(theme.value);
  appearance.append(el('small','setup-detail','Saved in this browser. Match Roblox uses your game’s palette.'));
  const permissions=card(root,'Permissions'),modes=el('div','segments');
  for(const [mode,name]of [['readonly','Read only'],['ask','Ask first'],['auto','Auto'],['full','Allow all']]){const n=button(name,()=>action('permission-mode',{mode}),state.permissions?.mode===mode?'selected':'','permission:'+mode);n.setAttribute('aria-pressed',String(state.permissions?.mode===mode));n.disabled=!connected;modes.append(n);}permissions.append(modes,el('small','setup-detail','Ask first lets you review actions that change your game.'));
  for(const [section,values]of Object.entries(state.settings||{})){
    const details=el('details','card');details.append(el('summary',null,({ui:'Workspace appearance',agent:'Agent behavior',logs:'Logging',iy:'Infinite Yield',identity:'Provider identity'})[section]||section));
    for(const [key,value]of Object.entries(values)){
      if(['lastSeenVersion','lastSeenChangelog','panel'].includes(key)||typeof value==='object')continue;
      const path=section+'.'+key,row=el('label','setting'),caption=el('span',null,key.replace(/([A-Z])/g,' $1').replace(/^./,c=>c.toUpperCase())),status=el('small','save-status');status.setAttribute('aria-live','polite');caption.append(status);row.append(caption);
      let input;
      if(typeof value==='boolean'){input=el('input');input.type='checkbox';input.checked=value;}
      else if(SETTING_CHOICES[path]){input=el('select');for(const item of SETTING_CHOICES[path]){const [id,title]=Array.isArray(item)?item:[item,item[0].toUpperCase()+item.slice(1)];const option=el('option',null,title);option.value=id;input.append(option);}input.value=value;}
      else{input=el(key==='customInstructions'?'textarea':'input');if(input.tagName==='INPUT')input.type=typeof value==='number'?'number':'text';input.value=value;if(typeof value==='number'){const [min,max,step]=SETTING_RANGES[path]||[0,10000000,1];input.min=min;input.max=max;input.step=step;}else input.maxLength=16000;}
      input.dataset.setting=path;input.disabled=!connected;
      let saveVersion=0;
      input.onchange=async()=>{
        const version=++saveVersion;
        if(!input.reportValidity()){status.textContent=input.validationMessage;row.dataset.state='error';return;}
        status.textContent='Saving…';row.dataset.state='saving';
        try{await command('setting',{path,value:typeof value==='boolean'?input.checked:typeof value==='number'?Number(input.value):input.value});if(version===saveVersion){status.textContent='Saved';row.dataset.state='saved';}}
        catch(e){if(version===saveVersion){status.textContent=e.message;row.dataset.state='error';toast(e.message);}}
        finally{queueMicrotask(flushPanelRefresh);}
      };
      row.append(input);details.append(row);
    }root.append(details);
  }
  const extras=card(root,'Configuration');extras.append(el('p','muted','A full configuration export includes your API keys. Keep the downloaded file private.'));
  const row=el('div','row');row.append(button('Export full config',async()=>{try{const data=await command('config:export');download('uai-config.json',data.text,'application/json');}catch(e){toast(e.message);}},'outline'),button('Import full config',()=>modal('Import configuration',body=>{body.append(el('p','muted','This replaces your current configuration. Stop running work before importing.'));const input=field(body,'Paste configuration JSON','','textarea');body.append(button('Import configuration',async()=>{try{await command('config:import',{text:input.value});$('modal').close();toast('Configuration imported');}catch(e){toast(e.message);}},'primary'));}),'outline'));extras.append(row);
}
async function submit(){
  if(sending||sendPhase!=='idle'||readingFiles||draftLoads.has(sessionId)||busy||!connected)return;
  const text=$('input').value;
  const pictureIds=UAI.pictures.ids();
  if(!text.trim()&&!uploads.length&&!pictureIds.length)return;
  if(UAI.pictures.busy()){toast('Wait for pictures to finish uploading.');return;}
  if(UAI.pictures.hasErrors()){toast('Retry or remove the picture that could not be attached.');return;}
  const encode=new TextEncoder(),max=state.attachments?.maxBytes||2*1024*1024;
  if(encode.encode(text).length>max){toast('This message exceeds 2 MiB. Split it into smaller files.');return;}
  if(draftBytes(text,uploads)>MAX_DRAFT_BYTES){toast('Use up to 8 MiB of text and code per message.');return;}
  saveDraft();
  const original=text,files=uploads.slice(),sentSession=sessionId;
  const operation={sessionId:sentSession,commandId:uuid(),sawTurn:false,instance,createdAt:Date.now(),sentVersion:drafts[sentSession]?.version,fileIds:files.map(f=>f.id)};
  sendOperation=operation;
  sending=true;setPhase('submitting');
  try{
    const limit=state.attachments?.inlineLimit||8000;
    const parts=[],references=[];
    const attach=async(text,name)=>{setPhase('uploading');const file=await uploadText(text,name,sentSession);references.push({path:file.path,bytes:file.bytes});return file.reference;};
    if(encode.encode(text).length>limit)parts.push(await attach(text,'pasted-input.txt'),'Read the file for the complete user input, including any request at the end.');
    else if(text.trim())parts.push(text.trim());
    else if(!pictureIds.length)parts.push('Please read the attached input.');
    for(const file of files){
      if(encode.encode(file.text).length>limit)parts.push(await attach(file.text,file.name));
      else parts.push(`[Attached: ${file.name}]\n${file.text}`);
    }
    setPhase('submitting');
    const fields={text:parts.join('\n\n'),files:references,sessionId:sentSession,commandId:operation.commandId};
    if(pictureIds.length)fields.pictureIds=pictureIds;
    lastSend={text:original,files,sessionId:sentSession};
    // Correlate before POST: the game can emit its user event before the receipt.
    if(pictureIds.length)UAI.pictures.attachToCommand(operation.commandId,pictureIds);
    operation.submitted=true;persistOperation();
    await command('send',fields);
    await clearSentDraft(operation);forgetOperation();armAwaitTurn(operation);
  }catch(e){
    toast(e.message);
    if(operation.submitted&&e.uncertain){setPhase('uncertain');persistOperation();}
    else{UAI.pictures.releaseCommand(operation.commandId);forgetOperation();setPhase('idle');}
  }
  finally{sending=false;refresh();}
}
function persistOperation(){try{sessionStorage.setItem('uai.pendingSend',JSON.stringify(sendOperation));}catch{}}
function forgetOperation(){sendOperation=null;try{sessionStorage.removeItem('uai.pendingSend');}catch{}}
async function clearSentDraft(operation){
  await draftLoads.get(operation.sessionId);
  if(sessionId===operation.sessionId)saveDraft();
  const current=drafts[operation.sessionId]||await UAI.drafts.load(operation.sessionId)||{},sentIds=new Set(operation.fileIds||[]);
  const clear=current.version===operation.sentVersion;
  drafts[operation.sessionId]={...current,text:clear?'':current.text||'',textLength:clear?0:(current.text||'').length,version:(current.version||0)+(clear?1:0),uploads:(current.uploads||[]).filter(f=>!sentIds.has(f.id)),updatedAt:Date.now()};
  dirtyDrafts.add(operation.sessionId);
  if(sessionId===operation.sessionId){$('input').value=drafts[sessionId].text;uploads=drafts[sessionId].uploads.slice();renderAttachments();resizeComposer();}
  persistDrafts();
}
async function checkDelivery(){
  const operation=sendOperation;if(!operation||sending)return;
  $('deliveryCheck').disabled=true;
  try{
    if(operation.instance!==instance){operation.lost=true;toast('The bridge restarted. Review the conversation before sending this draft again.');return;}
    const receipt=await api('/commands/'+operation.commandId);
    if(['queued','running'].includes(receipt.state)){toast('Roblox is still processing this message. Keep the game and bridge open.');return;}
    if(receipt.result?.uncertain){operation.lost=true;toast(receipt.result.error);return;}
    if(receipt.result?.ok===false){UAI.pictures.releaseCommand(operation.commandId);forgetOperation();setPhase('idle');toast(receipt.result.error||'Message was not delivered. Your draft was kept.');return;}
    await clearSentDraft(operation);forgetOperation();setPhase('idle');toast('Message delivered.');
  }catch(e){if(e.status===404){operation.lost=true;toast('The receipt is no longer available. Review the conversation before sending again.');}else toast(e.message);}
  finally{if(sendOperation)persistOperation();$('deliveryCheck').disabled=false;refresh();}
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
  if(window.UAI&&UAI.pictures&&UAI.pictures.handlePaste(event))return;
  const text=event.clipboardData?.getData('text/plain');
  if(!text||!sessionId||new TextEncoder().encode(text).length<=(state.attachments?.inlineLimit||8000))return;
  event.preventDefault();
  if(new TextEncoder().encode(text).length>(state.attachments?.maxBytes||2*1024*1024)){toast('This paste exceeds 2 MiB. Split it into smaller files.');return;}
  if(uploads.length>=16||draftBytes($('input').value,uploads)+new TextEncoder().encode(text).length>MAX_DRAFT_BYTES){toast('Use up to 16 text files and 8 MiB per message.');return;}
  const input=$('input');input.setRangeText('',input.selectionStart,input.selectionEnd,'end');
  uploads.push({id:uuid(),name:'pasted-input.txt',text});renderAttachments();grow();
}
function draftBytes(text,files){const encode=new TextEncoder();return encode.encode(text||'').length+(files||[]).reduce((sum,f)=>sum+encode.encode(f.text||'').length,0);}
async function attachFiles(source){
  const selected=Array.isArray(source)?source:Array.from($('fileInput').files),target=sessionId;
  $('fileInput').value='';
  if(!target){toast('Connect to Roblox before attaching files.');return;}
  saveDraft();
  readingFiles++;refresh();
  try{for(const file of selected.slice(0,16)){
    if(file.size>(state.attachments?.maxBytes||2*1024*1024)){toast(file.name+' exceeds 2 MiB');continue;}
    if(/^(image|audio|video)\//.test(file.type)){toast(file.name+': attach a text or code file.');continue;}
    try{
      const text=await file.text();
      if(text.includes('\0')){toast(file.name+': binary files are not supported.');continue;}
      const draft=sessionId===target?{text:$('input').value,uploads}:drafts[target]||{};
      if((draft.uploads?.length||0)>=16||draftBytes(draft.text,draft.uploads)+new TextEncoder().encode(text).length>MAX_DRAFT_BYTES){toast('Use up to 16 text files and 8 MiB per message.');break;}
      const item={id:uuid(),name:file.name,text};
      if(sessionId===target){uploads.push(item);renderAttachments();saveDraft();setBusy(busy);}
      else{const previous=drafts[target]||{text:'',version:0,uploads:[]};drafts[target]={...previous,uploads:[...(previous.uploads||[]),item],updatedAt:Date.now()};dirtyDrafts.add(target);persistDrafts();}
    }catch(err){toast('Could not read '+file.name+': '+err.message);}
  }}finally{readingFiles--;refresh();}
}
function download(name,text,type){const url=URL.createObjectURL(new Blob([text],{type}));const a=el('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
$('send').onclick=submit;$('stop').onclick=async()=>{if(sendPhase==='stopping')return;setPhase('stopping');try{await command('abort');}catch(e){toast(e.message);}finally{setPhase(sendOperation?.submitted?'uncertain':'idle');}};armButton($('clear'),'Confirm clear',()=>action('clear'));
$('input').oninput=grow;
$('input').onpaste=pasteInput;
$('input').onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing&&e.keyCode!==229){e.preventDefault();submit();}};
$('newThread').onclick=$('newConversation').onclick=()=>openConversation();$('modelButton').onclick=models;
$('attach').onclick=()=>$('fileInput').click();$('fileInput').onchange=attachFiles;
$('attachPictures').onclick=()=>{if(window.UAI&&UAI.pictures)UAI.pictures.openPicker();};
$('themeToggle').onclick=()=>{if(window.UAI&&UAI.theme)UAI.theme.toggle();};
$('setupHelp').onclick=$('connectionAction').onclick=()=>show('cowork');
$('permissionBadge').onclick=()=>show('settings');
$('deliveryCheck').onclick=checkDelivery;
$('deliveryReview').onclick=()=>{const operation=sendOperation;if(!operation?.lost)return;UAI.pictures.releaseCommand(operation.commandId);forgetOperation();setPhase('idle');show('chat');$('input').focus();toast('Draft kept. Check the conversation before sending it again.');};
$('sidebarOverlay').onclick=()=>closeSidebar(true);
$('options').onclick=()=>modal('Conversation options',root=>{root.className='stack';root.append(button('Model and effort',models),button('Permissions',()=>{$('modal').close();show('settings');}),button('Chat loops',()=>{$('modal').close();show('loops');}));for(const [title,,prompt]of starters)root.append(button(title,()=>{$('modal').close();insert(prompt);}));root.append(button('Export JSON',()=>download('uai-events.json',JSON.stringify({events,pictures:UAI.pictures.manifest(),pictureNote:'Picture metadata only. Image bytes are not included or sent to the AI.'},null,2),'application/json')));});
$('sidebarToggle').onclick=()=>{const mobile=innerWidth<=768;document.body.classList.toggle(mobile?'sidebar-open':'sidebar-hidden');syncSidebar();if(mobile&&document.body.classList.contains('sidebar-open'))$('closeSidebar').focus();};
document.addEventListener('keydown',e=>{
  if(innerWidth>768||!document.body.classList.contains('sidebar-open')||$('modal').open)return;
  if(e.key==='Escape'){e.preventDefault();closeSidebar(true);}
  if(e.key==='Tab'){
    const focusable=[...$('sidebar').querySelectorAll('button,input,summary,a[href]')].filter(n=>!n.disabled&&!n.hidden&&n.getClientRects().length&&getComputedStyle(n).visibility!=='hidden');
    const first=focusable[0],last=focusable.at(-1);
    if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}
    else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}
  }
});
$('closeSidebar').onclick=()=>closeSidebar(true);
$('searchThreads').onclick=()=>{$('threadSearch').hidden=!$('threadSearch').hidden;$('searchThreads').setAttribute('aria-expanded',String(!$('threadSearch').hidden));if(!$('threadSearch').hidden)$('threadSearch').focus();};
$('threadSearch').oninput=renderThreads;document.querySelectorAll('button[data-page]').forEach(b=>b.onclick=()=>show(b.dataset.page));
$('panel').addEventListener('focusout',()=>queueMicrotask(flushPanelRefresh));
$('panel').addEventListener('pointerdown',()=>{panelPointerActive=true;clearTimeout(panelPointerTimer);},true);
const releasePanelPointer=()=>{panelPointerActive=false;clearTimeout(panelPointerTimer);flushPanelRefresh();};
document.addEventListener('pointerup',()=>{if(panelPointerActive)panelPointerTimer=setTimeout(releasePanelPointer,400);});
document.addEventListener('pointercancel',()=>{if(panelPointerActive)panelPointerTimer=setTimeout(releasePanelPointer,0);});
document.addEventListener('click',()=>{if(panelPointerActive)queueMicrotask(releasePanelPointer);});
window.addEventListener('blur',releasePanelPointer);
document.addEventListener('selectionchange',()=>queueMicrotask(flushPanelRefresh));
$('latest').onclick=()=>{$('transcript').scrollTop=$('transcript').scrollHeight;};$('transcript').onscroll=()=>$('latest').hidden=stick();
$('exportChat').onclick=()=>{
  const transcript=events.filter(e=>['user','assistant:text'].includes(e.kind)).map(e=>`### ${e.kind==='user'?'You':'Assistant'}\n\n${e.text}\n`).join('\n');
  const pictures=UAI.pictures.manifest();
  const appendix=pictures.length?'\n### Picture previews\n\nMetadata only; image bytes are not included or sent to the AI.\n\n'+pictures.map(p=>`- ${String(p.name).replace(/[\r\n]/g,' ')} · ${p.width} × ${p.height} · ${p.bytes} bytes`).join('\n'):'';
  download('uai-transcript.md',transcript+appendix,'text/markdown');
};
document.addEventListener('click',e=>{const b=e.target.closest('.copy-code');if(b)copyText(b.closest('.code-block')?.querySelector('pre code')?.textContent||'');});
function closeSidebar(restore=false){const opened=document.body.classList.contains('sidebar-open');document.body.classList.remove('sidebar-open');syncSidebar();if(opened&&(restore||$('sidebar').contains(document.activeElement)))$('sidebarToggle').focus();}
function syncSidebar(){
  const mobile=innerWidth<=768;if(!mobile)document.body.classList.remove('sidebar-open');
  const open=mobile?document.body.classList.contains('sidebar-open'):!document.body.classList.contains('sidebar-hidden');
  $('sidebarToggle').setAttribute('aria-expanded',String(open));$('sidebar').inert=!open;
  $('sidebarOverlay').hidden=!mobile||!open;$('workspace').inert=mobile&&open;
  if(mobile&&open){$('sidebar').setAttribute('role','dialog');$('sidebar').setAttribute('aria-modal','true');}
  else{$('sidebar').removeAttribute('role');$('sidebar').removeAttribute('aria-modal');}
}
function themeChanged(){
  applyTheme(state.theme||{});const next=UAI.theme.resolved()==='dark'?'light':'dark';
  $('themeToggle').setAttribute('aria-label','Switch to '+next+' theme');$('themeToggle').title='Switch to '+next+' theme';
  document.body.dataset.codeTheme=state.settings?.ui?.codeTheme||UAI.theme.resolved();
}
document.addEventListener('uai:theme',themeChanged);themeChanged();
window.addEventListener('resize',()=>{syncSidebar();resizeComposer();});syncSidebar();
window.addEventListener('pagehide',()=>{saveDraft();persistDrafts();});
function showGate(reason=''){
  saveDraft();persistDrafts();stream?.close();clearTimeout(connectionRetry);closeSidebar();if($('modal').open)$('modal').close();
  connected=false;link='disconnected';$('app').hidden=true;$('gate').hidden=false;$('gate-error').textContent=reason;
  $('gate-connect').disabled=false;refresh();$('gate-token').focus({preventScroll:true});
}
async function checkConnection(){
  try{await api('/hello');}catch(error){if(error.status===401)return;}
  if(!$('app').hidden&&stream?.readyState!==EventSource.OPEN)connectionRetry=setTimeout(checkConnection,3000);
}
async function enter(){
  clearTimeout(connectionRetry);const hello=await api('/hello');
  if(hello.protocol!==2)throw Error('Update the bridge files, then restart the bridge to connect.');
  if(instance&&hello.instance!==instance){
    UAI.pictures.reset();renderer.reset();events=[];eventBytes=0;tools.clear();state={};$('transcript').replaceChildren();
    if(sendOperation){sendOperation.lost=true;setPhase('uncertain');persistOperation();}
  }
  instance=hello.instance;connected=!!hello.connected;link='online';
  UAI.pictures.setToken(token);await UAI.pictures.configure(hello);
  try{sessionStorage.setItem('uai.token',token);sessionStorage.setItem('uai.instance',instance);localStorage.removeItem('uai.token');}catch{}
  $('gate').hidden=true;$('gate-error').textContent='';$('gate-token').value='';$('app').hidden=false;refresh();welcome();syncSidebar();(page==='chat'?$('input'):$('panel')).focus({preventScroll:true});
  stream?.close();stream=new EventSource('/api/stream?token='+encodeURIComponent(token));
  stream.onopen=()=>{clearTimeout(connectionRetry);link='online';refresh();};
  stream.onmessage=e=>{try{apply(JSON.parse(e.data));}catch(err){console.error(err);toast('Could not render bridge update: '+err.message);}};
  stream.onerror=()=>{link='offline';connected=false;refresh();clearTimeout(connectionRetry);connectionRetry=setTimeout(checkConnection,2000);};
}
$('gate-form').onsubmit=async e=>{e.preventDefault();token=$('gate-token').value.trim().toLowerCase();$('gate-connect').disabled=true;$('gate-error').textContent='';try{await enter();}catch(err){showGate(err.message);}finally{$('gate-connect').disabled=false;}};
window.addEventListener('hashchange',async()=>{
  const supplied=location.hash.match(/(?:#|&)t=([a-f0-9]{64})(?:$|&)/i);if(!supplied)return;
  token=supplied[1].toLowerCase();history.replaceState(null,'',location.pathname);$('gate-connect').disabled=true;
  try{await enter();}catch(error){showGate(error.message);}finally{$('gate-connect').disabled=false;}
});
try{const pending=JSON.parse(stored('sessionStorage','uai.pendingSend')||'null');if(pending&&/^[\w-]{8,100}$/.test(pending.commandId)&&typeof pending.sessionId==='string'){sendOperation=pending;sendPhase='uncertain';}}catch{}
(async()=>{try{if(!token){showGate();return;}await enter();}catch(err){showGate(err.message||'Keep the bridge terminal open, then try connecting again.');}})();
