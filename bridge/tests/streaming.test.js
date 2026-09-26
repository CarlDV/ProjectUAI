'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createInference } = require('../inference');
const sleep = ms => new Promise(r => setTimeout(r, ms));

// One-shot loopback upstream. Error handlers keep the process alive when the
// relay destroys the connection mid-response (oversize/malformed cases).
async function upstream(t, handler) {
  const server = http.createServer((req, res) => { req.on('error', () => {}); res.on('error', () => {}); handler(req, res); });
  server.on('clientError', () => {});
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections?.(); server.close(); });
  return `http://127.0.0.1:${server.address().port}`;
}

// Run one job to a terminal state and return the collected events + final view.
async function run(t, handler, opts = {}) {
  const url = await upstream(t, handler);
  const events = [];
  const relay = createInference({ publish: e => events.push(e), ...opts });
  t.after(() => relay.close());
  const id = 'job-' + Math.random().toString(36).slice(2);
  relay.start({ id, instance: relay.instance, url, sessionId: 's1', body: '{}' });
  for (let i = 0; i < 500 && relay.get(id).state === 'running'; i++) await sleep(5);
  return { events, relay, id, view: relay.get(id) };
}
const done = events => events.find(e => e.kind === 'inference:done');
const deltas = events => events.filter(e => e.kind === 'inference:delta');

test('frame 1 is delivered to the browser before inference:done', async t => {
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"first"}}]}\n\n');
    setTimeout(() => res.end('data: [DONE]\n\n'), 40);
  });
  const firstDelta = events.findIndex(e => e.kind === 'inference:delta');
  const end = events.findIndex(e => e.kind === 'inference:done');
  assert.ok(firstDelta >= 0 && end >= 0 && firstDelta < end, 'delta precedes done');
  assert.equal(events[firstDelta].text, 'first');
  assert.equal(view.state, 'completed');
});

test('per-job seq is 1-based, gapless, and monotonic', async t => {
  const { events } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (let i = 1; i <= 5; i++) res.write(`data: {"choices":[{"delta":{"content":"t${i}"}}]}\n\n`);
    res.end('data: [DONE]\n\n');
  });
  assert.deepEqual(deltas(events).map(e => e.seq), [1, 2, 3, 4, 5]);
});

test('Unicode split across writes and across data: lines is reassembled into one delta each', async t => {
  const s = 'data: {"choices":[{"delta":{"content":"世界"}}]}\n\n';
  const frame = Buffer.from(s);
  const cut = Buffer.byteLength(s.slice(0, s.indexOf('世'))) + 1; // mid-byte of 世
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write(frame.subarray(0, cut));
    setTimeout(() => {
      res.write(frame.subarray(cut));
      // A single logical frame spread over two data: lines (joined with \n).
      res.write('data: {"choices":[{"delta":\ndata: {"content":"X"}}]}\n\n');
      res.end('data: [DONE]\n\n');
    }, 30);
  });
  const d = deltas(events);
  assert.equal(d[0].text, '世界');
  assert.equal(d[1].text, 'X');
  assert.equal(view.state, 'completed');
});

test('malformed streaming JSON fails with a stable reason and never completes', async t => {
  const { view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n');
    res.end('data: {not valid json\n\n');
  });
  assert.equal(view.state, 'failed');
  assert.match(view.error, /malformed streaming data/i);
});

test('a truncated stream (no [DONE]) fails instead of completing', async t => {
  const { view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
  });
  assert.equal(view.state, 'failed');
  assert.match(view.error, /ended before completion/i);
});

test('a non-SSE 200 response completes with streamed:false and keeps its body', async t => {
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"choices":[{"message":{"content":"buffered"}}]}');
  });
  assert.equal(view.state, 'completed');
  assert.equal(done(events).streamed, false);
  assert.equal(done(events).sawText, false); // non-SSE path emits no normalized deltas
  assert.match(view.body, /buffered/);
});

test('a zero-token stream failure is state failed with sawText:false', async t => {
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(); // opened as a stream, produced no frames or [DONE]
  });
  assert.equal(view.state, 'failed');
  assert.equal(done(events).sawText, false);
  assert.equal(done(events).streamed, true);
});

