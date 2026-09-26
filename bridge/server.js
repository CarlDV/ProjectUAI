#!/usr/bin/env node
'use strict';

// The web bridge.
//
// A Roblox client cannot accept an inbound connection -- executors expose an
// outbound HTTP function and nothing that listens -- so the browser and the game
// cannot see each other directly. This process sits between them on loopback:
// both sides dial out to it, and it owns the queue in the middle.
//
//   browser  --POST /api/send-------->|
//            <----GET /api/stream SSE-|  this
//   game     --GET /api/agent/inbox-->|
//            --POST /api/agent/events>|
//
// Zero dependencies on purpose. SSE downstream to the browser and plain requests
// from the game cover every direction needed, so there is no WebSocket handshake
// or frame codec in here to get wrong.
//
//   node bridge/server.js [--port 8790] [--legacy]

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { createInference } = require('./inference');
const { createPictureStore } = require('./picture-store');

const args = process.argv.slice(2);
function flag(name, fallback) {
  const at = args.indexOf('--' + name);
  return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
}
function hasFlag(name) { return args.includes('--' + name); }

const PORT = Number(flag('port', 8790)) || 8790;
const HOST = '127.0.0.1';
const WEB_DIR = path.join(__dirname, 'web');
// Staged rollout: --legacy disables the picture routes and the normalized-delta
// projection, leaving the plain text send/stream path exactly as it was.
const LEGACY = hasFlag('legacy');

// Regenerated every start. A token that outlived the process would end up pasted
// into a config somewhere and become a permanent key to an agent that can run
// code on this machine.
const TOKEN = crypto.randomBytes(32).toString('hex');

// How long an inbox poll is held before answering empty. Comfortably under the
// point where an executor's own HTTP timeout would kill the request first, which
// costs a reconnect rather than a message.
const HOLD_MS = 18000;

// Past this with no contact the game is treated as gone, so the browser stops
// pretending a message it sends is going somewhere.
const STALE_MS = 25000;

const PICTURE_LIMITS = {
  pictureBytes: 5 * 1024 * 1024,
  picturesPerSend: 8,
  pictureTotalBytes: 20 * 1024 * 1024,
  pictureTtlMs: 15 * 60 * 1000,
};

const BACKLOG_LIMIT = 400;          // events kept since the last snapshot
const BACKLOG_BYTES = 8 * 1024 * 1024;
const REPLAY_LIMIT = 5000;          // transcript replay frames (Last-Event-ID)
const REPLAY_BYTES = 16 * 1024 * 1024;
const MAX_SUBSCRIBERS = 8;
const SUBSCRIBER_PENDING_BYTES = 1 * 1024 * 1024; // per-subscriber socket buffer cap
const SUBSCRIBER_STALL_MS = 30000;
const COMMAND_BYTES = 16 * 1024 * 1024;
const RESULT_BYTES = 32 * 1024 * 1024;
let commandBytes = 0, resultBytes = 0, backlogBytes = 0, activeUploads = 0;
const submissionTimes = [];

let eventSequence = 0;
const replay = [];
let replayBytes = 0;
const seenBatches = new Set();
const commands = new Map();
// Metadata-only reconciliation of pictures attached to a queued command. Never
// holds image bytes; retained briefly with the receipt for reload/reconciliation.
const commandPictures = new Map();
const pictures = LEGACY ? null : createPictureStore({ limits: PICTURE_LIMITS });
const inference = createInference({ publish: broadcast, legacy: LEGACY });
let gameInstance = null;

const state = {
  inbox: [],        // commands waiting for the game to collect
  waiters: [],      // inbox polls being held open
  subscribers: new Set(), // browser SSE subscribers ({ res, stalledSince, beat })
  backlog: [],      // events since the last snapshot, replayed to a new browser
  snapshot: null,   // the transcript as of the game's last (re)connect
  agentState: null, // the game's last full state push: providers, models, threads, tools, usage
  lastSeen: 0,      // when the game last touched any /api/agent route
  connected: false,
};

// Security headers applied to static, API, SSE, and error responses. The CSP is
// same-origin only (no remote CDN) with blob: for locally fetched thumbnails.
const SECURITY_HEADERS = {
  'content-security-policy': "default-src 'self'; connect-src 'self'; img-src 'self' blob:; script-src 'self'; style-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'cross-origin-opener-policy': 'same-origin',
  'cross-origin-resource-policy': 'same-origin',
};
function withSecurity(headers) { return { ...SECURITY_HEADERS, ...headers }; }

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, withSecurity({
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  }));
  res.end(body);
}

