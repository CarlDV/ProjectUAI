'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { createPictureStore } = require('../picture-store');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const picId = () => 'pic_' + crypto.randomUUID();
const owner = { browserId: 'b1', sessionId: 's1' };
const caught = fn => { try { fn(); return null; } catch (e) { return e; } };

const { makePng, makeJpeg, makeWebp, makeAnimatedWebp, pngChunk, PNG_SIG } = require('./helpers/images');

const sha = buf => crypto.createHash('sha256').update(buf).digest('hex');

test('valid PNG/JPEG/WebP stage with correct mediaType, dimensions, and digest', () => {
  const store = createPictureStore();
  const png = makePng(10, 20);
  const p = store.stage({ id: picId(), ...owner, name: 'a.png', declaredType: 'image/png', bytes: png });
  assert.equal(p.mediaType, 'image/png');
  assert.equal(p.width, 10); assert.equal(p.height, 20);
  assert.equal(p.bytes, png.length);
  assert.equal(p.sha256, sha(png));
  assert.equal(p.status, 'staged');
  assert.ok(p.createdAt && p.expiresAt > p.createdAt);

  const j = store.stage({ id: picId(), ...owner, name: 'b.jpg', declaredType: 'image/jpeg', bytes: makeJpeg(30, 40) });
  assert.equal(j.mediaType, 'image/jpeg');
  assert.equal(j.width, 30); assert.equal(j.height, 40);

  const wbytes = makeWebp(50, 60);
  const w = store.stage({ id: picId(), ...owner, name: 'c.webp', declaredType: 'image/webp', bytes: wbytes });
  assert.equal(w.mediaType, 'image/webp');
  assert.equal(w.width, 50); assert.equal(w.height, 60);
  assert.equal(w.sha256, sha(wbytes));
});

test('SVG and other non-image bytes are rejected as unsupported', () => {
  const store = createPictureStore();
  const svg = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/svg+xml', bytes: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>') }));
  assert.equal(svg.code, 'unsupported');
  const html = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'text/html', bytes: Buffer.from('<!doctype html><html></html>') }));
  assert.equal(html.code, 'unsupported');
  // A declared type that disagrees with the sniffed container is also unsupported.
  const spoof = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/png', bytes: makeJpeg(4, 4) }));
  assert.equal(spoof.code, 'unsupported');
});

test('bytes larger than the per-picture limit are too_large', () => {
  const store = createPictureStore({ pictureBytes: 40 });
  const e = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/png', bytes: makePng(8, 8) }));
  assert.equal(e.code, 'too_large');
});

test('over-dimension and over-pixel images are rejected as dimensions', () => {
  const store = createPictureStore();
  const overDim = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/png', bytes: makePng(5000, 100) }));
  assert.equal(overDim.code, 'dimensions');
  const overPixel = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/png', bytes: makePng(4000, 4000) }));
  assert.equal(overPixel.code, 'dimensions');
  // An unparseable header is also a dimensions failure.
  const truncated = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/png', bytes: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]) }));
  assert.equal(truncated.code, 'dimensions');
});

test('per-owner count and total-byte quotas are too_many', () => {
  const count = createPictureStore({ picturesPerSend: 2 });
  count.stage({ id: picId(), ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(2, 2) });
  count.stage({ id: picId(), ...owner, name: 'b', declaredType: 'image/png', bytes: makePng(3, 3) });
  const third = caught(() => count.stage({ id: picId(), ...owner, name: 'c', declaredType: 'image/png', bytes: makePng(4, 4) }));
  assert.equal(third.code, 'too_many');

  const pA = makePng(2, 2), pB = makePng(3, 3);
  const bytesStore = createPictureStore({ pictureTotalBytes: pA.length + pB.length - 1 });
  bytesStore.stage({ id: picId(), ...owner, name: 'a', declaredType: 'image/png', bytes: pA });
  const over = caught(() => bytesStore.stage({ id: picId(), ...owner, name: 'b', declaredType: 'image/png', bytes: pB }));
  assert.equal(over.code, 'too_many');
});

test('same id is idempotent for identical bytes and conflicts otherwise', () => {
  const store = createPictureStore();
  const id = picId();
  const first = store.stage({ id, ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(5, 5) });
  const again = store.stage({ id, ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(5, 5) });
  assert.equal(again.sha256, first.sha256);
  assert.equal(again.id, id);
  const conflict = caught(() => store.stage({ id, ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(6, 6) }));
  assert.equal(conflict.code, 'conflict');
  assert.equal(conflict.status, 409);
});

