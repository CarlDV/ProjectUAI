// Browser behavior and layout checks. No screenshots or image inspection.
'use strict';
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const http = require('node:http');
const { once } = require('node:events');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const reserve = http.createServer();
  reserve.listen(0, '127.0.0.1');
  await once(reserve, 'listening');
  const port = reserve.address().port;
  await new Promise(resolve => reserve.close(resolve));
  const server = spawn(process.execPath, ['bridge/server.js', '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
  let browser;
  try {
    const token = await new Promise((resolve, reject) => {
      let output = '';
      const timer = setTimeout(() => reject(Error('Bridge did not start')), 5000);
      server.stdout.on('data', chunk => {
        output += chunk;
        const match = output.match(/Token\s+([a-f0-9]{64})/);
        if (match) { clearTimeout(timer); resolve(match[1]); }
      });
    });
    const base = `http://127.0.0.1:${port}`;
    const headers = { Authorization: 'Bearer ' + token, 'content-type': 'application/json' };
    let sequence = 0;
    const post = async body => {
      const response = await fetch(base + '/api/agent/events', { method: 'POST', headers, body: JSON.stringify({ batchId: 'workflow-' + (++sequence), ...body }) });
      assert.ok(response.ok);
    };
    const state = {
      protocol: 2, runtime: 'game', sessionId: 's1', player: 'Tester',
      agent: { status: 'Ready', busy: false, model: 'fixture-model' },
      threads: [{ id: 's1', title: 'First', active: true }, { id: 's2', title: 'Second' }],
      providers: [], settings: { ui: {}, agent: {} }, permissions: { mode: 'full' },
      tools: [
        { name: 'run_luau', risk: 'danger', group: 'script', available: true, enabled: true,
          parameters: { required: ['code'], properties: {
            code: { type: 'string', minLength: 1, description: 'Source to run.' },
            timeout: { type: 'number', minimum: 1, maximum: 60 },
          } } },
        { name: 'file_edit', risk: 'write', group: 'fs', available: true, enabled: true,
          parameters: { required: ['path', 'old_text', 'new_text'], properties: {
            path: { type: 'string' }, old_text: { type: 'string', minLength: 1 }, new_text: { type: 'string' }, replace_all: { type: 'boolean' },
          } } },
        { name: 'schema_probe', risk: 'read', group: 'test', available: true, enabled: true,
          parameters: { required: ['items'], properties: { items: { type: 'array' }, mode: { type: 'string', enum: ['read', 'write'] }, enabled: { type: 'boolean' } } } },
      ],
    };
    const switchTo = id => post({ snapshot: [], sessionId: id, state: { ...state, sessionId: id, threads: state.threads.map(t => ({ ...t, active: t.id === id })) } });
    await switchTo('s1');
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [], commands = [], receipts = new Map();
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/command', async route => {
      const command = route.request().postDataJSON();
      commands.push(command);
      const result = command.type === 'send' ? null : { ok: true, data: { ok: true, text: 'Fixture execution result.' } };
      receipts.set(command.commandId, result);
      await route.fulfill({ json: { id: command.commandId } });
    });
    await page.route('**/api/commands/*', route => {
      const id = route.request().url().split('/').pop(), result = receipts.get(id);
      return route.fulfill({ json: result ? { state: 'completed', result } : { state: 'queued' } });
    });
    const waitCommands = async count => {
      for (let i = 0; i < 100 && commands.length < count; i++) await sleep(20);
      assert.equal(commands.length, count);
      return commands[count - 1];
    };
    const openTool = async name => {
      await page.locator('#sidebar [data-page="tools"]').click();
      await page.locator('.tool-grid .card').filter({ has: page.getByRole('heading', { name, exact: true }) }).getByRole('button', { name: 'Run…', exact: true }).click();
    };
    const parameter = name => page.locator(`#modal [data-parameter="${name}"]`);
    const resultClose = async () => {
      await page.waitForFunction(() => document.querySelector('#modalTitle').textContent.endsWith(' result'));
      await page.locator('#modalClose').click();
    };
    await page.goto(base + '/#t=' + token);
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#modelLabel').textContent === 'fixture-model');
    assert.ok(await page.locator('#send').isDisabled());

    await openTool('run_luau');
    assert.equal(await parameter('code').evaluate(node => node.tagName), 'TEXTAREA');
    const code = 'local greeting = "世界"\nprint(greeting)\nreturn { answer = 42 }';
    await parameter('code').fill(code);
    await parameter('timeout').fill('90');
    await page.getByRole('button', { name: 'Run tool', exact: true }).click();
    assert.equal(commands.length, 0);
    assert.equal(await parameter('code').inputValue(), code);
    await parameter('timeout').fill('6.5');
    await page.getByRole('button', { name: 'Run tool', exact: true }).click();
    const execution = await waitCommands(1);
    assert.deepEqual(execution.arguments, { code, timeout: 6.5 });
    await resultClose();

    await openTool('schema_probe');
    assert.equal(await parameter('mode').evaluate(node => node.tagName), 'SELECT');
    assert.equal(await parameter('enabled').evaluate(node => node.tagName), 'SELECT');
    await parameter('items').fill('{"incorrect":"object"}');
    await page.getByRole('button', { name: 'Run tool', exact: true }).click();
    assert.match(await page.locator('.form-error').textContent(), /JSON array/);
    assert.equal(commands.length, 1);
    await parameter('items').fill('[1, 2]');
    await parameter('enabled').selectOption('false');
    await parameter('mode').selectOption('write');
    await page.getByRole('button', { name: 'Run tool', exact: true }).click();
    assert.deepEqual((await waitCommands(2)).arguments, { items: [1, 2], mode: 'write', enabled: false });
    await resultClose();

    await openTool('file_edit');
    await parameter('path').fill('code.lua');
    await parameter('old_text').fill('remove this\n');
    await page.getByRole('button', { name: 'Run tool', exact: true }).click();
    assert.equal((await waitCommands(3)).arguments.new_text, '');
    await resultClose();
    console.log('Tool forms: multiline code, bounds, JSON types, booleans, enums, empty replacements');

    await page.locator('#input').fill('Draft prompt');
    await page.locator('#input').evaluate(input => input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true })));
    await sleep(100);
    assert.equal(commands.length, 3, 'IME confirmation must not submit');
    await page.locator('#fileInput').setInputFiles({ name: 'before.lua', mimeType: 'text/plain', buffer: Buffer.from('return 1') });
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('before.lua'));
    await page.locator('#send').click();
    const sent = await waitCommands(4);
    assert.match(sent.text, /Attached: before.lua/);
    await page.locator('#fileInput').setInputFiles({ name: 'new.lua', mimeType: 'text/plain', buffer: Buffer.from('return 2') });
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('new.lua'));
    await page.locator('#input').fill('New draft');
    await page.locator('#input').fill('Draft prompt');
    receipts.set(sent.commandId, { ok: true });
    await page.waitForFunction(() => !document.querySelector('#send').disabled);
    assert.equal(await page.locator('#input').inputValue(), 'Draft prompt');
    assert.equal(await page.locator('#attachments button').count(), 1);
    assert.match(await page.locator('#attachments').textContent(), /new.lua/);

    await page.evaluate(() => {
      const read = File.prototype.text;
      File.prototype.text = function() { return this.name === 'slow.txt' ? new Promise(resolve => { window.finishFileRead = resolve; }) : read.call(this); };
    });
    await page.locator('#fileInput').setInputFiles({ name: 'slow.txt', mimeType: 'text/plain', buffer: Buffer.from('slow') });
    await page.waitForFunction(() => typeof window.finishFileRead === 'function');
    await switchTo('s2');
    await page.waitForFunction(() => document.querySelector('#input').value === '');
    await page.evaluate(() => window.finishFileRead('Finished in the original conversation'));
    await sleep(100);
    assert.equal(await page.locator('#attachments button').count(), 0);
    await switchTo('s1');
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('slow.txt'));
    assert.equal(await page.locator('#input').inputValue(), 'Draft prompt');
    console.log('Composer: IME, send acknowledgements, newer drafts and attachments, asynchronous file reads');

    await page.evaluate(() => {
      window.originalSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function() { throw new DOMException('Quota reached', 'QuotaExceededError'); };
    });
    await page.locator('#input').fill('Storage fallback draft');
    await switchTo('s2');
    await page.waitForFunction(() => document.querySelector('#input').value === '');
    await switchTo('s1');
    await page.waitForFunction(() => document.querySelector('#input').value === 'Storage fallback draft');
    await page.evaluate(() => { Storage.prototype.setItem = window.originalSetItem; });

    await post({ events: [
      { kind: 'tool:call', id: 'shared', name: 'run_luau', arguments: JSON.stringify({ code }), sessionId: 's1' },
      { kind: 'subagent:tool', id: 'child', callId: 'shared', name: 'run_luau', arguments: '{}', sessionId: 's1' },
      { kind: 'tool:progress', id: 'shared', name: 'run_luau', text: 'Main progress only', sessionId: 's1' },
      { kind: 'subagent:tool:done', id: 'child', callId: 'shared', name: 'run_luau', summary: 'CHILD_SUMMARY', ok: true, sessionId: 's1' },
    ] });
    await page.waitForFunction(() => document.querySelector('#transcript').textContent.includes('CHILD_SUMMARY'));
    const rows = page.locator('.tool-call');
    assert.equal(await rows.count(), 2);
    assert.equal(await rows.first().locator('.tool-status').textContent(), 'Running');
    assert.equal(await rows.first().locator(':scope > .tool-listing pre code').textContent(), code);
    assert.match(await rows.last().locator('.tool-status').textContent(), /Done/);
    await post({ events: [{ kind: 'tool:error', id: 'shared', name: 'run_luau', ok: false, data: { status: 'aborted' }, text: 'Stopped.', sessionId: 's1' }] });
    await page.waitForFunction(() => document.querySelector('.tool-status').textContent === 'Stopped');
    assert.equal(await rows.first().locator('details').getAttribute('open'), '');

    await post({ snapshot: [{ kind: 'tool:call', id: 'old', name: 'file_read', arguments: '{}' }], sessionId: 's1', state });
    await page.waitForFunction(() => document.querySelector('.tool-status')?.textContent === 'No saved result');
    const history = Array.from({ length: 20 }, (_, i) => ({ kind: 'assistant:text', text: `Reply ${i}\n\n` + 'Readable text. '.repeat(30), sessionId: 's1' }));
    await post({ snapshot: history, sessionId: 's1', state });
    await page.waitForFunction(() => document.querySelectorAll('.message.agent').length === 20);
    await page.locator('#transcript').evaluate(node => { node.scrollTop = 0; });
    await post({ events: [{ kind: 'assistant:text', text: 'Newest reply', sessionId: 's1' }] });
    await page.waitForFunction(() => document.querySelectorAll('.message.agent').length === 21);
    assert.equal(await page.locator('#transcript').evaluate(node => node.scrollTop), 0);
    await page.locator('#latest').click();
    await post({ events: [{ kind: 'tool:call', id: 'bottom', name: 'run_luau', arguments: JSON.stringify({ code: 'print(1)\n'.repeat(30) }), sessionId: 's1' }] });
    await page.waitForFunction(() => document.querySelectorAll('.tool-call').length === 1);
    assert.ok(await page.locator('#transcript').evaluate(node => node.scrollHeight - node.scrollTop - node.clientHeight < 4));
    console.log('Transcript: scoped progress, child results, code listings, restored state, reading position');

    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      await page.locator('#sidebarToggle').click();
      assert.equal(await page.locator('#sidebarToggle').getAttribute('aria-expanded'), 'true');
      await page.locator('#sidebar [data-page="tools"]').click();
      assert.equal(await page.locator('#sidebarToggle').getAttribute('aria-expanded'), 'false');
      await page.locator('.tool-grid .card').first().getByRole('button', { name: 'Run…', exact: true }).click();
      await parameter('code').fill('local long_line = "' + 'x'.repeat(400) + '"');
      const dimensions = await page.locator('#modal').evaluate(node => ({ left: node.getBoundingClientRect().left, right: node.getBoundingClientRect().right, width: innerWidth }));
      assert.ok(dimensions.left >= 0 && dimensions.right <= dimensions.width);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      await page.locator('#modalClose').click();
    }
    assert.deepEqual(errors, []);
    console.log('Browser workflow checks passed, including storage failures and 320px/390px layouts');
  } finally {
    await browser?.close();
    server.kill();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
