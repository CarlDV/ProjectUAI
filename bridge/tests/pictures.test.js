'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const path = require('node:path');
const { createPictureStore } = require('../picture-store');
const sleep = ms => new Promise(r => setTimeout(r, ms));

const { startBridge } = require('./helpers/bridge');
const { readStream } = require('./helpers/bridge');

const { makePng, makeJpeg, makeWebp, makeAnimatedWebp } = require('./helpers/images');

const owner = (token, b, s) => ({ Authorization: 'Bearer ' + token, 'X-UAI-Browser-Id': b, 'X-UAI-Session-Id': s });
const picId = () => 'pic_' + crypto.randomUUID();
async function upload(base, token, { id, browserId, sessionId, name, mediaType, bytes }) {
  return fetch(base + '/api/pictures', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'X-UAI-Browser-Id': browserId, 'X-UAI-Picture-Id': id,
      'X-UAI-Session-Id': sessionId, 'X-UAI-Picture-Name': encodeURIComponent(name || 'x'), 'content-type': mediaType },
    body: bytes,
  });
}

test('the picture store validates containers, dimensions, and idempotency', () => {
  const store = createPictureStore({});
  const base = { browserId: 'b1', sessionId: 's1' };
  const png = store.stage({ id: picId(), ...base, name: 'a.png', mediaType: 'image/png', bytes: makePng(10, 20) });
  assert.equal(png.mediaType, 'image/png'); assert.equal(png.width, 10); assert.equal(png.height, 20);
  assert.match(png.sha256, /^[a-f0-9]{64}$/);
  assert.equal(store.stage({ id: picId(), ...base, name: 'j', mediaType: 'image/jpeg', bytes: makeJpeg(30, 40) }).width, 30);
  assert.equal(store.stage({ id: picId(), ...base, name: 'w', mediaType: 'image/webp', bytes: makeWebp(50, 60) }).height, 60);
  // spoofed MIME: jpeg bytes declared as png.
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: makeJpeg(4, 4) }), /match/i);
  // SVG / HTML rejected by the container sniff.
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/svg+xml', bytes: Buffer.from('<svg xmlns="http://x"><rect/></svg>') }), /Unsupported|container/i);
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: Buffer.from('<!doctype html><html></html>') }), /Unsupported|container|match/i);
  // Oversized bytes (> 5 MiB).
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: Buffer.concat([makePng(1, 1), Buffer.alloc(6 * 1024 * 1024)]) }), /byte limit/i);
  // Over-dimension (> 4096) and over-pixel (within dims but > 12 MP).
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: makePng(5000, 100) }), /dimensions/i);
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: makePng(4000, 4000) }), /pixel/i);
  // Malformed (truncated PNG header).
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/png', bytes: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]) }), /Unreadable|dimensions/i);
  // Animated WebP rejected.
  assert.throws(() => store.stage({ id: picId(), ...base, name: 'x', mediaType: 'image/webp', bytes: makeAnimatedWebp() }), /Animated/i);
  // Idempotent same id + same bytes; conflicting bytes => 409.
  const id = picId();
  const first = store.stage({ id, ...base, name: 'a', mediaType: 'image/png', bytes: makePng(10, 20) });
  const again = store.stage({ id, ...base, name: 'a', mediaType: 'image/png', bytes: makePng(10, 20) });
  assert.equal(again.sha256, first.sha256);
  let conflict; try { store.stage({ id, ...base, name: 'a', mediaType: 'image/png', bytes: makePng(11, 21) }); } catch (e) { conflict = e; }
  assert.equal(conflict.status, 409);
});

test('a staged picture expires after its idle TTL and reads as expired', async () => {
  const store = createPictureStore({ limits: { pictureTtlMs: 40 } });
  const o = { browserId: 'b1', sessionId: 's1' };
  const id = picId();
  store.stage({ id, browserId: 'b1', sessionId: 's1', name: 'a', mediaType: 'image/png', bytes: makePng(2, 2) });
  assert.ok(store.get(id, o).bytes);
  await sleep(80);
  assert.deepEqual(store.get(id, o), { expired: true });
});

test('cross-owner and cross-session reads are denied at the store', () => {
  const store = createPictureStore({});
  const id = picId();
  store.stage({ id, browserId: 'b1', sessionId: 's1', name: 'a', mediaType: 'image/png', bytes: makePng(3, 3) });
  assert.equal(store.get(id, { browserId: 'other', sessionId: 's1' }), null);
  assert.equal(store.get(id, { browserId: 'b1', sessionId: 'other' }), null);
  assert.ok(store.get(id, { browserId: 'b1', sessionId: 's1' }).bytes);
});