// Plain-text bodies so the browser transport helper can surface the real reason
// (bad token / bad origin / method not allowed) instead of a generic failure.
function sendText(res, status, text) {
  const body = String(text);
  res.writeHead(status, withSecurity({
    'content-type': 'text/plain; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  }));
  res.end(body);
}

// Both halves of the check matter. The token stops anything that has not been
// told the secret; the Origin check stops a page you happen to have open from
// using your browser as the messenger, which the token alone cannot do because a
// rebinding attack gets to read the reply and learn it.
const ORIGINS = new Set([
  `http://127.0.0.1:${PORT}`,
  `http://localhost:${PORT}`,
  `http://[::1]:${PORT}`,
]);

function originOk(req) {
  const origin = req.headers.origin;
  // Absent for the game's own requests: an executor HTTP call is not a browser
  // and sends no Origin. Present and wrong is the case worth refusing.
  if (!origin) return true;
  return ORIGINS.has(origin);
}

function authorised(req, url) {
  const header = String(req.headers.authorization || '');
  const bearer = header.startsWith('Bearer ') ? header.slice(7) : '';
  // EventSource cannot set a header, so the stream route -- and only the stream
  // route -- accepts the token in the query instead. Same secret, same compare.
  const supplied = bearer || (url.pathname === '/api/stream' ? (url.searchParams.get('token') || '') : '');
  if (!/^[a-f0-9]{64}$/.test(supplied)) return false;
  return crypto.timingSafeEqual(Buffer.from(supplied), Buffer.from(TOKEN));
}

// UTF-8 body reader for JSON commands. Rejects an oversized declared length up
// front and caps the actual read; both raise a 413.
function readBody(req, limit = 1 << 20) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > limit) { reject(tooLarge()); return; }
    let size = 0, done = false;
    const chunks = [];
    req.on('data', (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > limit) { done = true; reject(tooLarge()); return; }
      chunks.push(chunk);
    });
    req.on('end', () => { if (!done) { done = true; resolve(Buffer.concat(chunks).toString('utf8')); } });
    req.on('aborted', () => { if (!done) { done = true; reject(new Error('request aborted')); } });
    req.on('error', (err) => { if (!done) { done = true; reject(err); } });
  });
}

// Raw-byte reader for binary uploads. Never routed through the UTF-8 JSON path.
function readBuffer(req, limit) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > limit) { reject(tooLarge()); return; }
    let size = 0, done = false;
    const chunks = [];
    req.on('data', (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > limit) { done = true; reject(tooLarge()); return; }
      chunks.push(chunk);
    });
    req.on('end', () => { if (!done) { done = true; resolve(Buffer.concat(chunks)); } });
    req.on('aborted', () => { if (!done) { done = true; reject(new Error('request aborted')); } });
    req.on('error', (err) => { if (!done) { done = true; reject(err); } });
  });
}

function tooLarge() { const err = new Error('body too large'); err.status = 413; return err; }

async function readJson(req, limit = 20 << 20) {
  const text = await readBody(req, limit);
  if (!text) return {};
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

// A stable, key-order-independent canonical JSON so a semantically identical
// retry with different key order is the same receipt, not a false conflict.
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    const out = Object.create(null);
    for (const key of Object.keys(value).sort()) out[key] = canonicalize(value[key]);
    return out;
  }
  return value;
}
function fingerprintOf(source) { return crypto.createHash('sha256').update(JSON.stringify(canonicalize(source))).digest('hex'); }

function admitSubmission() {
  const now = Date.now();
  while (submissionTimes.length && submissionTimes[0] < now - 10000) submissionTimes.shift();
  if (submissionTimes.length >= 100) {
    const err = new Error('Too many commands; wait a moment and retry');
    err.status = 429; err.code = 'rate_limited'; throw err;
  }
  submissionTimes.push(now);
}

// Browser -> game ------------------------------------------------------------

// Handing the command straight to a held-open poll is what makes this feel live
// rather than polled: the game is already waiting when the message arrives. The
// fingerprintSource (defaults to the command) drives idempotency; pictureIds are
// part of it but are stripped from the object the game receives.
function enqueue(command, fingerprintSource) {
  const id = command.commandId || crypto.randomUUID();
  if (typeof id !== 'string' || !/^[\w-]{8,100}$/.test(id)) throw new Error('Invalid command ID');
  const fingerprint = fingerprintOf({ ...(fingerprintSource || command), commandId: id });
  if (commands.has(id)) {
    if (commands.get(id).fingerprint !== fingerprint) { const e = new Error('Command ID belongs to another action'); e.status = 400; throw e; }
    return { id, created: false };
  }
  admitSubmission();
  const bytes = Buffer.byteLength(JSON.stringify(command));
  if (commandBytes + bytes > COMMAND_BYTES) { const e = new Error('Command queue is full; let pending work finish first'); e.status = 503; throw e; }
  if (commands.size >= 10000) { const e = new Error('Command capacity reached; retry shortly'); e.status = 503; throw e; }
  const { pictureIds, ...clean } = command; // never crosses the game boundary
  const queued = { ...clean, commandId: id };
  commands.set(id, { command: queued, state: 'queued', fingerprint, bytes });
  commandBytes += bytes;
  state.inbox.push(queued);
  const waiter = state.waiters.shift();
  if (!waiter) return { id, created: true };
  clearTimeout(waiter.timer);
  for (const c of state.inbox.slice(0, 32)) commands.get(c.commandId).delivered = true;
  sendJson(waiter.res, 200, { commands: state.inbox.slice(0, 32) });
  return { id, created: true };
}