test('get denies a wrong browser id or session id', () => {
  const store = createPictureStore();
  const id = picId();
  store.stage({ id, ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(3, 3) });
  assert.ok(store.get(id, owner).bytes);
  assert.equal(store.get(id, { browserId: 'other', sessionId: 's1' }), null);
  assert.equal(store.get(id, { browserId: 'b1', sessionId: 'other' }), null);
});

test('an idle record expires after sweep and drops out of the catalog', async () => {
  const store = createPictureStore({ pictureTtlMs: 30 });
  const id = picId();
  store.stage({ id, ...owner, name: 'a', declaredType: 'image/png', bytes: makePng(2, 2) });
  assert.equal(store.catalog('s1').length, 1);
  await sleep(60);
  store.sweep();
  assert.deepEqual(store.get(id, owner), { expired: true });
  assert.equal(store.catalog('s1').length, 0);
});

test('animated WebP is rejected', () => {
  const store = createPictureStore();
  const e = caught(() => store.stage({ id: picId(), ...owner, name: 'x', declaredType: 'image/webp', bytes: makeAnimatedWebp() }));
  assert.equal(e.code, 'unsupported');
});

test('policy reports the shared limits and accepted media types', () => {
  const p = createPictureStore().policy();
  assert.equal(p.limits.pictureBytes, 5242880);
  assert.equal(p.limits.picturesPerSend, 8);
  assert.equal(p.limits.pictureTotalBytes, 20971520);
  assert.equal(p.limits.pictureTtlMs, 900000);
  assert.deepEqual(p.mediaTypes, ['image/png', 'image/jpeg', 'image/webp']);
  assert.equal(p.maxWidth, 4096); assert.equal(p.maxHeight, 4096); assert.equal(p.maxPixels, 12000000);
});

test('damaged containers, misleading extensions, and animated PNG are rejected', () => {
  const store = createPictureStore(), png = makePng(4, 4);
  const upload = (bytes, name = 'image.png') => store.stage({ id: picId(), ...owner, name, bytes });
  assert.throws(() => upload(png, 'image.jpg'), /extension/);
  assert.throws(() => upload(png.subarray(0, 33)), /Unreadable/);
  const corrupt = Buffer.from(png); corrupt[corrupt.length - 5] ^= 1;
  assert.throws(() => upload(corrupt), /Unreadable/);
  const animated = Buffer.concat([png.subarray(0, 33), pngChunk('acTL', Buffer.alloc(8)), png.subarray(33)]);
  assert.throws(() => upload(animated), /Animated/);
  const jpeg = makeJpeg(4, 4);
  assert.throws(() => upload(jpeg.subarray(0, -2), 'image.jpg'), /Unreadable/);
  const webp = makeWebp(20, 16), short = Buffer.from(webp); short.writeUInt32LE(short.length + 5, 4);
  assert.throws(() => upload(short, 'image.webp'), /Unreadable/);
});

test('failed uploads retry safely, delivered pictures release staging slots, and delete requires the owner', async () => {
  const store = createPictureStore({ picturesPerSend: 1, pictureTtlMs: 50 });
  const input = { id: picId(), ...owner, name: 'a.png', bytes: makePng(2, 2) };
  store.stage(input); store.markQueued([input.id], 'failed-command'); store.markStatus(input.id, 'failed');
  assert.equal(store.stage(input).status, 'staged');
  assert.equal(store.get(input.id, owner).meta.commandId, null);
  store.markQueued([input.id], 'delivered-command'); store.markStatus(input.id, 'acked');
  const next = { ...input, id: picId() }; assert.equal(store.stage(next).status, 'staged');
  assert.equal(store.remove(next.id, { ...owner, browserId: 'other' }), false);
  assert.ok(store.get(next.id, owner));
  await sleep(80); store.sweep();
  assert.throws(() => store.stage(next), error => error.code === 'expired');
  assert.throws(() => store.stage({ ...next, browserId: 'other' }), error => error.code === 'conflict');
  store.clearSession(owner.sessionId); assert.deepEqual(store.catalog(owner.sessionId), []);
});
