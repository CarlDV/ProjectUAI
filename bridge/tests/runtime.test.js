'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const net = require('node:net');
const path = require('node:path');
const { createInference } = require('../inference');
const markdown = require('../web/markdown');
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Spawn bridge/server.js on an ephemeral port and resolve once its token prints.
const { startBridge } = require('./helpers/bridge');

test('inference streams Unicode incrementally, retains results, and deduplicates submissions', async t => {
  let calls = 0;
  const upstream = http.createServer((req, res) => {
    calls++;
    assert.equal(req.headers.authorization, 'Bearer provider-test');
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const chunk = Buffer.from('data: {"choices":[{"delta":{"content":"Hi 世界"}}]}\n\n');
    res.write(chunk.subarray(0, chunk.length - 7));
    setTimeout(() => { res.write(chunk.subarray(chunk.length - 7)); res.end('data: [DONE]\n\n'); }, 40);
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  const events = [], relay = createInference({ publish: e => events.push(e), retentionMs: 100 });
  t.after(() => { relay.close(); upstream.close(); });
  const input = { id: 'request-123', instance: relay.instance, url: `http://127.0.0.1:${upstream.address().port}/v1/chat/completions`,
    headers: { Authorization: 'Bearer provider-test' }, body: '{"stream":true}', sessionId: 'session-one' };
  assert.equal(relay.start(input).state, 'running');
  assert.equal(relay.start(input).state, 'running');
  assert.throws(() => relay.start({ ...input, body: '{}' }), /different payload/);
  for (let i=0;i<100 && relay.get(input.id).state === 'running';i++) await sleep(5);
  assert.equal(calls, 1);
  assert.equal(relay.get(input.id).state, 'completed');
  assert.match(relay.get(input.id).body, /世界/);
  assert.equal(events.filter(e => e.kind === 'inference:delta').length, 1);
  assert.deepEqual(relay.previews('session-one').map(e => e.kind), ['inference:start', 'inference:delta', 'inference:done']);
  relay.commit(input.id); assert.equal(relay.previews('session-one').length, 0);
  await sleep(210);
  assert.equal(relay.get(input.id).state, 'expired');
  assert.equal(relay.start(input).state, 'expired');
  assert.equal(calls, 1);
  assert.throws(() => relay.start({ ...input, id: 'request-456', instance: 'old' }), /restarted/);
});

test('cancelled and truncated provider streams do not become successful answers', async t => {
  const upstream = http.createServer((req,res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
    if(req.url === '/truncated') res.end();
  });
  upstream.listen(0,'127.0.0.1');await once(upstream,'listening');
  const relay=createInference();t.after(()=>{relay.close();upstream.closeAllConnections();upstream.close();});
  const input={id:'cancel-me',instance:relay.instance,url:`http://127.0.0.1:${upstream.address().port}/slow`,body:'{}'};
  relay.start(input);await sleep(30);relay.cancel(input.id);
  assert.equal(relay.get(input.id).state,'cancelled');
  assert.equal(relay.start(input).state,'cancelled');
  relay.cancel('not-started');
  assert.equal(relay.start({...input,id:'not-started'}).state,'cancelled');
  relay.start({...input,id:'truncated',url:input.url.replace('/slow','/truncated')});
  for(let i=0;i<100&&relay.get('truncated').state==='running';i++)await sleep(5);
  assert.equal(relay.get('truncated').state,'failed');
});

test('bridge authenticates, redelivers unacknowledged commands, and deduplicates event batches', async t => {
  const reserve=http.createServer();reserve.listen(0,'127.0.0.1');await once(reserve,'listening');const port=reserve.address().port;await new Promise(r=>reserve.close(r));
  const process=spawn(global.process.execPath,['bridge/server.js','--port',String(port)],{cwd:require('node:path').join(__dirname,'../..'),stdio:['ignore','pipe','pipe']});
  t.after(()=>process.kill());
  let output=''; const token=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Server did not start')),5000);process.stdout.on('data',chunk=>{output+=chunk;const match=output.match(/Token\s+([a-f0-9]{64})/);if(match){clearTimeout(timer);resolve(match[1]);}});process.once('error',reject);});
  const base=`http://127.0.0.1:${port}`;
  const api=async(path,body)=>{const response=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{Authorization:'Bearer '+token,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});return {status:response.status,data:response.status===204?null:await response.json()};};
  assert.equal((await fetch(base+'/api/hello')).status,401);
  assert.equal((await fetch(base+'/api/hello?token='+encodeURIComponent('é'.repeat(64)))) .status,401);
  assert.equal((await api('/api/hello')).data.protocol,2);
  const payload={type:'send',text:'one message',sessionId:'s1',commandId:'test-command-one'};
  const first=await api('/api/command',payload),second=await api('/api/command',payload);
  assert.equal(first.data.id,second.data.id);
  assert.equal((await api('/api/agent/inbox')).data.commands.length,1);
  assert.equal((await api('/api/agent/inbox')).data.commands[0].commandId,payload.commandId);
  await api('/api/agent/ack',{results:[{id:payload.commandId,ok:true,data:{text:'Done'}}]});
  assert.equal((await api('/api/commands/'+payload.commandId)).data.state,'completed');
  assert.equal((await api('/api/command',{...payload,text:'changed'})).status,400);
  await api('/api/command',{...payload,commandId:'long-command'});
  await api('/api/agent/ack',{results:[{id:'long-command',pending:true}]});
  assert.equal((await api('/api/commands/long-command')).data.state,'running');
  await api('/api/agent/ack',{results:[{id:'long-command',ok:true}]});
  assert.equal((await api('/api/commands/long-command')).data.state,'completed');
  const waiting = api('/api/agent/inbox');
  await sleep(40);
  const sentAt = Date.now();
  await api('/api/command',{type:'abort',commandId:'instant-command'});
  const delivered = await waiting;
  assert.equal(delivered.data.commands[0].commandId,'instant-command');
  assert.ok(Date.now()-sentAt<2000,'held poll delivers immediately instead of waiting for HOLD_MS');
  await api('/api/agent/ack',{results:[{id:'instant-command',ok:true}]});
  const batch={batchId:'batch-one',events:[{kind:'user',text:'once'}],state:{sessionId:'s1'}};
  await api('/api/agent/events',batch);await api('/api/agent/events',batch);
  const controller=new AbortController();
  const response=await fetch(base+'/api/stream',{headers:{Authorization:'Bearer '+token},signal:controller.signal});
  const reader=response.body.getReader();const {value}=await reader.read();const text=new TextDecoder().decode(value);controller.abort();
  assert.equal((text.match(/"text":"once"/g)||[]).length,1);
  assert.match(text,/id: \d+/);
  const html=await (await fetch(base+'/')).text();assert.match(html,/id="sidebar"/);assert.match(html,/markdown.js/);
});

test('web Markdown escapes raw HTML and renders bounded tables and code without losing Unicode',()=>{
  const html=markdown.render('| Name | Score |\n| :--- | ---: |\n| **世界** | 42 |\n\n```lua\nprint("hello")\n```\n<script>alert(1)</script>');
  assert.match(html,/<table>/);assert.match(html,/<strong>世界<\/strong>/);assert.match(html,/md-right/);
  assert.match(html,/copy-code/);assert.doesNotMatch(html,/<script>/);assert.match(html,/&lt;script&gt;/);
});

test('native Anthropic SSE blocks are streamed and completed without OpenAI DONE markers',async t=>{
  const upstream=http.createServer((req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.end('event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Native reply"}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n');});
  upstream.listen(0,'127.0.0.1');await once(upstream,'listening');const events=[],relay=createInference({publish:e=>events.push(e)});t.after(()=>{relay.close();upstream.close();});
  relay.start({id:'native-anthropic',instance:relay.instance,url:`http://127.0.0.1:${upstream.address().port}`,sessionId:'s1',body:'{}'});
  for(let i=0;i<100&&relay.get('native-anthropic').state==='running';i++)await sleep(5);
  assert.equal(relay.get('native-anthropic').state,'completed');assert.ok(events.some(e=>e.frame?.delta?.text==='Native reply'));
});

test('server advertises capabilities, uses canonical fingerprints, and enforces the route/security matrix', async t => {
  const { base, token } = await startBridge(t);
  const auth = { Authorization: 'Bearer ' + token };
  const api = async (route, body, headers) => {
    const res = await fetch(base + route, { method: body === undefined ? 'GET' : 'POST',
      headers: { ...auth, 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body) });
    const raw = await res.text(); let data; try { data = JSON.parse(raw); } catch { data = raw; }
    return { status: res.status, data, res };
  };
  // /api/hello still reports protocol 2 and now carries capabilities + limits.
  const hello = await api('/api/hello');
  assert.equal(hello.data.protocol, 2);
  assert.equal(hello.data.capabilities.browserStream.schema, 1);
  assert.equal(hello.data.capabilities.pictures.version, 1);
  assert.equal(hello.data.limits.pictureBytes, 5242880);
  assert.equal(hello.data.limits.picturesPerSend, 8);
  assert.equal(hello.data.limits.pictureTtlMs, 900000);
  // Security headers on an API response.
  assert.equal(hello.res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(hello.res.headers.get('x-frame-options'), 'DENY');
  assert.equal(hello.res.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(hello.res.headers.get('cross-origin-resource-policy'), 'same-origin');
  assert.match(hello.res.headers.get('content-security-policy') || '', /default-src 'self'/);
  assert.doesNotMatch(hello.res.headers.get('content-security-policy') || '', /https?:\/\//);
  // Canonical fingerprint: different key order, same id => same receipt.
  const a = await api('/api/command', { type: 'abort', sessionId: 's1', commandId: 'canon-command-1' });
  const b = await api('/api/command', { commandId: 'canon-command-1', sessionId: 's1', type: 'abort' });
  assert.equal(a.status, 202);
  assert.equal(a.data.id, b.data.id);
  // Same id, changed payload => 400 conflict.
  assert.equal((await api('/api/command', { type: 'abort', sessionId: 's2', commandId: 'canon-command-1' })).status, 400);
  // Method/route matrix.
  assert.equal((await fetch(base + '/', { method: 'POST' })).status, 405);
  assert.equal((await api('/api/nope')).status, 404);
  // .png served as image/png with static security headers.
  const png = await fetch(base + '/icon-32.png');
  assert.equal(png.headers.get('content-type'), 'image/png');
  assert.equal(png.headers.get('x-content-type-options'), 'nosniff');
  assert.match(png.headers.get('content-security-policy') || '', /default-src 'self'/);
  // Query token: rejected on a non-stream API route, accepted on /api/stream.
  assert.equal((await fetch(base + '/api/hello?token=' + token)).status, 401);
  const controller = new AbortController();
  const stream = await fetch(base + '/api/stream?token=' + token, { signal: controller.signal });
  assert.equal(stream.status, 200);
  controller.abort();
});

test('a malformed request target returns 400 and the server keeps serving', async t => {
  const { base, token, port } = await startBridge(t);
  const line = await new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write('GET //[ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
    let buf = ''; socket.on('data', d => buf += d); socket.on('end', () => resolve(buf)); socket.on('error', reject);
  });
  assert.match(line, /^HTTP\/1\.1 400/);
  // The async handler survived: a normal request is still answered.
  const hello = await fetch(base + '/api/hello', { headers: { Authorization: 'Bearer ' + token } });
  assert.equal(hello.status, 200);
  assert.equal((await hello.json()).protocol, 2);
});
