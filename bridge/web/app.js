'use strict';

// ============================================================================
// Project UAI Web Bridge Application
// Real-data chat interface over the loopback SSE bridge. Everything the panels
// show -- providers, models, tools, threads, subagents, usage -- comes from the
// game's own state pushes. Nothing is hardcoded and nothing is simulated.
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
const permBanner = $('permBanner');
const permBannerText = $('permBannerText');
const permBannerMode = $('permBannerMode');

// Composer pills & popups
const composerToolsPill = $('composerToolsPill');
const modelSelectorPill = $('modelSelectorPill');
const modelSelectorMenu = $('modelSelectorMenu');
const quickPromptsPill = $('quickPromptsPill');
const quickPromptsMenu = $('quickPromptsMenu');

// Drawer elements
const sidebarToggle = $('sidebarToggle');
const telemetryDrawerBtn = $('telemetryDrawerBtn');
const featuresDrawer = $('featuresDrawer');
const drawerOverlay = $('drawerOverlay');
const drawerCloseBtn = $('drawerCloseBtn');

// State
let isBusy = false;
let autoScroll = true;
let agentState = null; // the game's last full state push
const transcriptEvents = [];
const toolRows = new Map();
const subagentRecords = new Map();
let lastLatencyMs = null;
let toolsRun = 0;

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

