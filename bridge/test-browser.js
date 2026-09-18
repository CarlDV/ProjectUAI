// Optional real-browser integration. Install Playwright outside the project or
// provide PLAYWRIGHT_MODULE; screenshots go only to the requested temp directory.
'use strict';
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const http=require('node:http');
const {once}=require('node:events');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  const reserve=http.createServer();reserve.listen(0,'127.0.0.1');await once(reserve,'listening');const port=reserve.address().port;await new Promise(r=>reserve.close(r));
  const server=spawn(process.execPath,['bridge/server.js','--port',String(port)],{stdio:['ignore','pipe','pipe']});
  let browser,upstream;
  try{
    let output='';const token=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Bridge did not start')),5000);server.stdout.on('data',c=>{output+=c;const m=output.match(/Token\s+([a-f0-9]{64})/);if(m){clearTimeout(timer);resolve(m[1]);}});});
    const base=`http://127.0.0.1:${port}`,headers={Authorization:'Bearer '+token,'content-type':'application/json'};
    const post=async(path,body)=>{const r=await fetch(base+path,{method:'POST',headers,body:JSON.stringify(body)});return r.status===204?null:r.json();};
    const state={protocol:2,runtime:'web',sessionId:'s1',player:'David',agent:{status:'Ready',busy:false,model:'test-model',provider:'Local test'},
      threads:[{id:'s1',title:'Bridge integration',place:'Test game',active:true},{id:'s2',title:'Second conversation',place:'Test game'}],
      providers:[{id:'p1',label:'Local test',baseUrl:'http://localhost:1234/v1',model:'test-model',models:['test-model','other-model'],enabled:true}],activeProvider:'p1',
      usage:{total:120,requests:2,cost:.001},permissions:{mode:'ask',pending:0},questions:[],pendingPermissions:[],todos:[],loops:[],subagents:[],logs:[],requests:[],
      settings:{ui:{density:'comfortable',fontScale:1,transcriptWidth:'wide'},agent:{effort:'high',maxTurns:24,customInstructions:''}},
      tools:[{name:'chat_bot',description:'Independent chatbot',risk:'write',group:'chat',enabled:true,available:true,parameters:{type:'object',properties:{instructions:{type:'string'}}}}]};
    await post('/api/agent/events',{batchId:'initial-browser',snapshot:[],state,sessionId:'s1'});
    browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:1280,height:800}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(base+'/#t='+token);await page.locator('#app').waitFor({state:'visible'});await page.waitForFunction(()=>document.querySelector('#modelLabel').textContent==='test-model');
    await page.locator('.starter').first().click();assert.match(await page.locator('#input').inputValue(),/Explore this game/);
    for(const name of ['providers','tools','agents','loops','logs','settings','cowork','chat']){await page.locator(`#sidebar [data-page="${name}"]`).first().click();await sleep(30);}
    await page.locator('#modelButton').click();assert.equal(await page.locator('#modal .model-list button').count(),2);await page.locator('#modalClose').click();
    upstream=http.createServer((req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: {"choices":[{"delta":{"content":"Real streaming "}}]}\n\n');setTimeout(()=>res.end('data: {"choices":[{"delta":{"content":"works."}}]}\n\ndata: [DONE]\n\n'),300);});
    upstream.listen(0,'127.0.0.1');await once(upstream,'listening');
    const hello=await (await fetch(base+'/api/hello',{headers})).json();
    await post('/api/inference',{id:'browser-stream',instance:hello.instance,url:`http://127.0.0.1:${upstream.address().port}`,body:'{}',sessionId:'s1'});
    await page.waitForFunction(()=>document.querySelector('.streaming .body')?.textContent.includes('Real streaming'));
    await sleep(400);
    await post('/api/agent/events',{batchId:'final-browser',events:[{kind:'assistant:text',text:'Real streaming works.',requestId:'browser-stream',sessionId:'s1'}]});
    await page.waitForFunction(()=>!document.querySelector('.streaming'));
    assert.equal(await page.locator('.message.agent').count(),1);
    await page.locator('#input').fill('Browser sends once');
    await page.locator('#send').click();
    const inbox=await (await fetch(base+'/api/agent/inbox',{headers})).json();
    const sent=inbox.commands.find(c=>c.type==='send');assert.equal(sent.text,'Browser sends once');
    await post('/api/agent/ack',{results:[{id:sent.commandId,ok:true}]});
    await post('/api/agent/events',{batchId:'browser-sent',events:[{kind:'user',text:sent.text,sessionId:'s1'}]});
    await page.waitForFunction(()=>document.querySelector('#input').value==='');
    assert.equal(await page.locator('.message.user').count(),1);
    await page.reload();await page.locator('#app').waitFor({state:'visible'});await page.waitForFunction(()=>document.querySelector('.message.agent .body')?.textContent.includes('Real streaming works.'));assert.equal(await page.locator('.message.agent').count(),1);
    await page.locator('#input').fill('keep draft on switch');
    await post('/api/agent/events',{batchId:'switch-browser',snapshot:[],sessionId:'s2',state:{...state,sessionId:'s2',threads:state.threads.map(t=>({...t,active:t.id==='s2'}))}});
    await page.waitForFunction(()=>document.querySelector('#input').value==='');
    await post('/api/agent/events',{batchId:'switch-back-browser',snapshot:[],sessionId:'s1',state});
    await page.waitForFunction(()=>document.querySelector('#input').value==='keep draft on switch');
    if(process.env.UAI_SCREENSHOTS)await page.screenshot({path:process.env.UAI_SCREENSHOTS+'/bridge-desktop.png'});
    await page.setViewportSize({width:390,height:844});await page.locator('#sidebarToggle').click();await page.locator('#sidebar').waitFor({state:'visible'});await page.locator('#closeSidebar').click();
    const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert.equal(overflow,false);
    if(process.env.UAI_SCREENSHOTS)await page.screenshot({path:process.env.UAI_SCREENSHOTS+'/bridge-mobile.png'});
    assert.deepEqual(errors,[]);console.log('Browser checks passed: navigation, model picker, real streaming, reload reconciliation, drafts, mobile bounds');
  }finally{await browser?.close();upstream?.close();server.kill();}
})().catch(e=>{console.error(e);process.exitCode=1;});
