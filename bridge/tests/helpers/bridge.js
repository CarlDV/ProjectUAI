'use strict';
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const root = path.resolve(__dirname, '../../..');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function startBridge(t, args = [], entry = 'bridge/server.js') {
  const reserve = http.createServer();
  reserve.listen(0, '127.0.0.1'); await once(reserve, 'listening');
  const port = reserve.address().port; await new Promise(resolve => reserve.close(resolve));
  const proc = spawn(process.execPath, [entry, '--port', String(port), ...args],
    { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  const stop = async () => {
    if (proc.exitCode !== null || proc.signalCode !== null) return;
    const exited = once(proc, 'exit'); proc.kill(); await exited;
  };
  t?.after(stop);
  let output = '', errors = '';
  proc.stderr.on('data', chunk => errors += chunk);
  const token = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('Bridge did not start: ' + errors)), 10000);
    proc.once('error', error => { clearTimeout(timer); reject(error); });
    proc.once('exit', code => { clearTimeout(timer); reject(Error('Bridge exited (' + code + '): ' + errors)); });
    proc.stdout.on('data', chunk => {
      output += chunk; const match = output.match(/Token\s+([a-f0-9]{64})/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
  });
  return { base: `http://127.0.0.1:${port}`, token, port, proc, stop };
}

async function readStream(base, token, run, headers = {}) {
  const controller = new AbortController(), events = [];
  const response = await fetch(base + '/api/stream', { headers: { Authorization: 'Bearer ' + token, ...headers }, signal: controller.signal });
  if (!response.ok) throw Error('Stream returned ' + response.status);
  const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = '';
  const pump = (async () => {
    try {
      for (;;) {
        const chunk = await reader.read(); if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true });
        let at;
        while ((at = buffer.indexOf('\n\n')) !== -1) {
          const block = buffer.slice(0, at); buffer = buffer.slice(at + 2);
          for (const line of block.split('\n')) if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6)));
        }
      }
    } catch (error) { if (error.name !== 'AbortError') throw error; }
  })();
  try { await run?.(events); await sleep(80); }
  finally { controller.abort(); await pump; }
  return events;
}

module.exports = { root, sleep, startBridge, readStream };
