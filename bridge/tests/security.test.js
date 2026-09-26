'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const path = require('node:path');
const sleep = ms => new Promise(r => setTimeout(r, ms));

const { startBridge } = require('./helpers/bridge');

// Raw request so headers like Origin (which fetch may strip) are sent verbatim.
function rawReq(port, method, route, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: route, method, headers }, res => {
      let d = ''; res.on('data', x => d += x); res.on('end', () => resolve({ status: res.statusCode, body: d, headers: res.headers }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('an oversized declared Content-Length is refused with 413 before the body is read', async t => {
  const { port, token } = await startBridge(t);
  const result = await new Promise(resolve => {
    const req = http.request({ host: '127.0.0.1', port, path: '/api/pictures', method: 'POST', headers: {
      Authorization: 'Bearer ' + token, 'content-type': 'image/png', 'content-length': String(10 * 1024 * 1024),
      'X-UAI-Browser-Id': 'b', 'X-UAI-Picture-Id': 'pic_' + crypto.randomUUID(), 'X-UAI-Session-Id': 's1',
    } }, res => { let d = ''; res.on('data', x => d += x); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
    req.on('error', () => resolve({ status: 0 }));
    req.write(Buffer.alloc(2048)); // only a tiny fraction of the declared length
    req.end();
  });
  // 413 preferred; a graceful 400 also satisfies "refused before full read".
  assert.ok(result.status === 413 || result.status === 400, 'oversized upload refused, got ' + result.status);
  assert.equal(result.status, 413);
});

test('no token or authorization value appears in an observable response body', async t => {
  const { base, token, port } = await startBridge(t);
  const bodies = [];
  bodies.push((await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer ' + token })).body);
  bodies.push((await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer deadbeef' })).body);
  bodies.push((await rawReq(port, 'GET', '/api/nope', { Authorization: 'Bearer ' + token })).body);
  bodies.push((await rawReq(port, 'POST', '/', {})).body);
  bodies.push((await rawReq(port, 'GET', '/api/commands/unknown-command', { Authorization: 'Bearer ' + token })).body);
  const controller = new AbortController();
  const res = await fetch(base + '/api/stream?token=' + token, { signal: controller.signal });
  const { value } = await res.body.getReader().read();
  controller.abort();
  bodies.push(new TextDecoder().decode(value));
  for (const b of bodies) assert.ok(!b.includes(token), 'token leaked in a response body: ' + b.slice(0, 80));
});

test('a foreign Origin is refused and an absent Origin is accepted', async t => {
  const { token, port } = await startBridge(t);
  const bad = await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer ' + token, Origin: 'http://evil.example' });
  assert.equal(bad.status, 403);
  assert.equal(bad.body, 'bad origin');
  const ok = await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer ' + token });
  assert.equal(ok.status, 200);
  assert.equal(JSON.parse(ok.body).protocol, 2);
  // The bridge's own listening origin is allowed.
  const same = await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer ' + token, Origin: `http://127.0.0.1:${port}` });
  assert.equal(same.status, 200);
});

test('the SSE hub caps concurrent subscribers and frees a slot on disconnect', async t => {
  const { base, token } = await startBridge(t);
  const held = [];
  const open = async keep => {
    const c = new AbortController();
    const r = await fetch(base + '/api/stream', { headers: { Authorization: 'Bearer ' + token }, signal: c.signal });
    if (keep) held.push(c); else c.abort();
    return r.status;
  };
  t.after(() => held.forEach(c => c.abort()));
  for (let i = 0; i < 8; i++) assert.equal(await open(true), 200);
  assert.equal(await open(false), 503); // cap reached
  held.shift().abort();                 // free one slot
  await sleep(150);
  assert.equal(await open(true), 200);  // a new subscriber is admitted again
});

test('security headers are present on API, static, and error responses', async t => {
  const { base, token, port } = await startBridge(t);
  const check = h => {
    assert.equal(h['x-content-type-options'], 'nosniff');
    assert.equal(h['x-frame-options'], 'DENY');
    assert.equal(h['referrer-policy'], 'no-referrer');
    assert.equal(h['cross-origin-opener-policy'], 'same-origin');
    assert.equal(h['cross-origin-resource-policy'], 'same-origin');
    assert.match(h['content-security-policy'] || '', /default-src 'self'/);
  };
  check((await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer ' + token })).headers); // API
  check((await rawReq(port, 'GET', '/', {})).headers);                                            // static
  check((await rawReq(port, 'GET', '/api/hello', { Authorization: 'Bearer nope' })).headers);     // 401 error
});

test('the --legacy flag disables the picture routes but keeps text send working', async t => {
  const { base, token } = await startBridge(t, ['--legacy']);
  const auth = { Authorization: 'Bearer ' + token, 'content-type': 'application/json' };
  // Picture routes are gone in legacy mode; /api/hello omits the picture capability.
  assert.equal((await fetch(base + '/api/pictures/policy', { headers: auth })).status, 404);
  const hello = await (await fetch(base + '/api/hello', { headers: auth })).json();
  assert.equal(hello.protocol, 2);
  assert.equal(hello.capabilities.pictures, undefined);
  // The plain text send path still works.
  const send = await fetch(base + '/api/send', { method: 'POST', headers: auth, body: JSON.stringify({ text: 'legacy still works', sessionId: 's1', commandId: 'legacy-send-1' }) });
  assert.equal(send.status, 202);
  const inbox = await (await fetch(base + '/api/agent/inbox', { headers: { ...auth, 'X-UAI-Client': 'g1' } })).json();
  assert.equal(inbox.commands.find(c => c.commandId === 'legacy-send-1').text, 'legacy still works');
});

test('raw and encoded traversal are refused, while static HEAD preserves the content length', async t => {
  const { port } = await startBridge(t);
  for (const target of ['/../server.js', '/%2e%2e/server.js', '/%2e%2e%2fserver.js', '/web%5c..%5cserver.js', '/%00']) {
    assert.equal((await rawReq(port, 'GET', target)).status, 403, target);
  }
  assert.equal((await rawReq(port, 'GET', '/%zz')).status, 400);
  const get = await rawReq(port, 'GET', '/'), head = await rawReq(port, 'HEAD', '/');
  assert.equal(head.status, 200); assert.equal(head.body, ''); assert.equal(head.headers['content-length'], get.headers['content-length']);
});

test('malformed command shapes and oversized commands do not enter the queue', async t => {
  const { port, token } = await startBridge(t), headers = { Authorization: 'Bearer ' + token, 'content-type': 'application/json' };
  for (const payload of ['null', '[]', '{broken', '{"pictureIds":"wrong","text":"x","type":"send"}']) {
    assert.equal((await rawReq(port, 'POST', '/api/command', headers, payload)).status, 400);
  }
  assert.equal((await rawReq(port, 'POST', '/api/agent/ack', headers, '{"results":{}}')).status, 400);
  assert.equal((await rawReq(port, 'POST', '/api/command', headers, JSON.stringify({ type: 'send', text: 'x'.repeat(2 * 1024 * 1024) }))).status, 413);
  assert.equal((await rawReq(port, 'GET', '/api/hello', headers)).status, 200);
});

test('aborted picture uploads release admission slots', async t => {
  const { port, token } = await startBridge(t);
  const uploads = Array.from({ length: 4 }, () => {
    const request = http.request({ host: '127.0.0.1', port, path: '/api/pictures', method: 'POST', headers: {
      Authorization: 'Bearer ' + token, 'content-type': 'image/png', 'content-length': '5000',
    } });
    request.on('error', () => {}); request.write(Buffer.alloc(10)); return request;
  });
  await sleep(80); uploads.forEach(request => request.destroy()); await sleep(100);
  const image = require('./helpers/images').makePng(4, 4);
  const response = await rawReq(port, 'POST', '/api/pictures', {
    Authorization: 'Bearer ' + token, 'content-type': 'image/png', 'X-UAI-Picture-Id': 'pic_upload-recovery',
    'X-UAI-Browser-Id': 'browser', 'X-UAI-Session-Id': 's1', 'X-UAI-Picture-Name': 'image.png',
  }, image);
  assert.equal(response.status, 201);
});

test('static serving resolves junctions before exposing files', async t => {
  const fs = require('node:fs'), os = require('node:os');
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-static-'));
  const app = path.join(temporary, 'app'), outside = path.join(temporary, 'outside');
  fs.mkdirSync(path.join(app, 'web'), { recursive: true }); fs.mkdirSync(outside);
  for (const name of ['server.js', 'inference.js', 'picture-store.js']) fs.copyFileSync(path.join(__dirname, '..', name), path.join(app, name));
  fs.writeFileSync(path.join(app, 'web/index.html'), '<html>fixture</html>'); fs.writeFileSync(path.join(outside, 'private.txt'), 'not a web asset');
  fs.symlinkSync(outside, path.join(app, 'web/escape'), process.platform === 'win32' ? 'junction' : 'dir');
  let bridge;
  t.after(async () => {
    await bridge?.stop(); assert.ok(path.resolve(temporary).startsWith(path.resolve(os.tmpdir()) + path.sep));
    fs.rmSync(temporary, { recursive: true, force: true });
  });
  bridge = await startBridge(null, [], path.join(app, 'server.js'));
  assert.equal((await rawReq(bridge.port, 'GET', '/escape/private.txt')).status, 403);
  assert.equal((await rawReq(bridge.port, 'GET', '/')).status, 200);
});