test('the policy route returns the shared limits and accepted media types', async t => {
  const { base, token } = await startBridge(t);
  const res = await fetch(base + '/api/pictures/policy', { headers: { Authorization: 'Bearer ' + token } });
  assert.equal(res.status, 200);
  const p = await res.json();
  assert.equal(p.limits.pictureBytes, 5242880);
  assert.equal(p.limits.picturesPerSend, 8);
  assert.equal(p.limits.pictureTotalBytes, 20971520);
  assert.deepEqual(p.mediaTypes, ['image/png', 'image/jpeg', 'image/webp']);
  assert.equal(p.maxWidth, 4096); assert.equal(p.maxHeight, 4096); assert.equal(p.maxPixels, 12000000);
});

test('pictures stage, read, and delete over the authenticated route for png/jpeg/webp', async t => {
  const { base, token } = await startBridge(t);
  const browserId = 'browser-abc', sessionId = 's1';
  const samples = [
    { name: 'a.png', mediaType: 'image/png', bytes: makePng(8, 8), w: 8, h: 8 },
    { name: 'b.jpg', mediaType: 'image/jpeg', bytes: makeJpeg(12, 9), w: 12, h: 9 },
    { name: 'c.webp', mediaType: 'image/webp', bytes: makeWebp(20, 16), w: 20, h: 16 },
  ];
  for (const s of samples) {
    const id = picId();
    const up = await upload(base, token, { id, browserId, sessionId, ...s });
    assert.equal(up.status, 201, s.name);
    const meta = await up.json();
    assert.equal(meta.mediaType, s.mediaType);
    assert.equal(meta.width, s.w); assert.equal(meta.height, s.h);
    assert.equal(meta.status, 'staged');
    assert.match(meta.sha256, /^[a-f0-9]{64}$/);
    const get = await fetch(base + '/api/pictures/' + id, { headers: owner(token, browserId, sessionId) });
    assert.equal(get.status, 200);
    assert.equal(get.headers.get('content-type'), s.mediaType);
    assert.equal(get.headers.get('cache-control'), 'no-store');
    assert.equal(get.headers.get('x-content-type-options'), 'nosniff');
    assert.ok(Buffer.from(await get.arrayBuffer()).equals(s.bytes));
    assert.equal((await fetch(base + '/api/pictures/' + id, { headers: owner(token, 'nope', sessionId) })).status, 404);
    assert.equal((await fetch(base + '/api/pictures/' + id, { headers: owner(token, browserId, 'nope') })).status, 404);
    assert.equal((await fetch(base + '/api/pictures/' + id, { method: 'DELETE', headers: owner(token, browserId, sessionId) })).status, 200);
    assert.equal((await fetch(base + '/api/pictures/' + id, { headers: owner(token, browserId, sessionId) })).status, 404);
  }
  // Spoofed MIME is refused over the route too.
  const bad = await upload(base, token, { id: picId(), browserId, sessionId, name: 'x', mediaType: 'image/png', bytes: makeJpeg(4, 4) });
  assert.ok(bad.status >= 400 && bad.status < 500);
});

test('a picture send composes markers, strips pictureIds, and emits metadata-only events', async t => {
  const { base, token } = await startBridge(t);
  const browserId = 'browser-xyz', sessionId = 's1';
  const auth = { Authorization: 'Bearer ' + token };
  const idA = picId(), idB = picId();
  await upload(base, token, { id: idA, browserId, sessionId, name: 'a.png', mediaType: 'image/png', bytes: makePng(4, 4) });
  await upload(base, token, { id: idB, browserId, sessionId, name: 'b.jpg', mediaType: 'image/jpeg', bytes: makeJpeg(6, 6) });
  const controller = new AbortController();
  const stream = await fetch(base + '/api/stream', { headers: { ...auth }, signal: controller.signal });
  const reader = stream.body.getReader(); const dec = new TextDecoder(); let sse = '';
  const pump = (async () => { try { for (;;) { const { value, done } = await reader.read(); if (done) break; sse += dec.decode(value, { stream: true }); } } catch { /* aborted */ } })();
  await sleep(60);
  const send = await fetch(base + '/api/send', { method: 'POST',
    headers: { ...auth, 'content-type': 'application/json', 'X-UAI-Browser-Id': browserId },
    body: JSON.stringify({ text: 'What is this?', pictureIds: [idA, idB], sessionId, commandId: 'pic-send-1' }) });
  assert.equal(send.status, 202);
  // The Roblox command is exactly the marker text with no picture leakage.
  const inbox = await (await fetch(base + '/api/agent/inbox', { headers: { ...auth, 'X-UAI-Client': 'game-1' } })).json();
  const cmd = inbox.commands.find(c => c.commandId === 'pic-send-1');
  assert.equal(cmd.type, 'send');
  assert.equal(cmd.text, '[PICTURE]\n[PICTURE]\n\nWhat is this?');
  assert.ok(!('pictureIds' in cmd) && !('bytes' in cmd) && !('path' in cmd) && !('data' in cmd));
  assert.equal(JSON.stringify(cmd).includes('pic_'), false);
  await sleep(60);
  controller.abort(); await pump;
  const events = sse.split('\n').filter(l => l.startsWith('data:')).map(l => { try { return JSON.parse(l.slice(5)); } catch { return null; } }).filter(Boolean);
  const queued = events.filter(e => e.kind === 'bridge:picture' && e.status === 'queued');
  assert.equal(queued.length, 2);
  assert.deepEqual(queued.map(e => e.id), [idA, idB]);
  for (const e of queued) {
    assert.equal(e.commandId, 'pic-send-1');
    assert.ok(e.sha256 && e.width && e.height && e.mediaType);
    assert.ok(!('url' in e) && !('path' in e) && !('data' in e) && !('base64' in e));
  }
});

