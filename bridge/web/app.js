'use strict';

// ============================================================================
// Project UAI Web Bridge Application
// Sleek, minimalist chat interface inspired by Anywhere Relay (ai.davidcsl.me)
// Dual-mode: Live loopback SSE bridge & Live Server simulation testing
// ============================================================================

const STORE_KEY = 'uai.token';

function harvestToken() {
  const match = /[#&]t=([0-9a-f]{64})/i.exec(location.hash || '');
  if (!match) return null;
  history.replaceState(null, '', location.pathname);
  return match[1];
}

let token = harvestToken() || localStorage.getItem(STORE_KEY) || '';

const $ = (id) => document.getElementById(id);

// Elements
const gate = $('gate');
const app = $('app');
const transcript = $('transcript');
const welcomeState = $('welcomeState');
const statusText = $('status');
const dot = $('dot');
const input = $('input');
const sendButton = $('send');
const stopButton = $('stop');
const scrollToBottomBtn = $('scrollToBottom');
const clearBtn = $('clear');
const activeModelLabel = $('activeModelLabel');
const topTokenCount = $('topTokenCount');

// Composer pills & popups
const composerToolsPill = $('composerToolsPill');
const modelSelectorPill = $('modelSelectorPill');
const modelSelectorMenu = $('modelSelectorMenu');
const quickPromptsPill = $('quickPromptsPill');
const quickPromptsMenu = $('quickPromptsMenu');

// Drawer elements
const sidebarToggle = $('sidebarToggle');
const toolsDrawerBtn = $('toolsDrawerBtn');
const telemetryDrawerBtn = $('telemetryDrawerBtn');
const featuresDrawer = $('featuresDrawer');
const drawerOverlay = $('drawerOverlay');
const drawerCloseBtn = $('drawerCloseBtn');

// State
let isSimulationMode = false;
let isBusy = false;
let autoScroll = true;
let currentModelName = 'Claude 3.7 Sonnet';
const transcriptEvents = [];
const toolRows = new Map();
const subagentRecords = new Map();

// Telemetry Counters
const stats = {
  totalTokens: 0,
  promptTokens: 0,
  completionTokens: 0,
  messages: 0,
  tools: 0,
  startTime: Date.now(),
};

// ============================================================================
// API
// ============================================================================

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

// ============================================================================
// Safe Markdown Formatter
// ============================================================================

function escapeHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function renderMarkdown(rawText) {
  if (!rawText) return '';
  let text = String(rawText);

  // Extract code blocks
  const codeBlocks = [];
  text = text.replace(/```([a-zA-Z0-9_\-]*)\n([\s\S]*?)```/g, (_, lang, code) => {
    const placeholder = `__CODE_BLOCK_${codeBlocks.length}__`;
    codeBlocks.push({ lang: (lang || 'code').toLowerCase(), code });
    return placeholder;
  });

  text = escapeHtml(text);

  // Headers
  text = text.replace(/^### (.*$)/gim, '<h3>$1</h3>');
  text = text.replace(/^## (.*$)/gim, '<h2>$1</h2>');
  text = text.replace(/^# (.*$)/gim, '<h1>$1</h1>');

  // Blockquotes
  text = text.replace(/^\> (.*$)/gim, '<blockquote>$1</blockquote>');

  // Bold & Italic
  text = text.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
  text = text.replace(/\*(.*?)\*/g, '<em>$1</em>');

  // Inline code
  text = text.replace(/`([^`]+)`/g, '<code>$1</code>');

  // Lists
  text = text.replace(/^\s*[\-\*]\s+(.*$)/gim, '<li>$1</li>');
  text = text.replace(/(<li>.*<\/li>)/s, '<ul>$1</ul>');

  // Paragraphs
  const paragraphs = text.split(/\n\s*\n/);
  text = paragraphs
    .map(p => {
      p = p.trim();
      if (!p) return '';
      if (p.startsWith('<h') || p.startsWith('<ul>') || p.startsWith('<blockquote>') || p.startsWith('__CODE_BLOCK_')) {
        return p;
      }
      return `<p>${p.replace(/\n/g, '<br>')}</p>`;
    })
    .join('');

  // Re-insert code blocks with copy button
  codeBlocks.forEach((block, idx) => {
    const escapedCode = escapeHtml(block.code.trim());
    const blockHtml = `
      <div class="code-container">
        <div class="code-header">
          <span>${block.lang}</span>
          <button type="button" class="copy-btn" data-code="${encodeURIComponent(block.code.trim())}">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
            </svg>
            <span>Copy</span>
          </button>
        </div>
        <pre><code>${escapedCode}</code></pre>
      </div>
    `;
    text = text.replace(`__CODE_BLOCK_${idx}__`, blockHtml);
  });

  return text;
}

// Copy Code Button Delegated Handler
document.addEventListener('click', (ev) => {
  const btn = ev.target.closest('.copy-btn');
  if (!btn) return;
  const rawCode = decodeURIComponent(btn.getAttribute('data-code') || '');
  if (!rawCode) return;
  navigator.clipboard.writeText(rawCode).then(() => {
    const span = btn.querySelector('span');
    if (span) {
      const orig = span.textContent;
      span.textContent = 'Copied';
      btn.style.color = '#34d399';
      setTimeout(() => {
        span.textContent = orig;
        btn.style.color = '';
      }, 2000);
    }
  }).catch(() => {});
});

// ============================================================================
// DOM Utilities
// ============================================================================

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function nearBottom() {
  return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 120;
}

function updateScrollButton() {
  if (!scrollToBottomBtn) return;
  const isUp = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight > 180;
  scrollToBottomBtn.hidden = !isUp;
}

function place(node, eventData) {
  if (welcomeState) welcomeState.hidden = true;
  const stick = autoScroll && nearBottom();
  transcript.appendChild(node);
  if (eventData) {
    node.__eventData = eventData;
    transcriptEvents.push({ node, data: eventData });
  }
  if (stick) {
    transcript.scrollTop = transcript.scrollHeight;
  }
  updateScrollButton();
  return node;
}

// ============================================================================
// Message Rendering (Matches Screenshot: YOU with left line, Model label)
// ============================================================================

function say(who, text, extra) {
  const isUser = who.toLowerCase() === 'you' || extra === 'user';
  const isAgent = who.toLowerCase() === 'uai' || extra === 'agent';
  const isError = who.toLowerCase() === 'error' || extra === 'bad';

  const row = el('div', `msg-row ${isUser ? 'user' : ''} ${isAgent ? 'agent' : ''} ${isError ? 'bad' : ''}`);

  // Header: Tracked uppercase label (e.g. YOU or GPT 5.6 SOL or CLAUDE 3.7 SONNET)
  let senderLabel = isUser ? 'YOU' : currentModelName.toUpperCase();
  if (isError) senderLabel = 'SYSTEM ERROR';

  const header = el('div', 'msg-header', senderLabel);
  row.appendChild(header);

  // Body
  if (isError) {
    const errBox = el('div', 'msg-error-box', text);
    row.appendChild(errBox);
  } else if (isAgent) {
    const body = el('div', 'msg-body');
    body.innerHTML = renderMarkdown(text);
    row.appendChild(body);
  } else {
    // User message with white line indicator on left (from screenshot)
    const body = el('div', 'msg-body', text);
    row.appendChild(body);
  }

  stats.messages++;
  updateStatsDisplay();

  return place(row, { type: isUser ? 'user' : (isError ? 'bad' : 'agent'), text });
}

function note(text) {
  const row = el('div', 'msg-row');
  const body = el('div', 'msg-body');
  body.style.borderLeft = '2px solid var(--border-medium)';
  body.style.color = 'var(--text-tertiary)';
  body.style.fontSize = '12.5px';
  body.textContent = text;
  row.appendChild(body);
  return place(row, { type: 'note', text });
}

function summarise(args) {
  if (args === undefined || args === null || args === '') return '';
  let value = args;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      return value.replace(/\s+/g, ' ').slice(0, 120);
    }
  }
  if (typeof value !== 'object') return String(value);
  return Object.entries(value)
    .map(([key, item]) => `${key}=${typeof item === 'object' && item !== null ? JSON.stringify(item) : item}`)
    .join('  ')
    .slice(0, 120);
}

// Collapsible Tool Accordion
function openTool(event) {
  const box = el('details', 'tool-accordion');
  const head = el('summary');
  head.appendChild(el('span', 'tool-arrow', '▸'));
  head.appendChild(el('span', 'tool-name-tag', event.name || 'tool'));
  head.appendChild(el('span', 'tool-summary-args', summarise(event.arguments)));

  const verdict = el('span', 'tool-status-pill running', 'running');
  head.appendChild(verdict);
  box.appendChild(head);

  // Content
  const bodyDetails = el('div', 'tool-details-content');
  const argsPre = el('pre', null, typeof event.arguments === 'object' ? JSON.stringify(event.arguments, null, 2) : String(event.arguments || '{}'));
  bodyDetails.appendChild(argsPre);
  box.appendChild(bodyDetails);

  place(box, { type: 'tool', name: event.name, args: event.arguments });
  if (event.id) toolRows.set(event.id, { box, verdict, bodyDetails });

  stats.tools++;
  updateStatsDisplay();

  return box;
}

function closeTool(event, ok) {
  const entry = event.id ? toolRows.get(event.id) : null;
  const box = entry ? entry.box : openTool(event);
  const verdict = entry ? entry.verdict : box.querySelector('.tool-status-pill');
  const bodyDetails = entry ? entry.bodyDetails : box.querySelector('.tool-details-content');

  box.classList.remove('running');
  box.classList.add(ok ? 'ok' : 'failed');
  if (verdict) {
    verdict.className = 'tool-status-pill ' + (ok ? 'ok' : 'failed');
    verdict.textContent = ok ? 'ok' : 'failed';
  }

  const text = typeof event.text === 'string' ? event.text : (event.result || '');
  if (text && bodyDetails) {
    const resultPre = el('pre', null, text);
    resultPre.style.borderTop = '1px solid var(--border-subtle)';
    resultPre.style.marginTop = '8px';
    resultPre.style.paddingTop = '8px';
    bodyDetails.appendChild(resultPre);
  }

  if (!ok) box.open = true;
  if (event.id) toolRows.delete(event.id);
}

// Subagent Card
function renderSubagent(event) {
  const card = el('div', 'subagent-card');
  card.appendChild(el('div', 'subagent-card-title', '🤖 SUBAGENT DISPATCH'));
  card.appendChild(el('div', 'subagent-card-text', event.task || 'Analyzing environment and game hierarchy…'));

  if (event.id) {
    subagentRecords.set(event.id, {
      id: event.id,
      task: event.task,
      preset: event.preset || 'general',
      status: 'running',
    });
    renderDrawerSubagents();
  }

  return place(card, { type: 'subagent', data: event });
}

// Permission Card
function askPermission(event) {
  const card = el('div', 'ask-card');
  const title = el('div', 'ask-title');
  title.appendChild(document.createTextNode('Authorize in-game execution: '));
  title.appendChild(el('code', null, event.name || 'tool'));
  title.appendChild(document.createTextNode('?'));
  card.appendChild(title);

  if (event.description) card.appendChild(el('p', null, event.description));

  const argsText = summarise(event.args || event.arguments);
  if (argsText) {
    const p = el('p', null, `Arguments: ${argsText}`);
    p.style.fontFamily = 'var(--font-mono)';
    p.style.fontSize = '12px';
    p.style.color = 'var(--text-tertiary)';
    card.appendChild(p);
  }

  const btns = el('div', 'ask-btns');
  const allowBtn = el('button', 'btn-auth', 'Authorize & Run');
  const denyBtn = el('button', 'btn-deny', 'Deny');

  btns.append(allowBtn, denyBtn);
  card.appendChild(btns);

  const answer = (granted) => {
    card.classList.add('done');
    const noteEl = el('p', null, granted ? '✓ Authorized' : '✕ Denied');
    noteEl.style.fontSize = '12px';
    noteEl.style.color = granted ? 'var(--color-green)' : 'var(--color-danger)';
    card.appendChild(noteEl);

    if (isSimulationMode) {
      note(`Permission ${granted ? 'granted' : 'denied'} for ${event.name}`);
      return;
    }

    api('/permission', {
      id: event.id,
      allow: granted,
      remember: true,
    }).catch(() => {});
  };

  allowBtn.addEventListener('click', () => answer(true));
  denyBtn.addEventListener('click', () => answer(false));

  return place(card, { type: 'permission', data: event });
}

// ============================================================================
// Event Dispatcher
// ============================================================================

function setBusy(next) {
  isBusy = next;
  if (stopButton) stopButton.hidden = !next;
  if (sendButton) sendButton.disabled = next;
}

function apply(event) {
  if (!event || typeof event !== 'object') return;

  switch (event.kind) {
    case 'bridge:snapshot':
      transcript.replaceChildren();
      toolRows.clear();
      transcriptEvents.length = 0;
      for (const past of event.events || []) apply(past);
      transcript.scrollTop = transcript.scrollHeight;
      break;

    case 'bridge:game':
      if (event.connected) {
        dot.className = 'status-dot';
        statusText.textContent = 'bridge';
      } else {
        dot.className = 'status-dot warn';
        statusText.textContent = 'disconnected';
        setBusy(false);
      }
      break;

    case 'user':
      say('you', event.text || '', 'user');
      break;

    case 'assistant:text':
      say('uai', event.text || '', 'agent');
      break;

    case 'tool:call':
      openTool(event);
      break;

    case 'tool:result':
      closeTool(event, true);
      break;

    case 'tool:error':
      closeTool(event, false);
      break;

    case 'tool:progress':
      note(`[tool] ${event.text || ''}`);
      break;

    case 'permission:ask':
      askPermission(event);
      break;

    case 'status':
      statusText.textContent = event.text || 'bridge';
      setBusy((event.text || 'Ready') !== 'Ready');
      break;

    case 'error':
      say('error', event.message || 'Unknown error', 'bad');
      break;

    case 'abort':
      note('Agent turn stopped by operator.');
      setBusy(false);
      break;

    case 'cleared':
      transcript.replaceChildren();
      toolRows.clear();
      transcriptEvents.length = 0;
      if (welcomeState) {
        welcomeState.hidden = false;
        transcript.appendChild(welcomeState);
      }
      break;

    case 'provider:switch':
      note(`Switched provider to ${event.to || event.name || 'fallback'}`);
      if (activeModelLabel && (event.to || event.name)) {
        currentModelName = event.to || event.name;
        activeModelLabel.textContent = currentModelName.toLowerCase();
      }
      break;

    case 'subagent:start':
      renderSubagent(event);
      break;

    case 'subagent:done':
      note(`Subagent completed.`);
      if (event.id && subagentRecords.has(event.id)) {
        subagentRecords.get(event.id).status = 'completed';
        renderDrawerSubagents();
      }
      break;

    default:
      break;
  }
}

// ============================================================================
// Composer & Input
// ============================================================================

function grow() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 180) + 'px';
}

async function submit() {
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  grow();

  closeMenus();

  if (isSimulationMode) {
    runSimulatedTurn(text);
    return;
  }

  say('you', text, 'user');
  const res = await api('/send', { text }).catch(() => null);
  if (!res || !res.ok) {
    note('Could not reach the local bridge server (bridge/server.js).');
  }
}

sendButton.addEventListener('click', submit);
stopButton.addEventListener('click', () => {
  if (isSimulationMode) {
    note('Simulated turn interrupted.');
    setBusy(false);
    return;
  }
  api('/abort', {}).catch(() => {});
});

clearBtn.addEventListener('click', () => {
  if (isSimulationMode) {
    transcript.replaceChildren();
    transcriptEvents.length = 0;
    if (welcomeState) {
      welcomeState.hidden = false;
      transcript.appendChild(welcomeState);
    }
    stats.messages = 0;
    stats.tools = 0;
    updateStatsDisplay();
    return;
  }
  api('/clear', {}).catch(() => {});
});

input.addEventListener('input', grow);
input.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    submit();
  }
});

// Scroll to bottom button
transcript.addEventListener('scroll', updateScrollButton);
if (scrollToBottomBtn) {
  scrollToBottomBtn.addEventListener('click', () => {
    transcript.scrollTop = transcript.scrollHeight;
    scrollToBottomBtn.hidden = true;
  });
}

// ============================================================================
// Popups (Model Selector & Quick Prompts)
// ============================================================================

function closeMenus() {
  if (modelSelectorMenu) modelSelectorMenu.hidden = true;
  if (quickPromptsMenu) quickPromptsMenu.hidden = true;
}

if (modelSelectorPill && modelSelectorMenu) {
  modelSelectorPill.addEventListener('click', (ev) => {
    ev.stopPropagation();
    const isHidden = modelSelectorMenu.hidden;
    closeMenus();
    modelSelectorMenu.hidden = !isHidden;
  });
}

if (quickPromptsPill && quickPromptsMenu) {
  quickPromptsPill.addEventListener('click', (ev) => {
    ev.stopPropagation();
    const isHidden = quickPromptsMenu.hidden;
    closeMenus();
    quickPromptsMenu.hidden = !isHidden;
  });
}

document.addEventListener('click', (ev) => {
  if (!ev.target.closest('.popup-menu') && !ev.target.closest('.composer-pill')) {
    closeMenus();
  }
});

// Model selection
document.querySelectorAll('#modelSelectorMenu .popup-menu-item').forEach(item => {
  item.addEventListener('click', () => {
    document.querySelectorAll('#modelSelectorMenu .popup-menu-item').forEach(i => i.classList.remove('active'));
    item.classList.add('active');
    currentModelName = item.getAttribute('data-model') || 'Claude 3.7 Sonnet';
    if (activeModelLabel) activeModelLabel.textContent = currentModelName.toLowerCase();
    closeMenus();
  });
});

// Quick prompt insertion
document.querySelectorAll('#quickPromptsMenu .popup-menu-item').forEach(item => {
  item.addEventListener('click', () => {
    const prompt = item.getAttribute('data-prompt');
    if (prompt) {
      input.value = prompt;
      grow();
      input.focus();
    }
    closeMenus();
  });
});

// ============================================================================
// Slide-Over Drawer
// ============================================================================

function openDrawer(tabName) {
  closeMenus();
  if (featuresDrawer) featuresDrawer.hidden = false;
  if (drawerOverlay) drawerOverlay.hidden = false;

  if (tabName) {
    document.querySelectorAll('.drawer-tab').forEach(t => {
      t.classList.toggle('active', t.getAttribute('data-tab') === tabName);
    });
    document.querySelectorAll('.drawer-tab-content').forEach(c => {
      c.hidden = c.id !== ('drawerTab' + tabName.charAt(0).toUpperCase() + tabName.slice(1));
    });
  }
  renderDrawerTools();
}

function closeDrawer() {
  if (featuresDrawer) featuresDrawer.hidden = true;
  if (drawerOverlay) drawerOverlay.hidden = true;
}

if (sidebarToggle) sidebarToggle.addEventListener('click', () => openDrawer('tools'));
if (toolsDrawerBtn) toolsDrawerBtn.addEventListener('click', () => openDrawer('tools'));
if (composerToolsPill) composerToolsPill.addEventListener('click', () => openDrawer('tools'));
if (telemetryDrawerBtn) telemetryDrawerBtn.addEventListener('click', () => openDrawer('telemetry'));
if (drawerOverlay) drawerOverlay.addEventListener('click', closeDrawer);
if (drawerCloseBtn) drawerCloseBtn.addEventListener('click', closeDrawer);

// Drawer tab switches
document.querySelectorAll('.drawer-tab').forEach(tab => {
  tab.addEventListener('click', () => {
    const target = tab.getAttribute('data-tab');
    document.querySelectorAll('.drawer-tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');

    document.querySelectorAll('.drawer-tab-content').forEach(c => {
      c.hidden = c.id !== ('drawerTab' + target.charAt(0).toUpperCase() + target.slice(1));
    });
  });
});

// ============================================================================
// In-Game 60+ Tool Catalog
// ============================================================================

const TOOLS_CATALOG = [
  // Instance (7)
  { name: 'instance_find', group: 'instance', desc: 'Find instances matching class name or parent hierarchy.' },
  { name: 'instance_get', group: 'instance', desc: 'Read detailed properties, attributes and tags of an instance.' },
  { name: 'instance_set', group: 'instance', desc: 'Set property values or attributes on a specific instance.' },
  { name: 'instance_call', group: 'instance', desc: 'Invoke an allowed engine method on an instance.' },
  { name: 'instance_tree', group: 'instance', desc: 'Generate an ASCII or structured JSON hierarchy tree.' },
  { name: 'instance_delete', group: 'instance', desc: 'Destroy an instance and remove it from DataModel.' },
  { name: 'instance_create', group: 'instance', desc: 'Instantiate a new Part, Model or Folder.' },

  // Character (4)
  { name: 'character_move', group: 'character', desc: 'Move local character to target 3D coordinates using MoveTo.' },
  { name: 'character_jump', group: 'character', desc: 'Trigger the Humanoid Jump state.' },
  { name: 'character_look_at', group: 'character', desc: 'Pivot character or camera to orient toward a point.' },
  { name: 'character_equip', group: 'character', desc: 'Equip or unequip a Tool from Backpack to Character.' },

  // Players (4)
  { name: 'player_list', group: 'players', desc: 'Retrieve full list of active server players and UserIds.' },
  { name: 'player_get', group: 'players', desc: 'Get leaderstats, team, character status and distance.' },
  { name: 'player_teleport', group: 'players', desc: 'Teleport local character directly to target player.' },
  { name: 'player_chat', group: 'players', desc: 'Send a message to public in-game TextChatService.' },

  // World (3)
  { name: 'world_raycast', group: 'world', desc: 'Cast a ray from origin to direction and return hit part.' },
  { name: 'world_get_parts', group: 'world', desc: 'Find parts in a bounding box, sphere or radius.' },
  { name: 'world_ambient', group: 'world', desc: 'Read Lighting ClockTime, Fog, and atmosphere data.' },

  // Remotes (3)
  { name: 'remote_fire', group: 'remotes', desc: 'Fire a RemoteEvent with arbitrary payload arguments.' },
  { name: 'remote_invoke', group: 'remotes', desc: 'Invoke a RemoteFunction and return server response.' },
  { name: 'remote_spy', group: 'remotes', desc: 'Log outbound network remote calls and signatures.' },

  // Script (3)
  { name: 'script_decomp', group: 'script', desc: 'Decompile a LocalScript or ModuleScript into Luau source.' },
  { name: 'script_source', group: 'script', desc: 'Read script source accessible by executor capabilities.' },
  { name: 'script_dump', group: 'script', desc: 'Disassemble bytecode constants and proto tables.' },

  // Filesystem (3)
  { name: 'fs_read', group: 'fs', desc: 'Read text or JSON configuration from local folder.' },
  { name: 'fs_write', group: 'fs', desc: 'Write state to local executor storage.' },
  { name: 'fs_list', group: 'fs', desc: 'List files and subdirectories in workspace.' },

  // Performance (3)
  { name: 'perf_fps', group: 'perf', desc: 'Measure client render framerate, delta time and hitch frequency.' },
  { name: 'perf_memory', group: 'perf', desc: 'Query Stats:GetTotalMemoryUsageMb() by tag.' },
  { name: 'perf_ping', group: 'perf', desc: 'Measure round-trip server network latency in ms.' },

  // Subagents (3)
  { name: 'dispatch_agent', group: 'agentself', desc: 'Spawn a nested autonomous subagent with goal and turns.' },
  { name: 'agent_followup', group: 'agentself', desc: 'Resume a finished subagent session with follow-up task.' },
  { name: 'subagent_status', group: 'agentself', desc: 'Query progress and active tool invocation of a child agent.' },
];

let activeDrawerCategory = 'all';
let drawerSearchQuery = '';

function renderDrawerTools() {
  const container = $('drawerToolsList');
  if (!container) return;
  container.innerHTML = '';

  const filtered = TOOLS_CATALOG.filter(t => {
    const matchCat = activeDrawerCategory === 'all' || t.group === activeDrawerCategory;
    const matchQ = !drawerSearchQuery || t.name.toLowerCase().includes(drawerSearchQuery) || t.desc.toLowerCase().includes(drawerSearchQuery);
    return matchCat && matchQ;
  });

  filtered.forEach(tool => {
    const card = el('div', 'drawer-tool-card');
    card.innerHTML = `
      <div style="display:flex; justify-content:space-between; align-items:center;">
        <span class="drawer-tool-name">${tool.name}</span>
        <span style="font-size:10px; color:var(--text-tertiary); text-transform:uppercase;">${tool.group}</span>
      </div>
      <div class="drawer-tool-desc">${tool.desc}</div>
      <button type="button" class="drawer-tool-action">Insert prompt</button>
    `;
    card.querySelector('.drawer-tool-action').addEventListener('click', () => {
      input.value = `Execute tool: ${tool.name} to inspect ${tool.group}`;
      grow();
      closeDrawer();
      input.focus();
    });
    container.appendChild(card);
  });
}

document.querySelectorAll('#drawerCategoryPills .cat-pill').forEach(pill => {
  pill.addEventListener('click', () => {
    document.querySelectorAll('#drawerCategoryPills .cat-pill').forEach(p => p.classList.remove('active'));
    pill.classList.add('active');
    activeDrawerCategory = pill.getAttribute('data-cat') || 'all';
    renderDrawerTools();
  });
});

const drawerToolSearch = $('drawerToolSearch');
if (drawerToolSearch) {
  drawerToolSearch.addEventListener('input', () => {
    drawerSearchQuery = drawerToolSearch.value.trim().toLowerCase();
    renderDrawerTools();
  });
}

// Subagents in Drawer
function renderDrawerSubagents() {
  const container = $('subagentsList');
  const countBadge = $('activeSubagentsCount');
  if (!container) return;

  const list = Array.from(subagentRecords.values());
  if (countBadge) countBadge.textContent = `${list.filter(s => s.status === 'running').length} active`;

  if (list.length === 0) {
    container.innerHTML = '<div style="font-size:12px; color:var(--text-tertiary); padding:16px 0;">No active subagents.</div>';
    return;
  }

  container.innerHTML = '';
  list.forEach(rec => {
    const item = el('div', 'drawer-tool-card');
    item.innerHTML = `
      <div style="display:flex; justify-content:space-between;">
        <strong style="color:var(--color-coral); font-size:12px;">${rec.preset}</strong>
        <span style="font-size:10px; text-transform:uppercase;">${rec.status}</span>
      </div>
      <div style="font-size:12px; color:var(--text-primary); margin-top:2px;">${rec.task}</div>
    `;
    container.appendChild(item);
  });
}

// Telemetry in Drawer
function updateStatsDisplay() {
  const total = $('statTotalTokens');
  const prompt = $('statPromptTokens');
  const comp = $('statCompletionTokens');
  const cost = $('statCost');
  const msgs = $('statMessages');
  const tools = $('statTools');

  if (total) total.textContent = stats.totalTokens.toLocaleString();
  if (prompt) prompt.textContent = stats.promptTokens.toLocaleString();
  if (comp) comp.textContent = stats.completionTokens.toLocaleString();
  if (msgs) msgs.textContent = stats.messages;
  if (tools) tools.textContent = stats.tools;

  if (topTokenCount) {
    topTokenCount.textContent = `${stats.totalTokens.toLocaleString()} tok`;
  }

  const costVal = (stats.promptTokens * 0.000003) + (stats.completionTokens * 0.000015);
  if (cost) cost.textContent = `$${costVal.toFixed(4)}`;
}

// Session Uptime
setInterval(() => {
  const uptimeEl = $('diagUptime');
  if (!uptimeEl) return;
  const sec = Math.floor((Date.now() - stats.startTime) / 1000);
  const h = String(Math.floor(sec / 3600)).padStart(2, '0');
  const m = String(Math.floor((sec % 3600) / 60)).padStart(2, '0');
  const s = String(sec % 60).padStart(2, '0');
  uptimeEl.textContent = `${h}:${m}:${s}`;
}, 1000);

// Setting Auto-Scroll
const settingAutoScroll = $('settingAutoScroll');
if (settingAutoScroll) {
  settingAutoScroll.addEventListener('change', () => {
    autoScroll = settingAutoScroll.checked;
  });
}

// Export Markdown & JSON
const btnExportMarkdown = $('btnExportMarkdown');
if (btnExportMarkdown) {
  btnExportMarkdown.addEventListener('click', () => {
    let md = '# Project UAI Session Transcript\n\n';
    transcriptEvents.forEach(({ data }) => {
      if (data.type === 'user') md += `### YOU\n${data.text}\n\n`;
      else if (data.type === 'agent') md += `### ${currentModelName.toUpperCase()}\n${data.text}\n\n`;
      else if (data.type === 'bad') md += `### ERROR\n${data.text}\n\n`;
    });
    const blob = new Blob([md], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `uai-transcript-${Date.now()}.md`;
    a.click();
    URL.revokeObjectURL(url);
  });
}