// Deterministic marker composition shared by /api/send and /api/command send.
function prepareSend(body, owner) {
  const rawText = body && typeof body.text === 'string' ? body.text.trim() : '';
  const pictureIds = Array.isArray(body && body.pictureIds) ? body.pictureIds : [];
  if (body?.pictureIds !== undefined && !Array.isArray(body.pictureIds)) throw badRequest('pictureIds must be an array');
  const metas = [];
  if (pictureIds.length) {
    if (!pictures) throw badRequest('Pictures are not enabled on this bridge');
    if (pictureIds.length > PICTURE_LIMITS.picturesPerSend) throw badRequest('Too many pictures in one send');
    const seen = new Set();
    for (const id of pictureIds) {
      if (typeof id !== 'string' || !/^pic_[\w-]{8,64}$/.test(id)) throw badRequest('Invalid picture ID');
      if (seen.has(id)) throw badRequest('Duplicate picture ID');
      seen.add(id);
      const found = pictures.get(id, owner);
      if (!found) throw badRequest('Unknown or inaccessible picture ID');
      if (found.expired) { const e = new Error('Picture has expired; re-upload it'); e.status = 410; throw e; }
      const meta = found.meta;
      if (meta.status === 'queued' && meta.commandId && meta.commandId !== body.commandId) { const e = new Error('Picture already queued to another command'); e.status = 409; throw e; }
      if (meta.status === 'acked' && meta.commandId !== body.commandId) { const e = new Error('Picture already delivered'); e.status = 409; throw e; }
      metas.push(meta);
    }
  }
  // One [PICTURE] line per id in input order, then a blank line and the text.
  const markers = pictureIds.map(() => '[PICTURE]').join('\n');
  let text;
  if (markers && rawText) text = markers + '\n\n' + rawText;
  else if (markers) text = markers;
  else text = rawText;
  if (!text) throw badRequest('no text');
  const command = { type: 'send', text, files: body && body.files, sessionId: body && body.sessionId, commandId: body && body.commandId };
  const fingerprintSource = { type: 'send', text, files: body && body.files, sessionId: body && body.sessionId, pictureIds };
  return { command, fingerprintSource, pictureIds, metas };
}

function badRequest(message) { const e = new Error(message); e.status = 400; return e; }

function pictureEvent(meta, status, commandId) {
  return {
    kind: 'bridge:picture', id: meta.id, sessionId: meta.sessionId,
    browserId: meta.browserId,
    commandId: commandId !== undefined ? commandId : meta.commandId,
    status: status || meta.status, name: meta.name, mediaType: meta.mediaType,
    bytes: meta.bytes, sha256: meta.sha256, width: meta.width, height: meta.height, expiresAt: meta.expiresAt,
  };
}

function handleSend(req, res, body) {
  const owner = { browserId: req.headers['x-uai-browser-id'], sessionId: body && body.sessionId };
  // A lost acknowledgement can be retried after the picture is delivered or
  // expired. Compare the original browser payload before touching staged bytes.
  const requestFingerprint = fingerprintOf({ ...body, type: 'send', browserId: owner.browserId });
  const previous = commands.get(body?.commandId);
  if (previous) {
    if (previous.sendFingerprint !== requestFingerprint) throw badRequest('Command ID belongs to another action');
    sendJson(res, 202, { queued: true, id: body.commandId }); return;
  }
  const prepared = prepareSend(body, owner);
  const { id, created } = enqueue(prepared.command, prepared.fingerprintSource);
  commands.get(id).sendFingerprint = requestFingerprint;
  if (created && prepared.pictureIds.length && pictures) {
    pictures.markQueued(prepared.pictureIds, id);
    commandPictures.set(id, { metas: prepared.metas.map(m => ({ ...m, commandId: id })),
      sessionId: prepared.command.sessionId, textHash: fingerprintOf(prepared.command.text), observed: false, createdAt: Date.now() });
    if (commandPictures.size > 10000) commandPictures.delete(commandPictures.keys().next().value);
    for (const m of prepared.metas) broadcast(pictureEvent(m, 'queued', id));
  }
  sendJson(res, 202, { queued: true, id });
}

