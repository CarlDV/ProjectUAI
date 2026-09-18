'use strict';

const http = require('node:http');
const https = require('node:https');
const crypto = require('node:crypto');
const { StringDecoder } = require('node:string_decoder');

// Requests live independently of the short executor polls. IDs are never reused
// during a server lifetime, even after response bodies expire.
function createInference({ publish = () => {}, maxBytes = 16 * 1024 * 1024,
  retentionMs = 300000, maxJobs = 10000, maxActive = 16 } = {}) {
  const jobs = new Map();
  const instance = crypto.randomUUID();
  function finish(job, state, error) {
    if (job.state !== 'running') return;
    job.state = state;
    job.error = error;
    job.finishedAt = Date.now();
    clearTimeout(job.timer);
    publish({ kind: 'inference:done', id: job.id, sessionId: job.sessionId, state, error });
  }
  function view(job) {
    return { id: job.id, state: job.state, error: job.error, status: job.status,
      headers: job.headers, body: job.state === 'completed' ? job.body : undefined };
  }
  function start(input) {
    if (!input || typeof input.id !== 'string' || !/^[\w-]{8,100}$/.test(input.id)) throw new Error('Invalid request ID');
    if (input.instance !== instance) throw new Error('Bridge restarted; request was not resubmitted');
    if (typeof input.body !== 'string' || Buffer.byteLength(input.body) > maxBytes) throw new Error('Invalid inference body');
    const url = new URL(input.url);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('Use an HTTP(S) provider URL');
    const headers = {};
    for (const [name, value] of Object.entries(input.headers || {})) {
      if (/^(host|connection|content-length|transfer-encoding|accept-encoding)$/i.test(name)) continue;
      http.validateHeaderName(name);
      http.validateHeaderValue(name, String(value));
      headers[name] = String(value);
    }
    headers['accept-encoding'] = 'identity';
    headers['content-length'] = Buffer.byteLength(input.body);
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify([url.href,
      Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)), input.body, input.sessionId])).digest('hex');
    const existing = jobs.get(input.id);
    if (existing) {
      if (existing.state === 'cancelled' && !existing.fingerprint) return view(existing);
      if (existing.fingerprint !== fingerprint) throw new Error('Request ID already belongs to a different payload');
      return view(existing);
    }
    if (jobs.size >= maxJobs || [...jobs.values()].filter(j => j.state === 'running').length >= maxActive) throw new Error('Inference capacity reached');
    const timeout = Math.min(86400, Math.max(10, Number(input.timeout) || 180));
    const job = { id: input.id, fingerprint, sessionId: input.sessionId, state: 'running', body: '', bytes: 0 };
    job.frames = [];
    jobs.set(job.id, job);
    const decoder = new StringDecoder('utf8');
    let lines = '', data = [];
    const frame = () => {
      if (!data.length) return;
      const payload = data.join('\n'); data = [];
      if (payload === '[DONE]') { job.sseDone = true; return; }
      let parsed;
      try { parsed = JSON.parse(payload); } catch { return; }
      if (parsed.type === 'message_stop') job.sseDone = true;
      job.frames.push(parsed);
      if (job.sessionId) publish({ kind: 'inference:delta', id: job.id, sessionId: job.sessionId, frame: parsed });
    };
    const consume = text => {
      job.body += text;
      if (!job.streaming) return;
      lines += text;
      let newline;
      while ((newline = lines.indexOf('\n')) >= 0) {
        const line = lines.slice(0, newline).replace(/\r$/, ''); lines = lines.slice(newline + 1);
        if (!line) frame();
        else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
      }
    };
    const transport = url.protocol === 'https:' ? https : http;
    const request = transport.request(url, { method: 'POST', headers }, response => {
      job.status = response.statusCode;
      job.headers = {};
      for (const name of ['content-type', 'retry-after', 'x-request-id', 'server']) {
        if (response.headers[name]) job.headers[name] = response.headers[name];
      }
      job.streaming = String(response.headers['content-type'] || '').includes('text/event-stream');
      response.on('data', chunk => {
        if (job.state !== 'running') return;
        job.bytes += chunk.length;
        if (job.bytes > maxBytes) { finish(job, 'failed', 'Provider response exceeds relay limit'); request.destroy(); return; }
        consume(decoder.write(chunk));
      });
      response.on('end', () => {
        if (job.state !== 'running') return;
        consume(decoder.end());
        if (lines.startsWith('data:')) data.push(lines.slice(5).replace(/^ /, '').replace(/\r$/, ''));
        frame();
        if (job.streaming && job.status >= 200 && job.status < 300 && !job.sseDone) finish(job, 'failed', 'Provider stream ended before completion');
        else finish(job, 'completed');
      });
      response.on('error', () => finish(job, 'failed', 'Provider response connection closed'));
    });
    job.request = request;
    request.on('error', () => finish(job, 'failed', 'Could not complete provider connection'));
    job.timer = setTimeout(() => { finish(job, 'failed', `Provider request exceeded ${timeout}s`); request.destroy(); }, timeout * 1000);
    job.timer.unref();
    if (job.sessionId) publish({ kind: 'inference:start', id: job.id, sessionId: job.sessionId });
    request.end(input.body);
    return view(job);
  }
  function cancel(id) {
    const job = jobs.get(id);
    if (!job) {
      if (typeof id !== 'string' || !/^[\w-]{8,100}$/.test(id) || jobs.size >= maxJobs) return false;
      jobs.set(id, { id, state: 'cancelled', error: 'Stopped before submission', finishedAt: Date.now(), frames: [], body: '' });
      return true;
    }
    finish(job, 'cancelled', 'Stopped');
    job.request?.destroy();
    return true;
  }
  const cleanup = setInterval(() => {
    for (const job of jobs.values()) {
      if (job.finishedAt && Date.now() - job.finishedAt > retentionMs && job.state !== 'expired') {
        job.body = ''; job.frames = []; job.headers = undefined; job.request = undefined; job.state = 'expired';
      }
    }
  }, Math.min(retentionMs, 10000));
  cleanup.unref();
  return { instance, start, get: id => jobs.has(id) ? view(jobs.get(id)) : null, cancel,
    commit(id) { const job = jobs.get(id); if (job) job.committed = true; },
    previews(sessionId) { return [...jobs.values()].filter(j => j.sessionId === sessionId && !j.committed && ['running', 'completed'].includes(j.state))
      .flatMap(j => j.frames.map(frame => ({ kind: 'inference:delta', id: j.id, sessionId, frame }))); },
    close() { clearInterval(cleanup); for (const id of jobs.keys()) cancel(id); } };
}
module.exports = { createInference };
