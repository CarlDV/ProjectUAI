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
//   node bridge/server.js [--port 8790]

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
function flag(name, fallback) {
  const at = args.indexOf('--' + name);
  return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
}

const PORT = Number(flag('port', 8790)) || 8790;
const HOST = '127.0.0.1';
const WEB_DIR = path.join(__dirname, 'web');

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

const BACKLOG_LIMIT = 400;

const state = {
  inbox: [],        // commands waiting for the game to collect
  waiters: [],      // inbox polls being held open
  subscribers: new Set(), // browser SSE responses
  backlog: [],      // events since the last snapshot, replayed to a new browser
  snapshot: null,   // the transcript as of the game's last (re)connect
  lastSeen: 0,      // when the game last touched any /api/agent route
  connected: false,
};

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
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
  // EventSource cannot set a header, so the stream route carries it in the query
  // instead. Same secret, same comparison.
  const supplied = bearer || url.searchParams.get('token') || '';
  if (supplied.length !== TOKEN.length) return false;
  return crypto.timingSafeEqual(Buffer.from(supplied), Buffer.from(TOKEN));
}

function readBody(req, limit = 1 << 20) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function readJson(req) {
  const text = await readBody(req);
  if (!text) return {};
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' ? value : {};
  } catch {
    return null;
  }
}

// Browser -> game ------------------------------------------------------------

// Handing the command straight to a held-open poll is what makes this feel live
// rather than polled: the game is already waiting when the message arrives.
function enqueue(command) {
  state.inbox.push(command);
  const waiter = state.waiters.shift();
  if (!waiter) return;
  clearTimeout(waiter.timer);
  sendJson(waiter.res, 200, { commands: state.inbox.splice(0) });
}