function command(type, fields) {
  return api('/command', { type, ...(fields || {}) }).catch(() => {});
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

  const codeBlocks = [];
  text = text.replace(/```([a-zA-Z0-9_\-]*)\n([\s\S]*?)```/g, (_, lang, code) => {
    const placeholder = `__CODE_BLOCK_${codeBlocks.length}__`;
    codeBlocks.push({ lang: (lang || 'code').toLowerCase(), code });
    return placeholder;
  });

  text = escapeHtml(text);

  text = text.replace(/^### (.*$)/gim, '<h3>$1</h3>');
  text = text.replace(/^## (.*$)/gim, '<h2>$1</h2>');
  text = text.replace(/^# (.*$)/gim, '<h1>$1</h1>');
  text = text.replace(/^\> (.*$)/gim, '<blockquote>$1</blockquote>');
  text = text.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
  text = text.replace(/\*(.*?)\*/g, '<em>$1</em>');
  text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
  text = text.replace(/^\s*[\-\*]\s+(.*$)/gim, '<li>$1</li>');
  text = text.replace(/(<li>.*<\/li>)/s, '<ul>$1</ul>');

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
// Message Rendering
// ============================================================================

function currentModelName() {
  return (agentState && agentState.agent && agentState.agent.model) || 'agent';
}

function say(who, text, extra) {
  const isUser = who.toLowerCase() === 'you' || extra === 'user';
  const isAgent = who.toLowerCase() === 'uai' || extra === 'agent';
  const isError = who.toLowerCase() === 'error' || extra === 'bad';

  const row = el('div', `msg-row ${isUser ? 'user' : ''} ${isAgent ? 'agent' : ''} ${isError ? 'bad' : ''}`);

  let senderLabel = isUser ? 'YOU' : currentModelName().toUpperCase();
  if (isError) senderLabel = 'SYSTEM ERROR';

  const header = el('div', 'msg-header', senderLabel);
  row.appendChild(header);

  if (isError) {
    const errBox = el('div', 'msg-error-box', text);
    row.appendChild(errBox);
  } else if (isAgent) {
    const body = el('div', 'msg-body');
    body.innerHTML = renderMarkdown(text);
    row.appendChild(body);
  } else {
    const body = el('div', 'msg-body', text);
    row.appendChild(body);
  }

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

function openTool(event) {
  const box = el('details', 'tool-accordion');
  const head = el('summary');
  head.appendChild(el('span', 'tool-arrow', '▸'));
  head.appendChild(el('span', 'tool-name-tag', event.name || 'tool'));
  head.appendChild(el('span', 'tool-summary-args', summarise(event.arguments)));

  const verdict = el('span', 'tool-status-pill running', 'running');
  head.appendChild(verdict);
  box.appendChild(head);

  const bodyDetails = el('div', 'tool-details-content');
  const argsPre = el('pre', null, typeof event.arguments === 'object' ? JSON.stringify(event.arguments, null, 2) : String(event.arguments || '{}'));
  bodyDetails.appendChild(argsPre);
  box.appendChild(bodyDetails);

  place(box, { type: 'tool', name: event.name, args: event.arguments });
  if (event.id) toolRows.set(event.id, { box, verdict, bodyDetails });

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

    case 'bridge:state':
      agentState = event.state || {};
      applyState();
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

    case 'assistant:reasoning':
      note('Reasoning… ' + String(event.text || '').replace(/\s+/g, ' ').slice(0, 140));
      break;

    case 'tool:call':
      toolsRun++;
      updateTelemetry();
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
      break;

    case 'request:start':
      note(`→ ${event.provider || 'provider'}${event.model ? ' · ' + event.model : ''} · ${event.messages || 0} messages`);
      break;

    case 'request:done':
      if (event.ms) {
        lastLatencyMs = event.ms;
        updateTelemetry();
      }
      if (event.error) note(`✕ ${event.provider || 'provider'}: ${event.error}`);
      break;

    case 'request:retry':
      note(`retry ${event.attempt || 1}/${event.attempts || '?'} on ${event.provider || 'provider'}`);
      break;

    case 'usage': {
      const turn = event.turn || {};
      if (turn.prompt || turn.completion) {
        note(`Tokens this turn: ${turn.prompt || 0} in / ${turn.completion || 0} out`);
      }
      break;
    }

    case 'turn:start':
      setBusy(true);
      break;

    case 'turn:end':
      setBusy(false);
      break;

    case 'compact':
      note(`Context compacted (${event.before || '?'} → ${event.after || '?'} tokens).`);
      break;

    case 'subagent:start':
      renderSubagent(event);
      break;

    case 'subagent:text':
      if (event.text) note(`[subagent] ${event.text}`);
      break;

    case 'subagent:tool':
      openTool({ ...event, name: event.name || 'subagent tool', id: event.id });
      break;

    case 'subagent:tool:done':
      closeTool({ ...event, name: event.name || 'subagent tool', id: event.id }, event.ok !== false);
      break;

    case 'subagent:done': {
      const ms = event.ms ? ` in ${(event.ms / 1000).toFixed(1)}s` : '';
      note(`Subagent finished${ms}${event.messages ? ' · ' + event.messages + ' messages' : ''}.`);
      if (event.id && subagentRecords.has(event.id)) {
        subagentRecords.get(event.id).status = 'completed';
        renderDrawerSubagents();
      }
      break;
    }

    default:
      break;
  }
}

// ============================================================================
// State Application (real data from the game)
// ============================================================================

function applyState() {
  const s = agentState;
  if (!s) return;

  if (activeModelLabel) {
    const label = s.agent && s.agent.model ? s.agent.model : 'no model';
    activeModelLabel.textContent = String(label).toLowerCase();
  }

  const mode = s.permissions && s.permissions.mode;
  const pending = (s.permissions && s.permissions.pending) || 0;
  if (permBanner) {
    permBanner.hidden = mode !== 'ask';
    if (permBannerText) permBannerText.textContent = pending > 0 ? `${pending} request(s) waiting for approval…` : 'Ask mode — risky tools need approval';
    if (permBannerMode) permBannerMode.textContent = mode ? (mode + ' mode') : '';
  }

  updateTelemetry();
  renderModelMenu();
  renderDrawerTools();
  renderDrawerSubagents();
  renderThreads();
  renderProviders();
  renderDiagnostics();
}

function updateTelemetry() {
  const u = agentState && agentState.usage;
  const total = u ? (u.total || 0) : 0;
  const cost = u ? (u.cost || 0) : 0;

  const set = (id, value) => { const node = $(id); if (node) node.textContent = value; };

  set('statTotalTokens', total.toLocaleString());
  set('statPromptTokens', (u ? (u.prompt || 0) : 0).toLocaleString());
  set('statCompletionTokens', (u ? (u.completion || 0) : 0).toLocaleString());
  set('statRequests', u ? (u.requests || 0) : 0);
  set('statCost', '$' + cost.toFixed(4));
  set('statCostSub', u && u.estimated ? 'estimated (provider reports none)' : 'provider pricing');

  const badge = $('usageBadge');
  if (badge) {
    badge.textContent = u && u.estimated ? 'estimated' : 'live';
    badge.className = 'badge-' + (u && u.estimated ? 'warn' : 'success');
  }

  if (lastLatencyMs != null) {
    set('statLatency', 'last request ' + lastLatencyMs + 'ms');
  }

  set('statTools', toolsRun);

  if (topTokenCount) topTokenCount.textContent = `${total.toLocaleString()} tok`;
}

// Model menu: the provider's real model list, plus a discovery fetch
function renderModelMenu() {
  const list = $('modelMenuList');
  const hint = $('modelMenuHint');
  if (!list) return;

  const providers = (agentState && agentState.providers) || [];
  const activeId = agentState && agentState.activeProvider;
  const activeRec = providers.find(p => p.id === activeId);

  if (hint) {
    hint.textContent = activeRec ? (activeRec.label + ' · ' + (activeRec.models ? activeRec.models.length : 0) + ' models') : 'no provider';
  }

  list.replaceChildren();

  if (providers.length === 0) {
    const empty = el('div', 'popup-menu-empty');
    empty.textContent = 'No provider configured. Add one in-game.';
    list.appendChild(empty);
    return;
  }

  providers.forEach(provider => {
    const header = el('div', 'popup-menu-group');
    header.textContent = provider.label + (provider.cooling ? ' (cooling)' : '');
    list.appendChild(header);

    if (provider.models && provider.models.length > 0) {
      provider.models.forEach(model => {
        const item = el('div', 'popup-menu-item');
        item.setAttribute('data-provider', provider.id);
        item.setAttribute('data-model', model);
        if (activeId === provider.id && provider.model === model) item.classList.add('active');
        item.textContent = model;
        item.addEventListener('click', () => {
          closeMenus();
          command('model', { provider: provider.id, model });
          if (activeModelLabel) activeModelLabel.textContent = String(model).toLowerCase();
        });
        list.appendChild(item);
      });
    } else {
      const empty = el('div', 'popup-menu-empty');
      empty.textContent = 'no models yet — fetch below';
      list.appendChild(empty);
    }

    const discover = el('button', 'popup-menu-discover');
    discover.type = 'button';
    discover.textContent = '↻ Fetch models from ' + provider.label;
    discover.addEventListener('click', () => {
      discover.disabled = true;
      discover.textContent = 'Fetching…';
      command('models:discover', { provider: provider.id });
      setTimeout(() => {
        discover.disabled = false;
        discover.textContent = '↻ Fetch models from ' + provider.label;
      }, 4000);
    });
    list.appendChild(discover);
  });
}

// Tool catalog: the game's real registry, grouped by its own groups
const GROUP_LABELS = {
  agentself: 'Autonomous', instance: 'Instances', script: 'Scripts', fs: 'Filesystem',
  net: 'Network', web: 'Web', players: 'Players', character: 'Character',
  world: 'World', remotes: 'Remotes', gui: 'Interface', perf: 'Diagnostics',
  meta: 'Metadata', chat: 'In-game chat', input: 'Virtual input',
};

let activeDrawerCategory = 'all';
let drawerSearchQuery = '';

function renderDrawerTools() {
  const container = $('drawerToolsList');
  const pills = $('drawerCategoryPills');
  if (!container) return;

  const tools = (agentState && agentState.tools) || [];

  if (pills) {
    const groups = [...new Set(tools.map(t => t.group))];
    const signature = groups.join(',');
    if (pills.getAttribute('data-groups') !== signature) {
      pills.setAttribute('data-groups', signature);
      pills.replaceChildren();
      const all = el('button', 'cat-pill' + (activeDrawerCategory === 'all' ? ' active' : ''), 'All');
      all.type = 'button';
      all.setAttribute('data-cat', 'all');
      all.addEventListener('click', () => { activeDrawerCategory = 'all'; renderDrawerTools(); });
      pills.appendChild(all);
      groups.forEach(group => {
        const pill = el('button', 'cat-pill' + (activeDrawerCategory === group ? ' active' : ''), GROUP_LABELS[group] || group);
        pill.type = 'button';
        pill.setAttribute('data-cat', group);
        pill.addEventListener('click', () => { activeDrawerCategory = group; renderDrawerTools(); });
        pills.appendChild(pill);
      });
    }
  }

  const count = $('toolCount');
  if (count) count.textContent = tools.length;

  const filtered = tools.filter(t => {
    const matchCat = activeDrawerCategory === 'all' || t.group === activeDrawerCategory;
    const matchQ = !drawerSearchQuery || t.name.toLowerCase().includes(drawerSearchQuery) || (t.description || '').toLowerCase().includes(drawerSearchQuery);
    return matchCat && matchQ;
  });

  container.replaceChildren();

  if (tools.length === 0) {
    const empty = el('div', 'drawer-empty');
    empty.textContent = 'Waiting for the game to report its tools…';
    container.appendChild(empty);
    return;
  }

  filtered.forEach(tool => {
    const card = el('div', 'drawer-tool-card');
    card.innerHTML = `
      <div class="drawer-tool-row">
        <span class="drawer-tool-name">${escapeHtml(tool.name)}</span>
        <span class="drawer-tool-group">${escapeHtml(GROUP_LABELS[tool.group] || tool.group)}</span>
      </div>
      <div class="drawer-tool-desc">${escapeHtml(tool.description || '')}</div>
      <div class="drawer-tool-footer">
        <span class="risk-chip risk-${escapeHtml(tool.risk || 'write')}">${escapeHtml(tool.risk || 'write')}</span>
        <button type="button" class="drawer-tool-action">Insert prompt</button>
      </div>
    `;
    card.querySelector('.drawer-tool-action').addEventListener('click', () => {
      input.value = `Execute tool: ${tool.name} — ${tool.description || ''}`;
      grow();
      closeDrawer();
      input.focus();
    });
    container.appendChild(card);
  });
}

// Subagents: real records from the game
function renderDrawerSubagents() {
  const container = $('subagentsList');
  const countBadge = $('activeSubagentsCount');
  if (!container) return;

  const list = (agentState && agentState.subagents) || [];
  if (countBadge) countBadge.textContent = `${list.filter(s => s.status === 'running' || s.status === 'queued').length} active`;

  container.replaceChildren();

  const records = list.length > 0 ? list : Array.from(subagentRecords.values());
  if (records.length === 0) {
    const empty = el('div', 'drawer-empty');
    empty.textContent = 'No subagents dispatched yet.';
    container.appendChild(empty);
    return;
  }

  records.forEach(rec => {
    const live = rec.status === 'running' || rec.status === 'queued';
    const item = el('div', 'drawer-tool-card');
    const report = rec.report ? `<div class="drawer-tool-desc">${escapeHtml(String(rec.report).slice(0, 200))}</div>` : '';
    item.innerHTML = `
      <div class="drawer-tool-row">
        <strong style="color:var(--color-coral); font-size:12px;">${escapeHtml(rec.label || rec.preset || 'subagent')}</strong>
        <span class="sub-status sub-${escapeHtml(rec.status || 'running')}">${escapeHtml(rec.status || 'running')}</span>
      </div>
      <div style="font-size:12px; color:var(--text-primary); margin-top:2px;">${escapeHtml(rec.task || '')}</div>
      ${report}
      ${live ? '<button type="button" class="drawer-tool-action sub-stop">Stop</button>' : ''}
    `;
    const stopBtn = item.querySelector('.sub-stop');
    if (stopBtn) stopBtn.addEventListener('click', () => command('subagent:stop', { id: rec.id }));
    container.appendChild(item);
  });
}

// Threads: the game's real conversation list
function renderThreads() {
  const container = $('threadsList');
  const countEl = $('threadCount');
  if (!container) return;

  const threads = (agentState && agentState.threads) || [];
  if (countEl) countEl.textContent = threads.length;

  container.replaceChildren();

  if (threads.length === 0) {
    const empty = el('div', 'drawer-empty');
    empty.textContent = 'No conversations yet.';
    container.appendChild(empty);
    return;
  }

  threads.forEach(thread => {
    const item = el('div', 'thread-item' + (thread.active ? ' active' : ''));
    item.innerHTML = `
      <div class="thread-row">
        <span class="thread-title">${escapeHtml(thread.title || 'untitled')}</span>
        <span class="thread-meta">${thread.busy ? '● busy' : ''}</span>
      </div>
      <div class="thread-sub">${escapeHtml(thread.place || '')} · ${thread.turns || 0} turns</div>
    `;
    item.addEventListener('click', () => {
      if (!thread.active) command('thread', { id: thread.id });
    });
    container.appendChild(item);
  });
}

// Providers: real list with health
function renderProviders() {
  const container = $('providersList');
  const countEl = $('providerCount');
  if (!container) return;

  const providers = (agentState && agentState.providers) || [];
  const activeId = agentState && agentState.activeProvider;
  if (countEl) countEl.textContent = providers.length;

  container.replaceChildren();

  if (providers.length === 0) {
    const empty = el('div', 'drawer-empty');
    empty.textContent = 'No providers configured. Add one in-game.';
    container.appendChild(empty);
    return;
  }

  providers.forEach(provider => {
    const isActive = provider.id === activeId;
    const health = provider.health || {};
    const h = health.ok || 0;
    const f = health.fail || 0;
    const item = el('div', 'thread-item' + (isActive ? ' active' : ''));
    item.innerHTML = `
      <div class="thread-row">
        <span class="thread-title">${escapeHtml(provider.label)}</span>
        <span class="thread-meta">${provider.cooling ? 'cooldown' : (h + '✓/' + (h + f))}</span>
      </div>
      <div class="thread-sub">${escapeHtml(provider.model || 'no model')}${provider.enabled === false ? ' · disabled' : ''}</div>
    `;
    item.addEventListener('click', () => {
      if (!isActive) command('provider', { id: provider.id });
    });
    container.appendChild(item);
  });
}

function renderDiagnostics() {
  const s = agentState || {};
  const set = (id, value) => { const node = $(id); if (node) node.textContent = value; };
  set('diagProvider', (s.agent && s.agent.provider) || '—');
  set('diagModel', (s.agent && s.agent.model) || '—');
  set('diagHost', (s.caps && (s.caps.executor || s.caps.http)) || '—');
  set('diagPlace', (s.place && s.place.name) || '—');

  // Permission mode segmented control
  const mode = s.permissions && s.permissions.mode;
  document.querySelectorAll('#permModeControl button').forEach(btn => {
    btn.classList.toggle('active', btn.getAttribute('data-mode') === mode);
  });
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

  say('you', text, 'user');
  const res = await api('/send', { text }).catch(() => null);
  if (!res || !res.ok) {
    note('Could not reach the local bridge server (bridge/server.js).');
  }
}

sendButton.addEventListener('click', submit);
stopButton.addEventListener('click', () => {
  api('/abort', {}).catch(() => {});
  setBusy(false);
});

clearBtn.addEventListener('click', () => {
  api('/clear', {}).catch(() => {});
});

input.addEventListener('input', grow);
input.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    submit();
  }
});

transcript.addEventListener('scroll', updateScrollButton);
if (scrollToBottomBtn) {
  scrollToBottomBtn.addEventListener('click', () => {
    transcript.scrollTop = transcript.scrollHeight;
    scrollToBottomBtn.hidden = true;
  });
}

// ============================================================================
// Popups
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
}