function finalizePictures(commandId, status) {
  const group = commandPictures.get(commandId);
  if (!group) return;
  for (const m of group.metas) {
    if (pictures) pictures.markStatus(m.id, status);
    broadcast(pictureEvent(m, status, commandId));
  }
  group.status = status;
}

function retainResult(entry, result) {
  const bytes = Buffer.byteLength(JSON.stringify(result));
  for (const old of commands.values()) {
    if (resultBytes + bytes <= RESULT_BYTES) break;
    if (!old.resultBytes || old === entry) continue;
    resultBytes -= old.resultBytes; old.resultBytes = 0;
    old.result = { id: old.command.commandId, ok: false, uncertain: true, error: 'This receipt has expired. Check Roblox before repeating the action.' };
  }
  entry.result = result; entry.resultBytes = bytes; resultBytes += bytes;
}

function serveInbox(req, res) {
  const client = req.headers['x-uai-client'];
  if (client && gameInstance && client !== gameInstance) {
    for (const entry of commands.values()) {
      if ((entry.state === 'queued' && entry.delivered) || entry.state === 'running') {
        entry.state = 'failed';
        entry.finishedAt = Date.now();
        retainResult(entry, { id: entry.command.commandId, ok: false, uncertain: true, error: 'Roblox restarted during command delivery; outcome is uncertain. The command was not repeated.' });
        commandBytes -= entry.bytes || 0; entry.bytes = 0;
        finalizePictures(entry.command.commandId, 'failed');
        entry.command = { commandId: entry.command.commandId };
      }
    }
    state.inbox = state.inbox.filter(c => commands.get(c.commandId).state === 'queued');
  }
  if (client) gameInstance = client;
  for (const command of state.inbox.slice(0, 32)) commands.get(command.commandId).delivered = true;
  touch();
  if (state.inbox.length) {
    sendJson(res, 200, { commands: state.inbox.slice(0, 32) });
    return;
  }
  const waiter = { res, timer: null };
  const release = () => {
    const at = state.waiters.indexOf(waiter);
    if (at >= 0) state.waiters.splice(at, 1);
  };
  waiter.timer = setTimeout(() => {
    release();
    sendJson(res, 200, { commands: [] });
  }, HOLD_MS);
  req.on('close', () => {
    clearTimeout(waiter.timer);
    release();
  });
  state.waiters.push(waiter);
}

// Game -> browser ------------------------------------------------------------

function dropSubscriber(sub) {
  if (!state.subscribers.has(sub)) return;
  state.subscribers.delete(sub);
  clearInterval(sub.beat);
  sub.pending.length = 0; sub.pendingBytes = 0;
  try { sub.res.destroy(); } catch { /* already gone */ }
}

function writeFrame(sub, frame) {
  if (sub.res.destroyed) return;
  const bytes = Buffer.byteLength(frame);
  try {
    if (sub.stalledSince) {
      if (sub.pendingBytes + bytes > SUBSCRIBER_PENDING_BYTES) { dropSubscriber(sub); return; }
      sub.pending.push(frame); sub.pendingBytes += bytes;
    } else if (!sub.res.write(frame)) sub.stalledSince = Date.now();
  } catch {
    dropSubscriber(sub);
  }
}

function broadcast(event) {
  const id = ++eventSequence;
  const frame = `id: ${id}\ndata: ${JSON.stringify(event)}\n\n`;
  const bytes = Buffer.byteLength(frame);
  replay.push({ id, frame, bytes });
  replayBytes += bytes;
  // Transcript-replay accounting: bounded by BOTH count and bytes. Inference
  // frame retention is accounted separately inside inference.js.
  while (replay.length > REPLAY_LIMIT || replayBytes > REPLAY_BYTES) {
    const dropped = replay.shift();
    if (!dropped) break;
    replayBytes -= dropped.bytes;
  }
  const now = Date.now();
  for (const sub of state.subscribers) {
    if (sub.stalledSince && now - sub.stalledSince > SUBSCRIBER_STALL_MS) { dropSubscriber(sub); continue; }
    writeFrame(sub, frame);
  }
}

function announceConnection(connected) {
  if (state.connected === connected) return;
  state.connected = connected;
  broadcast({ kind: 'bridge:game', connected });
}

function touch() {
  state.lastSeen = Date.now();
  announceConnection(true);
}