function serveInbox(req, res) {
  touch();
  if (state.inbox.length) {
    sendJson(res, 200, { commands: state.inbox.splice(0) });
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

function broadcast(event) {
  const frame = `data: ${JSON.stringify(event)}\n\n`;
  for (const res of state.subscribers) {
    // A browser that has gone away without closing cleanly must not take the
    // loop down with it.
    try {
      res.write(frame);
    } catch {
      state.subscribers.delete(res);
    }
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
  // A snapshot is the whole transcript as the game sees it, sent on connect and
  // whenever the active thread changes. It replaces the backlog rather than
  // adding to it, otherwise a reconnect would show the conversation twice.
  if (Array.isArray(payload.snapshot)) {
    state.snapshot = payload.snapshot;
    state.backlog = [];
    broadcast({ kind: 'bridge:snapshot', events: payload.snapshot });
  }
  const events = Array.isArray(payload.events) ? payload.events : [];
  for (const event of events) {
    if (!event || typeof event !== 'object') continue;
    state.backlog.push(event);
    broadcast(event);
  }
  if (state.backlog.length > BACKLOG_LIMIT) {
    state.backlog.splice(0, state.backlog.length - BACKLOG_LIMIT);
  }
  res.writeHead(204).end();
}

function serveStream(req, res) {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  // Replay before subscribing, so a browser opened mid-turn reads the
  // conversation from the top instead of joining halfway through a sentence.
  if (state.snapshot) {
    res.write(`data: ${JSON.stringify({ kind: 'bridge:snapshot', events: state.snapshot })}\n\n`);
  }
  for (const event of state.backlog) {
    res.write(`data: ${JSON.stringify(event)}\n\n`);
  }
  res.write(`data: ${JSON.stringify({ kind: 'bridge:game', connected: state.connected })}\n\n`);

  state.subscribers.add(res);
  // Comment frames keep the connection from being reaped by an idle timeout on a
  // quiet conversation. They are ignored by EventSource.
  const beat = setInterval(() => {
    try {
      res.write(': ping\n\n');
    } catch {
      /* cleaned up by the close handler */
    }
  }, 15000);
  req.on('close', () => {
    clearInterval(beat);
    state.subscribers.delete(res);
  });
}

// Static ---------------------------------------------------------------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

// The page itself is unauthenticated: you have to be able to load it before you
// can hand it a token. It ships no secret of its own -- every route that touches
// the agent is behind the check.
function serveStatic(pathname, res) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const target = path.resolve(WEB_DIR, rel);
  // Traversal guard: resolve first, then confirm the result is still inside the
  // directory we intended to serve.
  if (target !== WEB_DIR && !target.startsWith(WEB_DIR + path.sep)) {
    res.writeHead(403).end('forbidden');
    return;
  }
  fs.readFile(target, (err, body) => {
    if (err) {
      res.writeHead(404).end('not found');
      return;
    }
    res.writeHead(200, {
      'content-type': MIME[path.extname(target)] || 'application/octet-stream',
      'content-length': body.length,
      'cache-control': 'no-store',
    });
    res.end(body);
  });
}

// Router ---------------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${HOST}:${PORT}`);
  const route = url.pathname;

  if (!route.startsWith('/api/')) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405).end('method not allowed');
      return;
    }
    serveStatic(route, res);
    return;
  }

  if (!originOk(req)) {
    res.writeHead(403).end('bad origin');
    return;
  }
  if (!authorised(req, url)) {
    res.writeHead(401).end('bad token');
    return;
  }

  const post = req.method === 'POST';
  try {
    if (route === '/api/hello' && req.method === 'GET') {
      sendJson(res, 200, { ok: true, connected: state.connected });
    } else if (route === '/api/stream' && req.method === 'GET') {
      serveStream(req, res);
    } else if (route === '/api/send' && post) {
      const body = await readJson(req);
      const text = body && typeof body.text === 'string' ? body.text.trim() : '';
      if (!text) {
        sendJson(res, 400, { error: 'no text' });
        return;
      }
      enqueue({ type: 'send', text });
      sendJson(res, 202, { queued: true });
    } else if ((route === '/api/abort' || route === '/api/clear') && post) {
      enqueue({ type: route.slice(5) });
      sendJson(res, 202, { queued: true });
    } else if (route === '/api/permission' && post) {
      const body = await readJson(req);
      if (!body || typeof body.id !== 'string') {
        sendJson(res, 400, { error: 'no id' });
        return;
      }
      enqueue({
        type: 'permission',
        id: body.id,
        allow: body.allow === true,
        remember: body.remember === true,
      });
      sendJson(res, 202, { queued: true });
    } else if (route === '/api/agent/inbox' && req.method === 'GET') {
      serveInbox(req, res);
    } else if (route === '/api/agent/events' && post) {
      await serveEvents(req, res);
    } else {
      sendJson(res, 404, { error: 'no such route' });
    }
  } catch (err) {
    if (!res.headersSent) sendJson(res, 400, { error: String(err && err.message || err) });
  }
});

// A poll that stops arriving is the only signal the game has gone: it has no way
// to tell us on the way out if the client closed.
setInterval(() => {
  if (state.connected && Date.now() - state.lastSeen > STALE_MS) {
    announceConnection(false);
  }
}, 5000).unref();

server.listen(PORT, HOST, () => {
  const origin = `http://${HOST}:${PORT}`;
  // The token rides in the fragment, which browsers never send to a server and
  // nothing logs. The page reads it once and keeps it, so this link is the whole
  // setup on the browser side.
  process.stdout.write(
    `\n  UAI bridge on ${origin}\n\n` +
    `  Open    ${origin}/#t=${TOKEN}\n` +
    `  Token   ${TOKEN}\n` +
    `          ^ paste into UAI Settings -> Web bridge\n\n` +
    `  Loopback only. Whoever reaches this drives an agent that can run code\n` +
    `  on this machine, so treat the token like a password. Ctrl+C to stop.\n\n`
  );
});

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    process.stderr.write(`\n  Port ${PORT} is already in use. Try --port ${PORT + 1}.\n\n`);
    process.exit(1);
  }
  throw err;
});