test('markers-alone is a valid send and a cross-session picture is rejected', async t => {
  const { base, token } = await startBridge(t);
  const browserId = 'browser-1', sessionId = 's1';
  const id = picId();
  await upload(base, token, { id, browserId, sessionId, name: 'a.png', mediaType: 'image/png', bytes: makePng(5, 5) });
  // No text: the marker alone is a valid non-empty send.
  const send = await fetch(base + '/api/send', { method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'content-type': 'application/json', 'X-UAI-Browser-Id': browserId },
    body: JSON.stringify({ text: '', pictureIds: [id], sessionId, commandId: 'markers-only-1' }) });
  assert.equal(send.status, 202);
  const inbox = await (await fetch(base + '/api/agent/inbox', { headers: { Authorization: 'Bearer ' + token, 'X-UAI-Client': 'g1' } })).json();
  assert.equal(inbox.commands.find(c => c.commandId === 'markers-only-1').text, '[PICTURE]');
  // Same picture id from a different session cannot be attached.
  const otherId = picId();
  await upload(base, token, { id: otherId, browserId, sessionId, name: 'b.png', mediaType: 'image/png', bytes: makePng(5, 5) });
  const bad = await fetch(base + '/api/send', { method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'content-type': 'application/json', 'X-UAI-Browser-Id': browserId },
    body: JSON.stringify({ text: 'hi', pictureIds: [otherId], sessionId: 's2', commandId: 'wrong-session-1' }) });
  assert.equal(bad.status, 400);
});

test('delivery retries survive unavailable previews and snapshot correlation uses transcript identity', async t => {
  const { base, token } = await startBridge(t);
  const browserId = 'retry-browser', sessionId = 's1', id = picId();
  const auth = { ...owner(token, browserId, sessionId), 'content-type': 'application/json' };
  const post = (route, body) => fetch(base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
  await upload(base, token, { id, browserId, sessionId, name: 'a.png', mediaType: 'image/png', bytes: makePng(4, 4) });
  const payload = { type: 'send', text: 'Look here', pictureIds: [id], sessionId, commandId: 'retry-picture-send' };
  assert.equal((await post('/api/command', payload)).status, 202);
  const saved = { kind: 'user', text: '[PICTURE]\n\nLook here', at: 1000, transcriptId: 1 };
  const live = await readStream(base, token, async () => {
    await post('/api/agent/events', { batchId: 'picture-live', sessionId, state: { sessionId }, events: [saved] });
    await post('/api/agent/ack', { results: [{ id: payload.commandId, ok: true }] });
  });
  assert.equal(live.find(e => e.kind === 'user').commandId, payload.commandId);
  assert.equal((await (await fetch(base + '/api/pictures/' + id, { method: 'DELETE', headers: owner(token, 'other', sessionId) })).json()).removed, false);
  assert.equal((await (await fetch(base + '/api/pictures/' + id, { method: 'DELETE', headers: auth })).json()).removed, true);
  assert.equal((await post('/api/command', payload)).status, 202);
  assert.equal((await post('/api/command', { ...payload, text: 'Changed' })).status, 400);
  await post('/api/agent/events', { batchId: 'picture-snapshot', sessionId, snapshot: [saved, { ...saved, at: 2000, transcriptId: 2 }] });
  const replay = await readStream(base, token);
  const snapshot = replay.find(e => e.kind === 'bridge:snapshot').events;
  assert.equal(snapshot[0].commandId, payload.commandId);
  assert.equal(snapshot[1].commandId, undefined, 'equal text in another transcript entry is never guessed');
});