function closeDrawer() {
  if (featuresDrawer) featuresDrawer.hidden = true;
  if (drawerOverlay) drawerOverlay.hidden = true;
}

if (sidebarToggle) sidebarToggle.addEventListener('click', () => openDrawer('tools'));
if (composerToolsPill) composerToolsPill.addEventListener('click', () => openDrawer('tools'));
if (telemetryDrawerBtn) telemetryDrawerBtn.addEventListener('click', () => openDrawer('telemetry'));
if (drawerOverlay) drawerOverlay.addEventListener('click', closeDrawer);
if (drawerCloseBtn) drawerCloseBtn.addEventListener('click', closeDrawer);

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

// Permission mode segmented control
document.querySelectorAll('#permModeControl button').forEach(btn => {
  btn.addEventListener('click', () => {
    const mode = btn.getAttribute('data-mode');
    command('permission-mode', { mode });
    document.querySelectorAll('#permModeControl button').forEach(b => b.classList.toggle('active', b === btn));
  });
});

if (permBannerMode) {
  permBannerMode.addEventListener('click', () => openDrawer('settings'));
}

const btnNewThread = $('btnNewThread');
if (btnNewThread) {
  btnNewThread.addEventListener('click', () => command('thread:new'));
}

const drawerToolSearch = $('drawerToolSearch');
if (drawerToolSearch) {
  drawerToolSearch.addEventListener('input', () => {
    drawerSearchQuery = drawerToolSearch.value.trim().toLowerCase();
    renderDrawerTools();
  });
}

