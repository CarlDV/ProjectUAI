'use strict';

// The browser half of the bridge. Talks to the local node process only: it never
// speaks to the game or to any model directly.

const STORE_KEY = 'uai.token';

// The bridge prints a link with the token in the fragment. A fragment is never
// sent to a server and never lands in a log, so this is the cheap way to get the
// secret into the page without asking anyone to retype 64 hex characters. It is
// consumed immediately and scrubbed from the address bar.
function harvestToken() {
  const match = /[#&]t=([0-9a-f]{64})/i.exec(location.hash || '');
  if (!match) return null;
  history.replaceState(null, '', location.pathname);
  return match[1];
}

let token = harvestToken() || localStorage.getItem(STORE_KEY) || '';

const $ = (id) => document.getElementById(id);
const gate = $('gate');
const app = $('app');
const transcript = $('transcript');
const statusText = $('status');
const dot = $('dot');
const input = $('input');
const sendButton = $('send');
const stopButton = $('stop');

function api(path, body) {
  return fetch('/api' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      Authorization: 'Bearer ' + token,
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// Rendering ------------------------------------------------------------------
//
// Everything below builds nodes and assigns textContent. Nothing interpolates
// event data into HTML: a tool result carries whatever was in the game, and a
// place name or a chat log is not something to hand to an HTML parser.

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// Autoscroll only when the reader is already at the bottom, so scrolling up to
// read something is not undone by the next tool call.
function nearBottom() {
  return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 80;
}

function place(node) {
  const stick = nearBottom();
  transcript.appendChild(node);
  if (stick) transcript.scrollTop = transcript.scrollHeight;
  return node;
}

function say(who, text, extra) {
  const row = el('div', 'row ' + (extra || ''));
  row.appendChild(el('div', 'who', who));
  row.appendChild(el('div', 'body', text));
  return place(row);
}

function note(text) {
  return place(el('div', 'row note', text));
}

// A tool call and its result arrive as two events. The call opens a collapsed row
// and this keeps the handle, so the result lands inside the row it belongs to
// instead of below it as a second, orphaned line.
const toolRows = new Map();

function summarise(args) {
  if (args === undefined || args === null || args === '') return '';
  let value = args;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      return value.replace(/\s+/g, ' ').slice(0, 160);
    }
  }
  if (typeof value !== 'object') return String(value);
  return Object.entries(value)
    .map(([key, item]) => key + '=' + String(
      item !== null && typeof item === 'object' ? JSON.stringify(item) : item
    ).replace(/\s+/g, ' '))
    .join('  ')
    .slice(0, 160);
}

function openTool(event) {
  const box = el('details', 'tool');
  const head = el('summary');
  head.appendChild(el('span', 'name', event.name || 'tool'));
  head.appendChild(el('span', 'args', summarise(event.arguments)));
  const verdict = el('span', 'verdict', 'running');
  head.appendChild(verdict);
  box.appendChild(head);
  place(box);
  if (event.id) toolRows.set(event.id, { box, verdict });
  return box;
}

function closeTool(event, ok) {
  const entry = event.id ? toolRows.get(event.id) : null;
  const box = entry ? entry.box : openTool(event);
  const verdict = entry ? entry.verdict : box.querySelector('.verdict');
  box.classList.add(ok ? 'ok' : 'failed');
  if (verdict) verdict.textContent = ok ? 'ok' : 'failed';
  const text = typeof event.text === 'string' ? event.text : '';
  if (text) box.appendChild(el('pre', null, text));
  if (!ok) box.open = true;
  if (event.id) toolRows.delete(event.id);
}

// Permission prompts. The in-game panel answers these by calling a resolve
// function the agent handed it; from here the answer travels back as a command
// and the game calls the same function. Without this the default "ask" mode
// leaves a browser user watching a turn stall until it times itself out.
function askPermission(event) {
  const card = el('div', 'ask');
  const title = el('h3');
  title.appendChild(document.createTextNode('Allow '));
  title.appendChild(el('code', null, event.name || 'tool'));
  title.appendChild(document.createTextNode('?'));
  card.appendChild(title);
  if (event.description) card.appendChild(el('p', null, event.description));
  const args = summarise(event.args);
  if (args) card.appendChild(el('p', null, args));

  const buttons = el('div', 'buttons');
  const allow = el('button', null, 'Allow');
  const deny = el('button', 'danger', 'Deny');
  const label = el('label');
  const remember = el('input');
  remember.type = 'checkbox';
  label.appendChild(remember);
  label.appendChild(document.createTextNode('remember'));
  buttons.append(allow, deny, label);
  card.appendChild(buttons);

  const answer = (granted) => {
    card.classList.add('done');
    card.appendChild(el('p', null, granted ? 'allowed' : 'denied'));
    api('/permission', {
      id: event.id,
      allow: granted,
      remember: remember.checked,
    }).catch(() => {});
  };
  allow.addEventListener('click', () => answer(true));
  deny.addEventListener('click', () => answer(false));

  return place(card);
}

// Event dispatch -------------------------------------------------------------

let busy = false;

function setBusy(next) {
  busy = next;
  stopButton.hidden = !next;
  sendButton.disabled = next;
}

function apply(event) {
  switch (event.kind) {
    case 'bridge:snapshot':
      transcript.replaceChildren();
      toolRows.clear();
      for (const past of event.events || []) apply(past);
      transcript.scrollTop = transcript.scrollHeight;
      break;
    case 'bridge:game':
      dot.classList.toggle('live', event.connected === true);
      if (event.connected !== true) {
        statusText.textContent = 'game not connected';
        setBusy(false);
      }
      break;
    case 'user': say('you', event.text || ''); break;
    case 'assistant:text': say('uai', event.text || '', 'agent'); break;
    case 'tool:call': openTool(event); break;
    case 'tool:result': closeTool(event, true); break;
    case 'tool:error': closeTool(event, false); break;
    case 'tool:progress': note(event.text || ''); break;
    case 'permission:ask': askPermission(event); break;
    case 'status':
      statusText.textContent = event.text || '';
      setBusy((event.text || 'Ready') !== 'Ready');
      break;
    case 'error': say('error', event.message || 'something failed', 'bad'); break;
    case 'abort': note('stopped'); break;
    case 'cleared':
      transcript.replaceChildren();
      toolRows.clear();
      break;
    case 'provider:switch': note('switched to ' + (event.to || event.name || 'another provider')); break;
    case 'subagent:start': note('subagent: ' + (event.task || 'dispatched')); break;
    case 'subagent:done': note('subagent finished'); break;
    default: break; // reasoning, usage, request:*, compact, turn:* are not shown here
  }
}

// Composer -------------------------------------------------------------------

function grow() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px';
}