async function serveEvents(req, res) {
  touch();
  const payload = await readJson(req);
  if (!payload) {
    sendJson(res, 400, { error: 'invalid json' });
    return;
  }
  if (payload.state && (Array.isArray(payload.state) || Buffer.byteLength(JSON.stringify(payload.state)) > BACKLOG_BYTES)) throw badRequest('invalid or oversized game state');
  for (const event of [...(Array.isArray(payload.snapshot) ? payload.snapshot : []), ...(Array.isArray(payload.events) ? payload.events : [])]) {
    if (!event || typeof event.kind !== 'string' || Buffer.byteLength(JSON.stringify(event)) > BACKLOG_BYTES) throw badRequest('invalid or oversized game event');
  }
  if (payload.batchId && seenBatches.has(payload.batchId)) { res.writeHead(204, SECURITY_HEADERS).end(); return; }
  if (payload.batchId) {
    seenBatches.add(payload.batchId);
    if (seenBatches.size > 10000) seenBatches.delete(seenBatches.values().next().value);
  }
  const batchSession = payload.sessionId || (payload.state && payload.state.sessionId) || (state.agentState && state.agentState.sessionId);
  // A snapshot is the whole transcript as the game sees it, sent on connect and
  // whenever the active thread changes. It replaces the backlog rather than
  // adding to it, otherwise a reconnect would show the conversation twice.
  if (Array.isArray(payload.snapshot)) {
    state.snapshot = boundedEvents(payload.snapshot).map(event => {
      const normalized = { ...event, sessionId: event.sessionId || batchSession };
      if (event.kind !== 'user' || event.transcriptId == null) return normalized;
      const identity = fingerprintOf([event.transcriptId, event.at, event.text]);
      const matches = [...commandPictures.entries()].filter(([, group]) => group.sessionId === normalized.sessionId && group.eventFingerprint === identity);
      return matches.length === 1 ? { ...normalized, commandId: matches[0][0] } : normalized;
    });
    state.backlog = [];
    backlogBytes = 0;
    broadcast({ kind: 'bridge:snapshot', events: state.snapshot, sessionId: batchSession });
  }
  if (payload.state && typeof payload.state === 'object') {
    state.agentState = payload.state;
    broadcast({ kind: 'bridge:state', state: payload.state });
  }
  const events = Array.isArray(payload.events) ? payload.events : [];
  for (let event of events) {
    if (!event || typeof event !== 'object') continue;
    if (!event.sessionId && batchSession) event = { ...event, sessionId: batchSession };
    if (event.kind === 'user') {
      const hash = fingerprintOf(event.text || '');
      const candidates = [...commandPictures.entries()].filter(([, group]) => !group.observed && group.status !== 'failed' &&
        group.sessionId === event.sessionId && group.textHash === hash);
      if (candidates.length === 1) {
        const [id, group] = candidates[0]; group.observed = true;
        if (event.transcriptId != null) group.eventFingerprint = fingerprintOf([event.transcriptId, event.at, event.text]);
        event = { ...event, commandId: id };
      }
    }
    if (event.kind === 'cleared' && pictures) pictures.clearSession(event.sessionId);
    // Commit a live preview ONLY on the authoritative final text for this job in
    // the matching session. A reasoning event with the same id must not commit.
    if (event.kind === 'assistant:text' && event.requestId) inference.commit(event.requestId, event.sessionId || batchSession);
    state.backlog.push(event);
    backlogBytes += Buffer.byteLength(JSON.stringify(event));
    broadcast(event);
  }
  while (state.backlog.length > BACKLOG_LIMIT || backlogBytes > BACKLOG_BYTES) {
    backlogBytes -= Buffer.byteLength(JSON.stringify(state.backlog.shift()));
  }
  res.writeHead(204, SECURITY_HEADERS).end();
}

function boundedEvents(events) {
  const kept = []; let bytes = 0;
  for (let i = events.length - 1; i >= 0 && kept.length < BACKLOG_LIMIT; i--) {
    const size = Buffer.byteLength(JSON.stringify(events[i]));
    if (bytes + size > BACKLOG_BYTES) break;
    kept.push(events[i]); bytes += size;
  }
  return kept.reverse();
}