test('keepalive comment lines are ignored and [DONE] cleanly completes', async t => {
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write(': keepalive ping\n\n');
    res.write('data: {"choices":[{"delta":{"content":"hello"}}]}\n\n');
    res.end('data: [DONE]\n\n');
  });
  assert.equal(deltas(events).length, 1);
  assert.equal(deltas(events)[0].text, 'hello');
  assert.equal(view.state, 'completed');
  assert.equal(done(events).sawText, true);
});

test('frame ring overflow is flagged on done without trimming the raw body', async t => {
  const N = 4200; // exceeds the 4096-frame ring bound
  let payload = '';
  for (let i = 0; i < N; i++) payload += 'data: {"choices":[{"delta":{"content":"x"}}]}\n\n';
  payload += 'data: [DONE]\n\n';
  const { events, view } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(payload);
  });
  assert.equal(view.state, 'completed');
  assert.equal(done(events).overflow, true);
  assert.equal(deltas(events).length, N); // every frame was still published live
  assert.equal((view.body.match(/"content":"x"/g) || []).length, N); // Roblox poll body intact
});

test('a body over the 8 MiB deliverable limit fails fast and is never resubmitted', async t => {
  let calls = 0;
  const url = await upstream(t, (req, res) => {
    calls++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(Buffer.alloc(9 * 1024 * 1024, 0x61));
  });
  const relay = createInference({ publish: () => {} });
  t.after(() => relay.close());
  const input = { id: 'too-big-body', instance: relay.instance, url, sessionId: 's1', body: '{}' };
  relay.start(input);
  for (let i = 0; i < 500 && relay.get('too-big-body').state === 'running'; i++) await sleep(5);
  assert.equal(relay.get('too-big-body').state, 'failed');
  assert.match(relay.get('too-big-body').error, /deliverable limit/i);
  assert.equal(relay.start(input).state, 'failed'); // retry returns the terminal view
  assert.equal(calls, 1); // upstream was hit exactly once
});

test('the JSON receipt limit includes escaped response text and envelope bytes', async t => {
  const { view } = await run(t, (req, res) => { res.writeHead(200, { 'content-type': 'text/plain' }); res.end('"'.repeat(700)); }, { deliverableMax: 1000 });
  assert.equal(view.state, 'failed'); assert.match(view.error, /JSON encoding/); assert.equal(view.body, undefined);
});

test('HTTP provider errors retain the original body for Roblox and show an error in browser replay', async t => {
  const raw = '<html>Upstream overloaded. Retry later.</html>';
  const { view, events, relay } = await run(t, (req, res) => { res.writeHead(503, { 'content-type': 'text/event-stream', 'retry-after': '20' }); res.end(raw); });
  assert.equal(view.state, 'completed'); assert.equal(view.body, raw); assert.equal(view.status, 503);
  assert.equal(view.headers['retry-after'], '20'); assert.match(done(events).providerError, /HTTP 503/);
  assert.match(relay.previews('s1').at(-1).providerError, /HTTP 503/);
});

test('legacy mixed-channel frames do not duplicate text and replay their terminal state', async t => {
  const { events, relay } = await run(t, (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('data: {"type":4,"choices":[{"delta":{"content":"answer","reasoning_content":"thought"}}],"private":"do not project"}\n\ndata: [DONE]\n\n');
  }, { legacy: true });
  const frames = deltas(events).map(e => e.frame.choices[0].delta);
  assert.equal(frames.map(d => d.content || '').join(''), 'answer');
  assert.equal(frames.map(d => d.reasoning_content || '').join(''), 'thought');
  assert.ok(!JSON.stringify(events).includes('do not project'));
  assert.equal(relay.previews('s1').at(-1).kind, 'inference:done');
});

test('replay reports dropped frame ranges while the authoritative raw body stays intact', async t => {
  const payload = Array.from({ length: 4300 }, (_, i) => 'data: ' + JSON.stringify({ choices: [{ delta: { content: String(i) } }] }) + '\n\n').join('') + 'data: [DONE]\n\n';
  const { relay, view } = await run(t, (req, res) => { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(payload); });
  const replay = relay.previews('s1'), gap = replay.find(e => e.kind === 'inference:resync'), frames = deltas(replay);
  assert.ok(gap.from > 1); assert.equal(frames.length, 4096); assert.equal(frames[0].seq, gap.from);
  assert.equal(view.body, payload);
});
