/* Pictures stay in the browser/bridge. The game receives a text marker only. */
(function (root) {
  'use strict';
  root.UAI = root.UAI || {};
  const fmtBytes = n => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
  const newId = () => 'pic_' + crypto.randomUUID();
  const el = (tag, cls, text) => { const n = document.createElement(tag); n.className = cls || ''; if (text !== undefined) n.textContent = text; return n; };

  function createPictures(deps) {
    let token = deps.token, supported = false, policy, running = 0, generation = 0;
    const records = new Map(), messages = new Map(), waiting = [];
    const current = () => [...records.values()].filter(r => r.sessionId === deps.getSession());
    const drafts = () => current().filter(r => !r.commandId);
    const headers = sid => ({ Authorization: 'Bearer ' + token, 'X-UAI-Browser-Id': deps.browserId, 'X-UAI-Session-Id': sid });
    const notify = () => deps.onChange?.();
    const meta = r => Object.fromEntries(['id', 'sessionId', 'name', 'mediaType', 'bytes', 'width', 'height', 'sha256', 'status', 'commandId', 'expiresAt'].map(k => [k, r[k]]));
    function persist() {
      try { sessionStorage.setItem('uai.pictures', JSON.stringify([...records.values()].slice(-128).map(meta))); } catch { /* previews still work in memory */ }
    }
    try {
      const saved = JSON.parse(sessionStorage.getItem('uai.pictures') || '[]');
      for (const value of Array.isArray(saved) ? saved.slice(-128) : []) {
        if (value && /^pic_[\w-]{8,64}$/.test(value.id) && typeof value.sessionId === 'string') records.set(value.id, { ...value, status: ['queued', 'acked', 'staged'].includes(value.status) ? value.status : 'expired' });
      }
    } catch { /* invalid browser storage is disposable */ }

    async function configure(hello) {
      supported = !!hello.capabilities?.pictures;
      if (supported) {
        try { policy = await deps.api('/pictures/policy'); }
        catch (error) { supported = false; if (error.status === 401) throw error; }
      }
      if (supported) for (const rec of records.values()) if (!rec.url && rec.status !== 'expired') restore(rec);
      render(); notify();
    }

    async function measure(file) {
      if (root.createImageBitmap) {
        const bitmap = await createImageBitmap(file);
        const result = { width: bitmap.width, height: bitmap.height }; bitmap.close(); return result;
      }
      return new Promise((resolve, reject) => {
        const url = URL.createObjectURL(file), img = new Image();
        img.onload = () => { URL.revokeObjectURL(url); resolve({ width: img.naturalWidth, height: img.naturalHeight }); };
        img.onerror = () => { URL.revokeObjectURL(url); reject(Error('This image could not be read.')); }; img.src = url;
      });
    }

    function addFiles(fileList) {
      const sid = deps.getSession();
      if (!sid) { deps.toast('Connect Roblox before attaching pictures.'); return; }
      if (!supported || !policy) { deps.toast('Pictures are unavailable on this bridge.'); return; }
      for (const file of Array.from(fileList || [])) {
        const local = [...records.values()].filter(r => r.sessionId === sid && !r.commandId);
        if (!policy.mediaTypes.includes(file.type)) { deps.toast(file.name + ': choose a PNG, JPEG, or WebP image.'); continue; }
        if (!file.size || file.size > policy.limits.pictureBytes) { deps.toast(file.name + ': use an image under ' + fmtBytes(policy.limits.pictureBytes) + '.'); continue; }
        if (local.length >= policy.limits.picturesPerSend || local.reduce((sum, r) => sum + r.bytes, file.size) > policy.limits.pictureTotalBytes) {
          deps.toast('Up to ' + policy.limits.picturesPerSend + ' pictures and ' + fmtBytes(policy.limits.pictureTotalBytes) + ' per message.'); break;
        }
        while (records.size >= 128) {
          const old = [...records.values()].find(r => r.commandId || r.status === 'expired');
          if (!old) break; remove(old, false);
        }
        const rec = { id: newId(), sessionId: sid, name: file.name || 'pasted-image.png', mediaType: file.type,
          bytes: file.size, status: 'reading', file, url: URL.createObjectURL(file), progress: 0 };
        records.set(rec.id, rec); waiting.push(rec);
      }
      render(); notify(); pump();
    }

    function pump() {
      while (running < 2 && waiting.length) {
        const rec = waiting.shift(); if (!records.has(rec.id) || rec.status !== 'reading') continue;
        running++;
        upload(rec).finally(() => { running--; render(); persist(); notify(); pump(); });
      }
    }

    async function upload(rec) {
      try {
        const dims = await measure(rec.file);
        if (!records.has(rec.id)) return;
        if (dims.width > policy.maxWidth || dims.height > policy.maxHeight || dims.width * dims.height > policy.maxPixels) throw Error('This image is too large. Resize it to fit within ' + policy.maxWidth + ' × ' + policy.maxHeight + ' and 12 megapixels.');
        Object.assign(rec, dims, { status: 'uploading' }); render(); notify();
        const result = await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest(); rec.xhr = xhr;
          xhr.open('POST', '/api/pictures'); xhr.timeout = 30000;
          for (const [name, value] of Object.entries({ ...headers(rec.sessionId), 'X-UAI-Picture-Id': rec.id,
            'X-UAI-Picture-Name': encodeURIComponent(rec.name), 'Content-Type': rec.mediaType })) xhr.setRequestHeader(name, value);
          xhr.upload.onprogress = e => {
            if (e.lengthComputable) { rec.progress = Math.round(e.loaded / e.total * 100); if (rec.progressNode) rec.progressNode.value = rec.progress; }
          };
          xhr.onload = () => {
            let data; try { data = JSON.parse(xhr.responseText); } catch { data = {}; }
            if (xhr.status >= 200 && xhr.status < 300 && data.id) resolve(data);
            else reject(Error(data.error || 'Upload failed. Try again.'));
          };
          xhr.onerror = () => reject(Error('Upload connection failed. Try again.'));
          xhr.ontimeout = () => reject(Error('Upload timed out. Try again.'));
          xhr.onabort = () => reject(Error('Upload cancelled.'));
          xhr.send(rec.file);
        });
        if (records.has(rec.id)) Object.assign(rec, result, { progress: 100, error: null });
      } catch (error) {
        if (records.has(rec.id)) { rec.status = 'failed'; rec.error = error.message; }
      } finally { rec.xhr = null; }
    }

    function remove(rec, tellServer = true) {
      records.delete(rec.id); rec.xhr?.abort();
      if (rec.url) URL.revokeObjectURL(rec.url); rec.url = null; rec.file = null;
      if (tellServer && supported) fetch('/api/pictures/' + rec.id, { method: 'DELETE', headers: headers(rec.sessionId), signal: AbortSignal.timeout(10000) }).catch(() => {});
      persist();
    }

    function retry(rec) {
      if (!rec.file) { remove(rec); render(); openPicker(); return; }
      if (rec.status === 'expired') { records.delete(rec.id); rec.id = newId(); records.set(rec.id, rec); }
      rec.status = 'reading'; rec.error = null; rec.commandId = null; waiting.push(rec); render(); notify(); pump();
    }

    function render() {
      const list = drafts(); deps.tray.replaceChildren(); deps.tray.hidden = list.length === 0;
      if (!list.length) return;
      const summary = el('div', 'picture-summary');
      summary.append(el('strong', '', list.length + (list.length === 1 ? ' picture' : ' pictures') + ' · ' + fmtBytes(list.reduce((n, r) => n + r.bytes, 0))),
        el('span', '', 'Preview only. Describe the image for the AI.'));
      const cards = el('div', 'picture-cards'); deps.tray.append(summary, cards);
      for (const rec of list) {
        const card = el('div', 'picture-card'); card.dataset.status = rec.status;
        if (rec.url) { const img = el('img', 'picture-thumb'); img.src = rec.url; img.alt = rec.name; card.append(img); }
        const info = el('div', 'picture-meta');
        const status = rec.status === 'staged' ? 'Ready' : rec.status === 'expired' ? 'Expired · attach again' : rec.status === 'failed' ? rec.error || 'Upload failed' : rec.status === 'reading' ? 'Reading…' : 'Uploading…';
        info.append(el('strong', 'picture-name', rec.name), el('small', 'picture-dims', (rec.width ? rec.width + ' × ' + rec.height + ' · ' : '') + fmtBytes(rec.bytes)), el('span', 'picture-status', status));
        if (rec.status === 'failed' || rec.status === 'expired') {
          const again = el('button', 'picture-retry', rec.file ? 'Retry' : 'Attach again'); again.type = 'button'; again.onclick = () => retry(rec); info.append(again);
        }
        if (rec.status === 'uploading') {
          const progress = el('progress', 'picture-progress'); progress.max = 100; progress.value = rec.progress || 0; progress.setAttribute('aria-label', 'Uploading ' + rec.name); rec.progressNode = progress; info.append(progress);
        }
        const dismiss = el('button', 'picture-remove', '×'); dismiss.type = 'button'; dismiss.setAttribute('aria-label', 'Remove ' + rec.name);
        dismiss.onclick = () => { remove(rec); render(); notify(); }; card.append(info, dismiss); cards.append(card);
      }
    }

    function decorate(commandId) {
      const message = messages.get(commandId); if (!message?.body.isConnected) return;
      let strip = message.body.querySelector('.message-pictures');
      if (!strip) { strip = el('div', 'message-pictures'); message.body.append(strip); }
      strip.replaceChildren();
      for (const rec of records.values()) if (rec.commandId === commandId) {
        const figure = el('figure', 'message-picture');
        if (rec.url) { const img = el('img', 'picture-thumb'); img.src = rec.url; img.alt = rec.name; figure.append(img); }
        figure.append(el('figcaption', '', rec.name + (rec.url ? ' · preview only' : ' · preview unavailable'))); strip.append(figure);
      }
    }

    async function restore(rec) {
      if (rec.loading || rec.url || rec.status === 'expired') return;
      rec.loading = true; const epoch = generation;
      try {
        const response = await fetch('/api/pictures/' + rec.id, { headers: headers(rec.sessionId), signal: AbortSignal.timeout(10000) });
        if (!response.ok) { if ([404, 410].includes(response.status)) rec.status = 'expired'; return; }
        const blob = await response.blob();
        if (generation === epoch && records.get(rec.id) === rec) { rec.url = URL.createObjectURL(blob); rec.expiresAt = Date.now() + policy.limits.pictureTtlMs; }
      } catch { /* a reconnect may restore it later */ }
      finally { rec.loading = false; render(); decorate(rec.commandId); persist(); notify(); }
    }

    function attachToCommand(commandId, pictureIds) {
      for (const id of pictureIds) { const rec = records.get(id); if (rec) { rec.commandId = commandId; rec.status = 'queued'; } }
      render(); persist(); notify();
    }
    function releaseCommand(commandId) {
      for (const rec of records.values()) if (rec.commandId === commandId && rec.status !== 'acked') { rec.commandId = null; if (!['expired', 'failed'].includes(rec.status)) rec.status = 'staged'; }
      render(); persist(); notify();
    }
    function correlateUser(message, event) {
      if (event.commandId) { messages.set(event.commandId, message); decorate(event.commandId); }
    }
    function handleEvent(event) {
      if (event.browserId && event.browserId !== deps.browserId) return;
      if (!/^pic_[\w-]{8,64}$/.test(event.id || '')) return;
      let rec = records.get(event.id);
      if (!rec) { if (records.size >= 128) return; rec = {}; records.set(event.id, rec); }
      const uploading = rec.status === 'reading' || rec.status === 'uploading', previousStatus = rec.status;
      Object.assign(rec, meta(event));
      // The SSE notification can beat XHR.onload. Keep Send blocked until the
      // local upload settles, otherwise a late upload result can undo queuing.
      if (uploading && event.status === 'staged') rec.status = previousStatus;
      if (event.status === 'failed') { rec.commandId = null; rec.status = 'failed'; rec.error = 'Message was not delivered. Retry or remove this picture.'; }
      if (event.status === 'expired' && rec.url) { URL.revokeObjectURL(rec.url); rec.url = null; rec.file = null; }
      if (supported && policy && !rec.url) restore(rec);
      render(); decorate(rec.commandId); persist(); notify();
    }
    function clearSession(sid) { for (const rec of [...records.values()]) if (rec.sessionId === sid) remove(rec); render(); notify(); }
    function reset() { generation++; for (const rec of [...records.values()]) remove(rec, false); messages.clear(); waiting.length = 0; render(); notify(); }
    function resetMessages() { messages.clear(); }
    function openPicker() { if (supported) deps.input.click(); else deps.toast('Pictures are unavailable on this bridge.'); }
    function handlePaste(event) {
      const files = Array.from(event.clipboardData?.items || []).filter(i => i.kind === 'file' && i.type.startsWith('image/')).map(i => i.getAsFile()).filter(Boolean);
      if (!files.length) return false;
      event.preventDefault(); addFiles(files); return true;
    }
    deps.input.onchange = () => { addFiles(deps.input.files); deps.input.value = ''; };
    const dz = deps.dropZone;
    dz.addEventListener('dragover', e => { if (Array.from(e.dataTransfer?.types || []).includes('Files')) { e.preventDefault(); dz.classList.add('drag-over'); } });
    dz.addEventListener('dragleave', e => { if (!dz.contains(e.relatedTarget)) dz.classList.remove('drag-over'); });
    dz.addEventListener('drop', e => {
      const files = Array.from(e.dataTransfer?.files || []); if (!files.length) return;
      e.preventDefault(); dz.classList.remove('drag-over');
      const images = files.filter(f => f.type.startsWith('image/')), text = files.filter(f => !f.type.startsWith('image/'));
      if (images.length) addFiles(images); if (text.length) deps.onTextFiles?.(text);
    });
    setInterval(() => {
      let changed = false;
      for (const rec of records.values()) if (rec.expiresAt && rec.expiresAt < Date.now() && rec.status !== 'expired') {
        rec.status = 'expired'; if (rec.url) URL.revokeObjectURL(rec.url); rec.url = null; rec.file = null; decorate(rec.commandId); changed = true;
      }
      if (changed) { render(); persist(); notify(); }
    }, 15000);
    return { configure, addFiles, openPicker, handlePaste, attachToCommand, releaseCommand, correlateUser, handleEvent,
      ids: () => drafts().filter(r => r.status === 'staged').map(r => r.id),
      hasStaged: () => drafts().some(r => r.status === 'staged'),
      busy: () => drafts().some(r => r.xhr || ['reading', 'uploading'].includes(r.status)),
      hasErrors: () => drafts().some(r => ['failed', 'expired'].includes(r.status)),
      enabled: () => supported, manifest: () => current().filter(r => r.commandId).map(meta),
      showSession: render, clearSession, reset, resetMessages, setToken: value => { token = value; } };
  }
  root.UAI.createPictures = createPictures;
})(typeof window !== 'undefined' ? window : globalThis);