async function submit() {
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  grow();
  const res = await api('/send', { text }).catch(() => null);
  // The queue accepted it; whether the agent was free to take it is answered by
  // the events that follow, not by this response.
  if (!res || !res.ok) note('could not reach the bridge');
}

sendButton.addEventListener('click', submit);
stopButton.addEventListener('click', () => api('/abort', {}).catch(() => {}));
$('clear').addEventListener('click', () => api('/clear', {}).catch(() => {}));

input.addEventListener('input', grow);
input.addEventListener('keydown', (ev) => {
  // Enter sends, shift+enter breaks the line -- the convention every chat client
  // in this shape uses, and the one the in-game composer already follows.
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    submit();
  }
});

// Connection -----------------------------------------------------------------

let stream = null;

function connect() {
  if (stream) stream.close();
  stream = new EventSource('/api/stream?token=' + encodeURIComponent(token));
  stream.addEventListener('message', (ev) => {
    let event = null;
    try {
      event = JSON.parse(ev.data);
    } catch {
      return;
    }
    if (event && typeof event === 'object') apply(event);
  });
  // EventSource retries on its own, so there is nothing to do here but say the
  // bridge is the thing that went away rather than the game.
  stream.addEventListener('error', () => {
    statusText.textContent = 'bridge unreachable, retrying';
    dot.classList.remove('live');
  });
}

function start() {
  localStorage.setItem(STORE_KEY, token);
  gate.hidden = true;
  app.hidden = false;
  connect();
  input.focus();
}

// Checked against a cheap authenticated route rather than by opening the stream,
// because an EventSource rejected with a 401 reports the same opaque error as a
// bridge that is not running, and those need different messages.
async function accepted(candidate) {
  const previous = token;
  token = candidate;
  const res = await api('/hello').catch(() => null);
  if (res && res.ok) return true;
  token = previous;
  return false;
}

$('gate-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const error = $('gate-error');
  error.hidden = true;
  if (await accepted($('gate-token').value.trim())) {
    start();
    return;
  }
  error.textContent = 'That token was refused. Check the bridge console.';
  error.hidden = false;
});

(async function boot() {
  if (token && (await accepted(token))) {
    start();
    return;
  }
  // A stored token is stale every time the bridge restarts, which is by design.
  localStorage.removeItem(STORE_KEY);
  gate.hidden = false;
  $('gate-token').focus();
})();