function serveStream(req, res) {
  if (state.subscribers.size >= MAX_SUBSCRIBERS) {
    sendText(res, 503, 'too many subscribers');
    return;
  }
  res.writeHead(200, withSecurity({
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  }));
  const sub = { res, stalledSince: 0, beat: null, pending: [], pendingBytes: 0 };
  state.subscribers.add(sub);
  res.on('drain', () => {
    sub.stalledSince = 0;
    while (sub.pending.length && !sub.stalledSince && !res.destroyed) {
      const frame = sub.pending.shift(); sub.pendingBytes -= Buffer.byteLength(frame);
      writeFrame(sub, frame);
    }
  });
  const sessionId = state.agentState && state.agentState.sessionId;
  // Replay before subscribing, so a browser opened mid-turn reads the
  // conversation from the top instead of joining halfway through a sentence.
  const cursor = Number(req.headers['last-event-id'] || 0);
  const resumable = cursor > 0 && cursor <= eventSequence && (cursor === eventSequence || (replay.length && cursor >= replay[0].id - 1));
  if (resumable) {
    // A cursor still inside the ring: replay only the frames after it.
    for (const entry of replay) if (entry.id > cursor) writeFrame(sub, entry.frame);
  } else {
    // Fresh / non-resumable: reset -> snapshot -> state -> backlog -> picture
    // catalog -> uncommitted previews -> cursor -> game.
    const writeData = event => writeFrame(sub, `data: ${JSON.stringify(event)}\n\n`);
    writeData({ kind: 'bridge:reset', instance: inference.instance, resync: cursor > 0 });
    if (state.snapshot) writeData({ kind: 'bridge:snapshot', events: state.snapshot, sessionId });
    if (state.agentState) writeData({ kind: 'bridge:state', state: state.agentState });
    for (const event of state.backlog) writeData(event);
    if (pictures) for (const meta of pictures.catalog(sessionId)) writeData(pictureEvent(meta));
    for (const event of inference.previews(sessionId)) writeData(event);
  }
  writeFrame(sub, `id: ${eventSequence}\ndata: ${JSON.stringify({ kind: 'bridge:cursor' })}\n\n`);
  writeFrame(sub, `data: ${JSON.stringify({ kind: 'bridge:game', connected: state.connected })}\n\n`);

  // Comment frames keep the connection from being reaped by an idle timeout on a
  // quiet conversation. They are ignored by EventSource.
  sub.beat = setInterval(() => {
    if (sub.stalledSince && Date.now() - sub.stalledSince > SUBSCRIBER_STALL_MS) { dropSubscriber(sub); return; }
    writeFrame(sub, ': ping\n\n');
  }, 15000);
  req.on('close', () => {
    clearInterval(sub.beat);
    state.subscribers.delete(sub);
  });
}

// Static ---------------------------------------------------------------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
};

// The page itself is unauthenticated: you have to be able to load it before you
// can hand it a token. It ships no secret of its own -- every route that touches
// the agent is behind the check.
async function serveStatic(pathname, res) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const target = path.resolve(WEB_DIR, rel);
  // Traversal guard: resolve first, then confirm the result is still inside the
  // directory we intended to serve.
  if (target !== WEB_DIR && !target.startsWith(WEB_DIR + path.sep)) {
    sendText(res, 403, 'forbidden');
    return;
  }
  try {
    const real = await fs.promises.realpath(target), base = await fs.promises.realpath(WEB_DIR);
    if (!real.startsWith(base + path.sep)) { sendText(res, 403, 'forbidden'); return; }
    if (!(await fs.promises.stat(real)).isFile()) { sendText(res, 404, 'not found'); return; }
    const body = await fs.promises.readFile(real);
    res.writeHead(200, withSecurity({
      'content-type': MIME[path.extname(target).toLowerCase()] || 'application/octet-stream',
      'content-length': body.length,
      'cache-control': 'no-store',
    }));
    res.end(body);
  } catch { sendText(res, 404, 'not found'); }
}

