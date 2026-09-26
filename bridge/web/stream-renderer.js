/* Browser previews are incremental; only the game's assistant:text is final. */
(function (root) {
  'use strict';
  const PAINT_MS = 60, MAX_LIVE = 32, MAX_TEXT = 8 * 1024 * 1024;

  function create(deps) {
    const live = new Map(), committed = new Map();
    const key = e => (e.sessionId || deps.getSession() || '') + ':' + (e.id || e.requestId);
    const matches = e => !e.sessionId || e.sessionId === deps.getSession();
    const signal = () => deps.onActivity?.([...live.values()].some(entry => entry.streaming));
    const node = (tag, cls, text) => {
      const n = document.createElement(tag); n.className = cls;
      if (text !== undefined) n.textContent = text;
      return n;
    };

    function cancel(entry) {
      clearTimeout(entry.timer); cancelAnimationFrame(entry.raf);
      entry.timer = entry.raf = null; entry.scheduled = false;
      if (entry.deferred) {
        document.removeEventListener('selectionchange', entry.deferred);
        entry.body.removeEventListener('focusout', entry.deferred);
        entry.deferred = null;
      }
    }

    function ensure(e) {
      if (!matches(e) || committed.has(key(e))) return null;
      let entry = live.get(key(e));
      if (entry) return entry;
      while (live.size >= MAX_LIVE) {
        const [oldKey, old] = live.entries().next().value;
        cancel(old); old.streaming = false; old.node.classList.remove('streaming');
        old.status.textContent = 'Preview paused. Waiting for the saved reply.';
        live.delete(oldKey);
      }
      const created = deps.createAgentMessage(e.model || deps.defaultModel());
      const stable = node('div', 'stream-stable'), tail = node('div', 'stream-tail');
      const tailText = document.createTextNode(''); tail.append(tailText);
      const status = node('div', 'stream-status', 'Waiting for a response…');
      created.body.replaceChildren(stable, tail);
      created.node.append(status); created.node.classList.add('streaming');
      entry = { ...created, stable, tail, tailText, status, sessionId: e.sessionId || deps.getSession(),
        text: '', reasoning: '', stableLength: 0, paintedTail: '', lastSeq: 0, lastPaint: 0,
        streaming: true, timer: null, raf: null, scheduled: false };
      live.set(key(e), entry); signal();
      return entry;
    }

    // A block becomes stable only at a blank line outside a matching fence.
    function stableCut(text) {
      const lines = text.split('\n'); let fence = null, offset = 0, cut = 0;
      for (const line of lines) {
        const opening = line.match(/^\s*(`{3,}|~{3,})/);
        if (opening && !fence) fence = opening[1];
        else if (fence && new RegExp('^\\s*' + fence[0] + '{' + fence.length + ',}\\s*$').test(line)) fence = null;
        offset += line.length + 1;
        if (!fence && !line.trim() && offset <= text.length) cut = offset;
      }
      return cut;
    }

    function paint(entry) {
      entry.scheduled = false; entry.lastPaint = performance.now();
      if (!entry.node.isConnected) return;
      const pinned = deps.isPinned();
      const remainder = entry.text.slice(entry.stableLength), cut = stableCut(remainder);
      if (cut) {
        const fragment = document.createElement('template');
        fragment.innerHTML = deps.md(remainder.slice(0, cut));
        entry.stable.append(fragment.content); entry.stableLength += cut;
      }
      const tail = entry.text.slice(entry.stableLength);
      if (tail.startsWith(entry.paintedTail) && !cut) entry.tailText.appendData(tail.slice(entry.paintedTail.length));
      else entry.tailText.data = tail;
      entry.paintedTail = tail;
      if (entry.reasonBody && !entry.reasonCommitted) entry.reasonBody.textContent = entry.reasoning;
      if (entry.streaming && (entry.text || entry.reasoning)) entry.status.textContent = entry.text ? 'Receiving response…' : 'Thinking…';
      if (pinned) deps.scrollToEnd();
    }

    function schedule(entry) {
      if (entry.scheduled) return;
      entry.scheduled = true;
      entry.timer = setTimeout(() => {
        entry.timer = null;
        entry.raf = requestAnimationFrame(() => { entry.raf = null; paint(entry); });
      }, Math.max(0, PAINT_MS - (performance.now() - entry.lastPaint)));
    }

    function flush(entry) {
      clearTimeout(entry.timer); cancelAnimationFrame(entry.raf);
      entry.timer = entry.raf = null; paint(entry);
    }

    function isInteracting(body) {
      if (body.contains(document.activeElement)) return true;
      const selection = document.getSelection();
      return selection && !selection.isCollapsed && (body.contains(selection.anchorNode) || body.contains(selection.focusNode));
    }

    function reconcile(entry, text) {
      const render = () => {
        if (isInteracting(entry.body)) return;
        entry.body.innerHTML = deps.md(text); cancel(entry);
      };
      if (isInteracting(entry.body)) {
        entry.deferred = () => queueMicrotask(render);
        entry.body.addEventListener('focusout', entry.deferred);
        document.addEventListener('selectionchange', entry.deferred);
      } else render();
    }

    function start(e) { ensure(e); }

    function resync(e) {
      const entry = ensure(e); if (!entry) return;
      flush(entry);
      entry.text = ''; entry.stableLength = 0; entry.paintedTail = ''; entry.stable.replaceChildren(); entry.tailText.data = '';
      if (!entry.reasonCommitted) { entry.reasoning = ''; if (entry.reasonBody) entry.reasonBody.textContent = ''; }
      entry.lastSeq = Math.max(0, (e.from || entry.lastSeq + 1) - 1);
      if (!entry.gap) { entry.gap = node('p', 'stream-gap', 'Earlier live text is unavailable. The saved reply will replace this preview.'); entry.node.append(entry.gap); }
    }

    function delta(e) {
      const entry = ensure(e); if (!entry) return;
      if (Number.isFinite(e.seq)) {
        if (e.seq <= entry.lastSeq) return;
        if (e.seq > entry.lastSeq + 1) resync({ ...e, from: e.seq });
        entry.lastSeq = e.seq;
      }
      const d = e.frame?.choices?.[0]?.delta || {}, anthropic = e.frame?.delta || {};
      const text = e.channel ? (e.channel === 'text' && typeof e.text === 'string' ? e.text : '') : d.content || anthropic.text || '';
      const reasoning = e.channel ? (e.channel === 'reasoning' && typeof e.text === 'string' ? e.text : '') : d.reasoning_content || d.reasoning || anthropic.thinking || '';
      if (entry.text.length + entry.reasoning.length + text.length + reasoning.length > MAX_TEXT) {
        done({ ...e, state: 'failed', error: 'Live preview reached its size limit. Waiting for the saved reply.' }); return;
      }
      entry.text += text; entry.reasoning += reasoning;
      if (reasoning && !entry.reasonBody) { entry.reasonBody = deps.createThinking(''); entry.node.before(entry.reasonBody.parentElement); }
      if (text || reasoning) schedule(entry);
    }

    function done(e) {
      if (!matches(e) || committed.has(key(e))) return;
      const entry = ensure(e); if (!entry) return;
      flush(entry); entry.streaming = false; entry.node.classList.remove('streaming');
      const failure = (e.state && e.state !== 'completed') || e.status >= 400;
      if (failure) {
        entry.failed = true;
        entry.status.className = 'stream-error'; entry.status.setAttribute('role', 'alert');
        entry.status.replaceChildren(node('span', '', e.error || e.providerError || (e.state === 'cancelled' ? 'Request stopped.' : 'Request failed.')));
        if (deps.onRetry && e.state !== 'cancelled') {
          const retry = node('button', 'retry', 'Review & retry'); retry.type = 'button';
          retry.onclick = () => deps.onRetry(entry.sessionId); entry.status.append(retry);
        }
      } else entry.status.textContent = e.streamed === false ? 'Response received. Waiting for Roblox…' : 'Saving the response…';
      signal();
    }

    function commitText(e) {
      if (!matches(e)) return;
      const id = key(e); let entry = live.get(id) || committed.get(id);
      if (entry && !entry.node.isConnected) { cancel(entry); live.delete(id); committed.delete(id); entry = null; }
      if (entry) {
        if (live.has(id)) flush(entry);
        cancel(entry); reconcile(entry, e.text || '');
        entry.streaming = false; entry.node.classList.remove('streaming');
        entry.status?.remove(); entry.gap?.remove();
        deps.onFinal?.(entry, e.text || '', e.model);
        entry.text = entry.reasoning = ''; live.delete(id); committed.set(id, entry);
      } else {
        const created = deps.createAgentMessage(e.model || deps.defaultModel());
        created.body.innerHTML = deps.md(e.text || ''); deps.onFinal?.(created, e.text || '', e.model);
        if (e.requestId) committed.set(id, { ...created, sessionId: e.sessionId || deps.getSession() });
      }
      while (committed.size > 80) {
        const [oldId, old] = committed.entries().next().value; cancel(old); committed.delete(oldId);
      }
      signal();
    }

    function commitReasoning(e) {
      if (!matches(e)) return;
      const entry = live.get(key(e)) || committed.get(key(e));
      if (entry) {
        if (!entry.reasonBody && e.text) { entry.reasonBody = deps.createThinking(''); entry.node.before(entry.reasonBody.parentElement); }
        if (entry.reasonBody) entry.reasonBody.innerHTML = deps.md(e.text || '');
        entry.reasonCommitted = true;
      } else if (e.text) deps.createThinking(e.text);
    }

    function endTurn(sessionId, stopped = false) {
      for (const entry of live.values()) if (entry.sessionId === sessionId) {
        flush(entry); entry.streaming = false; entry.node.classList.remove('streaming');
        if (!entry.text && !entry.failed) entry.node.remove();
        else if (!entry.failed) entry.status.textContent = stopped ? 'Stopped. This is a partial response.' : 'Preview only. Waiting for the saved reply.';
      }
      signal();
    }

    function dropSession(sessionId) {
      for (const map of [live, committed]) for (const [id, entry] of map) if (entry.sessionId === sessionId) { cancel(entry); map.delete(id); }
      signal();
    }

    function reset() {
      for (const map of [live, committed]) { for (const entry of map.values()) cancel(entry); map.clear(); }
      signal();
    }
    return { start, delta, done, resync, commitText, commitReasoning, endTurn, dropSession, reset,
      has: id => [...live.keys(), ...committed.keys()].some(value => value.endsWith(':' + id)) };
  }

  root.UAIStreamRenderer = { create };
  if (typeof module !== 'undefined') module.exports = root.UAIStreamRenderer;
})(typeof window !== 'undefined' ? window : globalThis);