const btnExportJson = $('btnExportJson');
if (btnExportJson) {
  btnExportJson.addEventListener('click', () => {
    const raw = transcriptEvents.map(e => e.data);
    const blob = new Blob([JSON.stringify(raw, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `uai-events-${Date.now()}.json`;
    a.click();
    URL.revokeObjectURL(url);
  });
}

// ============================================================================
// Live Server Simulation / Internal Testing Mode
// ============================================================================

function seedSampleTranscript() {
  // User message (matches screenshot)
  say('you', 'hello', 'user');

  // Assistant error card (matches the exact red card from user screenshot!)
  say(
    'error',
    `{"error":{"message":"Budget pool quota has been exhausted. Please ask an administrator to increase the limit or select another budget pool. (request id: 202609070135078033215317dbjtHvEZqNlh)","type":"bad_response_status_code"},"type":"error"}`,
    'bad'
  );

  // Completed tool call example
  openTool({
    id: 'tool-sim-1',
    name: 'instance_find',
    arguments: { ClassName: 'Model', Parent: 'Workspace' },
  });
  closeTool({
    id: 'tool-sim-1',
    name: 'instance_find',
    text: 'Found 3 models:\n- Workspace.Map\n- Workspace.Spawns\n- Workspace.LocalPlayerCharacter',
  }, true);

  // Permission prompt example
  askPermission({
    id: 'perm-sim-1',
    name: 'remote_fire',
    description: 'Agent requested firing "ClaimReward" RemoteEvent.',
    arguments: { Remote: 'ClaimReward', Amount: 50 },
  });

  stats.promptTokens = 120;
  stats.completionTokens = 85;
  stats.totalTokens = 205;
  updateStatsDisplay();
}

function runSimulatedTurn(userPrompt) {
  say('you', userPrompt, 'user');
  setBusy(true);
  statusText.textContent = 'thinking…';

  stats.promptTokens += Math.round(userPrompt.length / 3);
  stats.totalTokens = stats.promptTokens + stats.completionTokens;
  updateStatsDisplay();

  setTimeout(() => {
    const lower = userPrompt.toLowerCase();
    let toolName = 'instance_find';
    let toolArgs = { query: userPrompt };
    let toolResult = 'Executed successfully in 35ms.';

    if (lower.includes('player') || lower.includes('who')) {
      toolName = 'player_list';
      toolArgs = { includeStats: true };
      toolResult = 'Active Players (3):\n- CarlDV (UserId: 18294102, Team: "Builders")\n- PlayerTwo (UserId: 9948201, Team: "Explorers")\n- GuestUser (UserId: 3381920, Team: "Neutral")';
    } else if (lower.includes('move') || lower.includes('teleport') || lower.includes('spawn')) {
      toolName = 'character_move';
      toolArgs = { target: 'SpawnLocation', coordinates: [0, 10, 0] };
      toolResult = 'Humanoid navigated to SpawnLocation (Vector3(0, 10, 0)).';
    } else if (lower.includes('perf') || lower.includes('fps')) {
      toolName = 'perf_fps';
      toolArgs = { sampleInterval: 1.0 };
      toolResult = 'Performance:\n- Client FPS: 60.0 fps\n- Memory: 408 MB\n- Ping: 24 ms';
    }

    const simId = 'sim-call-' + Date.now();
    openTool({ id: simId, name: toolName, arguments: toolArgs });

    setTimeout(() => {
      closeTool({ id: simId, name: toolName, text: toolResult }, true);

      const reply = `I executed \`${toolName}\` to handle your request:\n\n` +
        `\`\`\`json\n${JSON.stringify({ status: 'ok', tool: toolName, result: toolResult }, null, 2)}\n\`\`\`\n\n` +
        `Operations completed in client memory without errors.`;

      say('uai', reply, 'agent');
      setBusy(false);
      statusText.textContent = 'bridge';

      stats.completionTokens += Math.round(reply.length / 3);
      stats.totalTokens = stats.promptTokens + stats.completionTokens;
      updateStatsDisplay();
    }, 800);
  }, 500);
}

// ============================================================================
// Real Bridge SSE Connection
// ============================================================================

let stream = null;

function connectBridgeStream() {
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

  stream.addEventListener('error', () => {
    statusText.textContent = 'unreachable, retrying';
    dot.className = 'status-dot warn';
  });
}

async function accepted(candidate) {
  const previous = token;
  token = candidate;
  const res = await api('/hello').catch(() => null);
  if (res && res.ok) return true;
  token = previous;
  return false;
}

function enterApp(simulation) {
  isSimulationMode = simulation;
  if (gate) gate.hidden = true;
  if (app) app.hidden = false;

  if (simulation) {
    dot.className = 'status-dot simulation';
    statusText.textContent = 'bridge (simulation)';
    const diagMode = $('diagMode');
    if (diagMode) diagMode.textContent = 'Live Server (Simulation)';
    seedSampleTranscript();
  } else {
    dot.className = 'status-dot';
    statusText.textContent = 'bridge';
    connectBridgeStream();
  }

  input.focus();
}

// Boot
(async function boot() {
  renderDrawerTools();

  // Try token from URL fragment or localStorage
  if (token && (await accepted(token))) {
    localStorage.setItem(STORE_KEY, token);
    enterApp(false);
    return;
  }

  // Token is missing or invalid: show login screen (#gate)
  localStorage.removeItem(STORE_KEY);
  if (gate) gate.hidden = false;
  if (app) app.hidden = true;

  const form = $('gate-form');
  if (form) {
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const err = $('gate-error');
      if (err) err.hidden = true;
      const candidate = ($('gate-token').value || '').trim();
      if (!candidate) return;

      const submitBtn = $('gate-submit');
      if (submitBtn) submitBtn.disabled = true;

      if (await accepted(candidate)) {
        token = candidate;
        localStorage.setItem(STORE_KEY, token);
        enterApp(false);
        return;
      }

      if (submitBtn) submitBtn.disabled = false;
      if (err) {
        err.textContent = 'That token was refused. Check the bridge console.';
        err.hidden = false;
      }
    });
  }

  const demoBtn = $('gate-demo-btn');
  if (demoBtn) {
    demoBtn.addEventListener('click', () => {
      enterApp(true);
    });
  }

  const gateTokenInput = $('gate-token');
  if (gateTokenInput) gateTokenInput.focus();
})();