// Router ---------------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  // Parse the target inside a guard: a malformed request target returns 400
  // instead of rejecting the async handler and taking the process down.
  let url, route;
  try {
    if (!req.url.startsWith('/') || req.url.startsWith('//')) { sendText(res, 400, 'bad request'); return; }
    const rawPath = decodeURIComponent(req.url.split('?')[0]);
    if (rawPath.includes('\\') || rawPath.includes('\0') || rawPath.split('/').some(part => part === '..' || part === '.')) {
      sendText(res, 403, 'forbidden'); return;
    }
    url = new URL(req.url, `http://${HOST}:${PORT}`);
    route = url.pathname;
    const decoded = decodeURIComponent(route);
    if (decoded.includes('\\') || decoded.includes('\0') || decoded.split('/').some(part => part === '..' || part === '.')) {
      sendText(res, 403, 'forbidden'); return;
    }
    route = decoded;
  } catch {
    sendText(res, 400, 'bad request');
    return;
  }

  if (!route.startsWith('/api/')) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      sendText(res, 405, 'method not allowed');
      return;
    }
    await serveStatic(route, res);
    return;
  }

  if (!originOk(req)) {
    sendText(res, 403, 'bad origin');
    return;
  }
  if (!authorised(req, url)) {
    sendText(res, 401, 'bad token');
    return;
  }

  const post = req.method === 'POST';
  try {
    if (route === '/api/hello' && req.method === 'GET') {
      const capabilities = { browserStream: { schema: 1, replay: true } };
      if (!LEGACY) capabilities.pictures = { mode: 'browser-preview-and-text-marker', version: 1 };
      sendJson(res, 200, {
        ok: true, connected: state.connected, protocol: 2, instance: inference.instance,
        capabilities,
        limits: {
          pictureBytes: PICTURE_LIMITS.pictureBytes, picturesPerSend: PICTURE_LIMITS.picturesPerSend,
          pictureTotalBytes: PICTURE_LIMITS.pictureTotalBytes, pictureTtlMs: PICTURE_LIMITS.pictureTtlMs,
          deliverableBytes: inference.limits.deliverableMax,
        },
      });
    } else if (route === '/api/inference' && post) {
      const input = JSON.parse(await readBody(req, 20 << 20));
      sendJson(res, 202, inference.start(input));
    } else if (route.startsWith('/api/inference/')) {
      const id = route.slice('/api/inference/'.length);
      if (req.method === 'DELETE') sendJson(res, 200, { cancelled: inference.cancel(id) });
      else if (req.method === 'GET') {
        const job = inference.get(id);
        sendJson(res, job ? 200 : 404, job || { error: 'Unknown inference ID; do not resubmit' });
      } else sendJson(res, 405, { error: 'method not allowed' });
    } else if (route === '/api/agent/ack' && post) {
      touch();
      const body = await readJson(req);
      if (!body || !Array.isArray(body.results) || body.results.length > 1000) throw badRequest('invalid acknowledgement');
      for (const result of body.results) {
        if (!result || typeof result.id !== 'string') throw badRequest('invalid command receipt');
        const entry = commands.get(result.id);
        if (entry && ['queued', 'running'].includes(entry.state)) {
          entry.state = result.pending ? 'running' : (result.ok === false ? 'failed' : 'completed');
          if (!result.pending) {
            commandBytes -= entry.bytes || 0; entry.bytes = 0;
            retainResult(entry, result);
            if (result.ok !== false && pictures) {
              const command = entry.command;
              if (command.type === 'clear' || command.type === 'thread:delete') pictures.clearSession(command.type === 'thread:delete' ? command.id : command.sessionId);
            }
            entry.command = { commandId: result.id };
            entry.finishedAt = Date.now();
            finalizePictures(result.id, result.ok === false ? 'failed' : 'acked');
          }
          state.inbox = state.inbox.filter(c => c.commandId !== result.id);
          if (!result.pending) broadcast({ kind: 'bridge:command', id: result.id, ok: result.ok, error: result.error });
        }
      }
      sendJson(res, 200, { ok: true });
    } else if (route.startsWith('/api/commands/') && req.method === 'GET') {
      const entry = commands.get(route.slice('/api/commands/'.length));
      sendJson(res, entry ? 200 : 404, entry ? { state: entry.state, result: entry.result } : { error: 'Unknown command' });
    } else if (route === '/api/stream' && req.method === 'GET') {
      serveStream(req, res);
    } else if (route === '/api/pictures/policy' && req.method === 'GET') {
      // Registered before the :id matcher so "policy" is never parsed as an id.
      if (!pictures) { sendJson(res, 404, { error: 'pictures disabled' }); return; }
      sendJson(res, 200, pictures.policy());
    } else if (route === '/api/pictures' && post) {
      if (!pictures) { sendJson(res, 404, { error: 'pictures disabled' }); return; }
      if (activeUploads >= 4) { sendJson(res, 429, { error: 'Picture uploads are busy; retry in a moment', code: 'upload_capacity' }); return; }
      activeUploads++;
      let buf;
      try { buf = await readBuffer(req, PICTURE_LIMITS.pictureBytes); } finally { activeUploads--; }
      let name = req.headers['x-uai-picture-name'] || '';
      try { name = decodeURIComponent(name); } catch { /* sanitized in the store */ }
      const meta = pictures.stage({
        id: req.headers['x-uai-picture-id'],
        browserId: req.headers['x-uai-browser-id'],
        sessionId: req.headers['x-uai-session-id'],
        name,
        mediaType: req.headers['content-type'],
        bytes: buf,
      });
      broadcast(pictureEvent(meta));
      sendJson(res, 201, meta);
    } else if (route.startsWith('/api/pictures/')) {
      if (!pictures) { sendJson(res, 404, { error: 'pictures disabled' }); return; }
      const id = route.slice('/api/pictures/'.length);
      const owner = { browserId: req.headers['x-uai-browser-id'], sessionId: req.headers['x-uai-session-id'] };
      if (req.method === 'GET') {
        const found = pictures.get(id, owner);
        if (!found) { sendText(res, 404, 'not found'); return; }
        if (found.expired) { sendText(res, 410, 'gone'); return; }
        res.writeHead(200, withSecurity({
          'content-type': found.meta.mediaType,
          'content-length': found.bytes.length,
          'cache-control': 'no-store',
        }));
        res.end(found.bytes);
      } else if (req.method === 'DELETE') {
        sendJson(res, 200, { removed: pictures.remove(id, owner) });
      } else sendJson(res, 405, { error: 'method not allowed' });
    } else if (route === '/api/send' && post) {
      handleSend(req, res, await readJson(req, 2 << 20));
    } else if ((route === '/api/abort' || route === '/api/clear') && post) {
      const body = await readJson(req, 2 << 20);
      const { id } = enqueue({ type: route.slice(5), sessionId: body?.sessionId, commandId: body?.commandId });
      sendJson(res, 202, { queued: true, id });
    } else if (route === '/api/permission' && post) {
      const body = await readJson(req);
      if (!body || typeof body.id !== 'string') {
        sendJson(res, 400, { error: 'no id' });
        return;
      }
      const { id } = enqueue({
        type: 'permission',
        id: body.id,
        allow: body.allow === true,
        remember: body.remember === true,
      });
      sendJson(res, 202, { queued: true, id });
    } else if (route === '/api/command' && post) {
      // A generic door for everything that is not a message: provider and model
      // switching, thread management, permission mode, subagent control. The game
      // decides what is allowed; this only delivers.
      const body = await readJson(req, 2 << 20);
      if (!body || typeof body.type !== 'string') {
        sendJson(res, 400, { error: 'no type' });
        return;
      }
      if (body.type === 'send') { handleSend(req, res, body); return; }
      const { id } = enqueue(body);
      sendJson(res, 202, { queued: true, id });
    } else if (route === '/api/agent/inbox' && req.method === 'GET') {
      serveInbox(req, res);
    } else if (route === '/api/agent/events' && post) {
      await serveEvents(req, res);
    } else {
      sendJson(res, 404, { error: 'no such route' });
    }
  } catch (err) {
    const status = err && err.status ? err.status : 400;
    if (!res.headersSent) {
      if (status === 413) {
        // Close the connection so any remaining unread body is discarded rather
        // than kept alive for a request that was already refused.
        res.writeHead(413, withSecurity({ 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', connection: 'close' }));
        res.end(JSON.stringify({ error: 'body too large' }));
      } else {
        sendJson(res, status, { error: String(err && err.message || err), code: err.code });
      }
    }
  }
});

// A poll that stops arriving is the only signal the game has gone: it has no way
// to tell us on the way out if the client closed.
setInterval(() => {
  if (state.connected && Date.now() - state.lastSeen > STALE_MS) {
    announceConnection(false);
  }
}, 5000).unref();

// Periodic picture cleanup so idle-expired records free memory without waiting
// for the next access.
if (pictures) setInterval(() => pictures.cleanup(), 60000).unref();

// Terminal command records are dropped after a TTL longer than the browser's
// 190 s receipt poll, so a long-lived bridge never wedges at the count cap.
// Active (queued/running) records are never evicted.
setInterval(() => {
  const now = Date.now();
  for (const [id, entry] of commands) {
    if ((entry.state === 'completed' || entry.state === 'failed') && entry.finishedAt && now - entry.finishedAt > 300000) {
      resultBytes -= entry.resultBytes || 0; commands.delete(id);
    }
  }
  for (const [id, group] of commandPictures) if (now - group.createdAt > 2 * PICTURE_LIMITS.pictureTtlMs) commandPictures.delete(id);
}, 30000).unref();

server.listen(PORT, HOST, () => {
  const origin = `http://${HOST}:${PORT}`;
  // The token rides in the fragment, which browsers never send to a server and
  // nothing logs. The page reads it once and keeps it, so this link is the whole
  // setup on the browser side.
  process.stdout.write(
    `\n  UAI bridge on ${origin}${LEGACY ? ' (legacy mode)' : ''}\n\n` +
    `  Open    ${origin}/#t=${TOKEN}\n` +
    `  Token   ${TOKEN}\n` +
    `\n  1. Open the link above in your browser.\n` +
    `  2. In Roblox, open UAI -> Cowork. Paste the Token and set Port to ${PORT}.\n` +
    `  3. Turn Enabled on. Choose Web for live browser responses.\n\n` +
    `  Keep this terminal and Roblox open. Ctrl+C stops the bridge.\n` +
    `  Runs on this computer only. Keep the token private; it changes on restart.\n\n`
  );
});

for (const event of ['SIGINT', 'SIGTERM']) process.on(event, () => {
  inference.close();
  pictures?.close();
  server.closeAllConnections();
  server.close(() => process.exit(0));
});

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    process.stderr.write(`\n  Port ${PORT} is already in use. Try --port ${PORT + 1}.\n\n`);
    process.exit(1);
  }
  throw err;
});