// ============================================================================
// Export
// ============================================================================

const btnExportMarkdown = $('btnExportMarkdown');
if (btnExportMarkdown) {
  btnExportMarkdown.addEventListener('click', () => {
    let md = '# Project UAI Session Transcript\n\n';
    transcriptEvents.forEach(({ data }) => {
      if (data.type === 'user') md += `### YOU\n${data.text}\n\n`;
      else if (data.type === 'agent') md += `### ${currentModelName().toUpperCase()}\n${data.text}\n\n`;
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
// Live Bridge SSE Connection
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

function enterApp() {
  if (gate) gate.hidden = true;
  if (app) app.hidden = false;
  dot.className = 'status-dot warn';
  statusText.textContent = 'waiting for game';
  // Paint the panels' empty states immediately rather than after the first
  // state push, so a browser opened before the game connects shows structure.
  renderDrawerTools();
  renderDrawerSubagents();
  renderThreads();
  renderProviders();
  renderDiagnostics();
  connectBridgeStream();
  input.focus();
}

// Boot
(async function boot() {
  if (token && (await accepted(token))) {
    localStorage.setItem(STORE_KEY, token);
    enterApp();
    return;
  }

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
        enterApp();
        return;
      }

      if (submitBtn) submitBtn.disabled = false;
      if (err) {
        err.textContent = 'That token was refused. Check the bridge console.';
        err.hidden = false;
      }
    });
  }

  const gateTokenInput = $('gate-token');
  if (gateTokenInput) gateTokenInput.focus();
})();
