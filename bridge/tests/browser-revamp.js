// Real Chromium coverage of the bridge redesign. All network work uses loopback fixtures.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { once } = require('node:events');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge, sleep } = require('./helpers/bridge');
const { makePng } = require('./helpers/images');

(async () => {
  const bridge = await startBridge();
  let browser, page, upstream, heartbeat;
  const auth = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  let sequence = 0;
  const post = async (route, body) => {
    const response = await fetch(bridge.base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
    assert.ok(response.ok, route + ': ' + response.status);
    return response.status === 204 ? null : response.json();
  };
  const push = body => post('/api/agent/events', { batchId: 'revamp-' + (++sequence), ...body });
  const state = {
    protocol: 2, runtime: 'web', sessionId: 's1', player: 'David', place: { name: 'Studio garden' },
    agent: { busy: false, status: 'Ready', model: 'local-coder', provider: 'Local provider' },
    threads: [{ id: 's1', title: 'A little room to create', active: true, place: 'Studio garden' }],
    providers: [{ id: 'local', label: 'Local provider', baseUrl: 'http://localhost:1234/v1', model: 'local-coder', models: ['local-coder'], enabled: true }],
    activeProvider: 'local', theme: { canvas: '#111914', surface: '#18211a', text: '#edf0e7' },
    settings: { ui: { density: 'comfortable', transcriptWidth: 'medium' }, agent: { effort: 'high', temperature: 1, maxTurns: 24 } },
    permissions: { mode: 'ask' }, tools: [], todos: [], loops: [], logs: [], requests: [], subagents: [], questions: [], pendingPermissions: [],
    usage: { total: 2480, requests: 3, cost: .004 }, attachments: { inlineLimit: 8000, maxBytes: 2 * 1024 * 1024, available: true },
  };
  try {
    await push({ sessionId: 's1', snapshot: [], state });
    heartbeat = setInterval(() => push({ state }).catch(() => {}), 10000);
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 960 }, colorScheme: 'light', permissions: ['clipboard-read', 'clipboard-write'] });
    page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = [], csp = [], requests = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (/Content Security Policy|violates.*directive/i.test(message.text())) csp.push(message.text()); });
    page.on('request', request => {
      if (request.url().endsWith('/api/command')) requests.push(request.postDataJSON());
    });
    const screenshot = async name => {
      if (!process.env.UAI_SCREENSHOTS) return;
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: 'disabled', fullPage: true });
    };
    const navigate = async name => {
      if (page.viewportSize().width <= 768 && await page.locator('#sidebarToggle').getAttribute('aria-expanded') !== 'true') await page.locator('#sidebarToggle').click();
      await page.locator(`#sidebar [data-page="${name}"]`).first().click();
    };
    const setTheme = async value => { await page.evaluate(mode => UAI.theme.set(mode), value); };
    const fit = async label => {
      const bounds = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth,
        panels: ['workspace', 'panel', 'composer'].map(id => { const n = document.getElementById(id), r = n.getBoundingClientRect(); return { id, visible: !!n.getClientRects().length, left: r.left, right: r.right }; }) }));
      assert.ok(bounds.scroll <= bounds.width, label + ': page overflow ' + JSON.stringify(bounds));
      for (const element of bounds.panels) if (element.visible) assert.ok(element.left >= -.5 && element.right <= bounds.width + .5, label + ': ' + JSON.stringify(element));
    };

    await page.goto(bridge.base); await page.locator('#gate').waitFor({ state: 'visible' });
    assert.match(await page.locator('.gate-help').textContent(), /node UAI\/bridge\/start.txt/);
    await screenshot('bridge-gate-light');
    await page.goto(bridge.base + '/#t=' + bridge.token); await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#modelLabel').textContent === 'local-coder');
    assert.equal(await page.evaluate(() => location.hash), '');
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
    assert.equal(await page.evaluate(() => document.documentElement.style.getPropertyValue('--canvas')), '', 'game palette must not override browser light mode');
    await screenshot('bridge-welcome-light');
    await page.locator('#themeToggle').click(); await page.reload();
    await page.locator('#app').waitFor({ state: 'visible' });
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
    await navigate('settings');
    await page.getByLabel('Theme', { exact: true }).selectOption('game');
    assert.equal(await page.evaluate(() => document.documentElement.style.getPropertyValue('--canvas')), '#111914');
    await page.getByLabel('Theme', { exact: true }).selectOption('light');
    assert.equal(await page.evaluate(() => document.documentElement.style.getPropertyValue('--canvas')), '');
    await navigate('cowork');
    assert.equal(await page.locator('.setup-step').count(), 3);
    assert.match(await page.locator('.setup-step').first().textContent(), /node UAI\/bridge\/start.txt/);
    await page.getByLabel('Your installation').selectOption('repo');
    assert.match(await page.locator('.setup-step').first().textContent(), /node bridge\/server.js/);
    await page.getByLabel('Your installation').selectOption('executor');
    await screenshot('bridge-setup-light');
    await setTheme('dark'); await screenshot('bridge-setup-dark');
    await setTheme('light'); await navigate('chat');

    // Cancelling one of two active uploads must allow the next picture to finish.
    let uploadRequests = 0;
    await page.route('**/api/pictures', async route => {
      if (route.request().method() !== 'POST') return route.continue();
      uploadRequests++;
      assert.ok(route.request().headers()['x-uai-browser-id']); assert.equal(route.request().headers()['x-uai-session-id'], 's1');
      await sleep(350); await route.continue().catch(() => {});
    });
    const image = makePng(96, 72);
    await page.locator('#pictureInput').setInputFiles(['one', 'two', 'three'].map(name => ({ name: name + '.png', mimeType: 'image/png', buffer: image })));
    await page.waitForFunction(() => document.querySelectorAll('.picture-card').length === 3);
    await page.getByRole('button', { name: 'Remove one.png', exact: true }).click();
    await page.waitForFunction(() => document.querySelectorAll('.picture-card[data-status="staged"]').length === 2);
    assert.ok(uploadRequests >= 2); await page.unroute('**/api/pictures');
    await page.locator('#input').fill('Use these colors for a quiet garden. Pictures are previews; I have described what matters.');
    await screenshot('bridge-pictures-ready');
    await page.locator('#send').click();
    const inbox = await (await fetch(bridge.base + '/api/agent/inbox', { headers: auth })).json();
    const sent = inbox.commands.find(command => command.type === 'send'); assert.ok(sent);
    assert.equal((sent.text.match(/\[PICTURE\]/g) || []).length, 2); assert.equal(sent.pictureIds, undefined);
    const user = { kind: 'user', text: sent.text, transcriptId: 10, at: 12345, sessionId: 's1' };
    await push({ events: [user, { kind: 'turn:start', sessionId: 's1' }] });
    await page.locator('#input').fill('Keep this newer draft');
    for (let i = 0; i < 3; i++) await page.locator('#input').press('Enter');
    assert.equal(requests.filter(command => command.type === 'send').length, 1);
    await post('/api/agent/ack', { results: [{ id: sent.commandId, ok: true }] });
    const replyText = '## A quieter corner\n\nStart with warm stone, soft green foliage, and a clear walking path.\n\n| Part | Direction |\n| :--- | ---: |\n| Light | Warm |\n| Scale | Human |\n\n```lua\nlocal garden = workspace:FindFirstChild("Garden")\nprint("Ready, 世界", garden)\n```';
    const savedReply = { kind: 'assistant:text', text: replyText, requestId: 'garden-final', sessionId: 's1' };
    await push({ events: [savedReply, { kind: 'turn:end', sessionId: 's1' }] });
    await page.waitForFunction(() => !document.querySelector('#send').disabled);
    assert.equal(await page.locator('#input').inputValue(), 'Keep this newer draft');
    await page.waitForFunction(() => document.querySelectorAll('.message-picture img').length === 2);
    await page.locator('.copy-code').click();
    const copiedCode = await page.evaluate(() => navigator.clipboard.readText());
    // Windows clipboard text uses CRLF; Unicode and the code itself stay exact.
    assert.equal(copiedCode.replace(/\r\n/g, '\n'), 'local garden = workspace:FindFirstChild("Garden")\nprint("Ready, 世界", garden)');
    await push({ sessionId: 's1', snapshot: [user, savedReply], state });
    await page.reload(); await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => [...document.querySelectorAll('.message-picture img')].filter(img => img.complete && img.naturalWidth === 96).length === 2);
    assert.equal(await page.locator('.message.user').count(), 1); assert.equal(await page.locator('.message.agent').count(), 1);
    assert.equal(await page.locator('#input').inputValue(), 'Keep this newer draft');

    const source = 'local title = "草木🙂"\n'.repeat(2500);
    await page.locator('#fileInput').setInputFiles({ name: 'garden.lua', mimeType: 'text/plain', buffer: Buffer.from(source) });
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('garden.lua'));
    await sleep(700); await page.reload(); await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('garden.lua'));
    assert.equal(await page.evaluate(async () => (await UAI.drafts.load('s1')).uploads[0].text), source);

    const longDraft = 'A longer draft with 世界 and a full ending.\n'.repeat(700);
    await page.locator('#input').fill(longDraft);
    await page.waitForFunction(async text => (await UAI.drafts.load('s1'))?.text === text, longDraft);
    await page.reload();
    await page.waitForFunction(text => document.querySelector('#input').value === text, longDraft);
    assert.equal(await page.locator('#attachments button').count(), 1);

    // Simulate unloading before the newest IndexedDB transaction commits. The
    // small recovery copy must keep newer text alongside the saved file bodies.
    await page.evaluate(() => { UAI.drafts.save = async () => true; });
    await page.locator('#input').fill('A newer edit beside the saved garden file');
    await page.reload();
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('garden.lua'));
    assert.equal(await page.locator('#input').inputValue(), 'A newer edit beside the saved garden file');

    // Typing while storage opens must not discard either the edit or attachments.
    await page.route('**/drafts.js', async route => {
      const response = await route.fetch();
      await route.fulfill({ response, body: await response.text() + '\n{ const load = UAI.drafts.load; UAI.drafts.load = id => new Promise(resolve => { window.finishDraftRestore = () => { UAI.drafts.load = load; return load(id).then(resolve); }; }); }' });
    });
    await page.reload(); await page.waitForFunction(() => typeof window.finishDraftRestore === 'function');
    await page.locator('#input').fill('Typed while my files were restoring');
    assert.equal(await page.locator('#send').isDisabled(), true);
    await page.evaluate(() => window.finishDraftRestore());
    await page.waitForFunction(() => document.querySelector('#attachments').textContent.includes('garden.lua'));
    assert.equal(await page.locator('#input').inputValue(), 'Typed while my files were restoring');
    await page.unroute('**/drafts.js');
    await page.waitForFunction(async () => (await UAI.drafts.load('s1'))?.text === 'Typed while my files were restoring');

    // A stale full draft must not bring a removed file back after a quick reload.
    await page.evaluate(() => { UAI.drafts.save = async () => true; });
    await page.locator('#attachments button').click();
    await page.reload(); await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => !document.querySelector('#send').disabled);
    assert.equal(await page.locator('#attachments button').count(), 0);
    console.log('Redesign: themes, setup commands, upload cancellation, early user events, picture replay, full draft restoration');

    // A missing receipt must lock both button and keyboard submit until reviewed.
    await page.route('**/api/commands/*', route => route.fulfill({ status: 404, json: { error: 'Fixture lost receipt' } }));
    await page.locator('#input').fill('Check this message once'); await page.locator('#send').click();
    await page.locator('#deliveryNotice').waitFor({ state: 'visible' });
    await page.locator('#input').press('Enter'); assert.equal(requests.filter(command => command.type === 'send').length, 2);
    await page.unroute('**/api/commands/*');
    const pending = (await (await fetch(bridge.base + '/api/agent/inbox', { headers: auth })).json()).commands.find(command => command.type === 'send');
    await post('/api/agent/ack', { results: [{ id: pending.commandId, ok: true }] });
    await page.locator('#deliveryCheck').click(); await page.locator('#deliveryNotice').waitFor({ state: 'hidden' });
    assert.equal(await page.locator('#input').inputValue(), '');

    // Stable Markdown nodes survive live updates and final reconciliation while focused.
    let liveResponse;
    const livePrefix = '```lua\nprint("A stable code block")\n```\n\n';
    upstream = http.createServer((req, res) => {
      if (req.url === '/error') { res.writeHead(503, { 'content-type': 'application/json' }); res.end('{"error":"Try later"}'); return; }
      liveResponse = res; res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: ' + JSON.stringify({ choices: [{ delta: { content: livePrefix + 'Growing' } }] }) + '\n\n');
    });
    upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
    const hello = await (await fetch(bridge.base + '/api/hello', { headers: auth })).json();
    await post('/api/inference', { id: 'revamp-live-stream', instance: hello.instance, url: `http://127.0.0.1:${upstream.address().port}/stream`, sessionId: 's1', body: '{}' });
    await page.waitForFunction(() => document.querySelector('.streaming .copy-code'));
    await page.locator('.streaming .copy-code').focus();
    await page.evaluate(() => { window.stableCodeButton = document.querySelector('.streaming .copy-code'); });
    liveResponse.end('data: ' + JSON.stringify({ choices: [{ delta: { content: ' into an idea.' } }] }) + '\n\ndata: [DONE]\n\n');
    await push({ events: [{ kind: 'assistant:text', requestId: 'revamp-live-stream', text: livePrefix + 'Growing into an idea.', sessionId: 's1' }] });
    assert.equal(await page.evaluate(() => document.activeElement === window.stableCodeButton && window.stableCodeButton.isConnected), true);
    await page.locator('#input').focus();
    await page.waitForFunction(() => document.querySelector('#transcript').textContent.includes('Growing into an idea.'));
    await post('/api/inference', { id: 'revamp-http-error', instance: hello.instance, url: `http://127.0.0.1:${upstream.address().port}/error`, sessionId: 's1', body: '{}' });
    await page.waitForFunction(() => document.querySelector('.stream-error')?.textContent.includes('HTTP 503'));
    assert.equal(await page.locator('.stream-error .retry').count(), 1);

    for (const width of [1440, 1024, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 960 });
      await navigate('chat'); await fit('chat ' + width);
      await page.locator('#transcript').evaluate(node => { node.scrollTop = 0; });
      if ([1440, 390, 320].includes(width)) await screenshot('bridge-chat-' + width);
      await navigate('cowork'); await fit('setup ' + width);
      if ([390, 320].includes(width)) {
        await screenshot('bridge-setup-' + width);
        await page.locator('#panel').evaluate(node => { node.scrollTop = node.scrollHeight; });
        await screenshot('bridge-setup-more-' + width);
        await page.locator('#panel').evaluate(node => { node.scrollTop = 0; });
      }
      await navigate('settings'); await fit('settings ' + width);
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator('#sidebarToggle').click();
    assert.equal(await page.locator('#workspace').evaluate(node => node.inert), true);
    await page.locator('#profile').focus(); await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'closeSidebar');
    await screenshot('bridge-mobile-navigation');
    await page.keyboard.press('Escape');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'sidebarToggle');
    assert.equal(await page.locator('#workspace').evaluate(node => node.inert), false);
    assert.equal(await page.locator('#sidebar').evaluate(node => node.inert), true);
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await navigate('chat');
    assert.equal(await page.locator('.message').first().evaluate(node => getComputedStyle(node).animationName), 'none');
    await page.setViewportSize({ width: 1440, height: 1000 });
    // CSS zoom exercises reflow at twice the content size; narrow viewport checks
    // above separately cover the browser-zoom breakpoint behavior.
    await page.evaluate(() => { document.body.style.zoom = '2'; });
    await fit('200 percent zoom'); await screenshot('bridge-chat-zoom');
    await page.evaluate(() => { document.body.style.zoom = ''; });
    await setTheme('dark'); await screenshot('bridge-chat-dark');

    await page.goto(bridge.base + '/#t=' + '0'.repeat(64));
    await page.locator('#gate').waitFor({ state: 'visible' });
    assert.match(await page.locator('#gate-error').textContent(), /token no longer works/);
    await screenshot('bridge-gate-dark');
    await page.locator('#gate-token').fill(bridge.token); await page.locator('#gate-connect').click();
    await page.locator('#app').waitFor({ state: 'visible' });
    assert.deepEqual(errors, []); assert.deepEqual(csp, []);
    console.log('Browser redesign checks passed: delivery recovery, stable code, HTTP errors, 320–1440px, drawer focus, reduced motion, zoom, token recovery, CSP');
  } catch (error) {
    if (page && process.env.UAI_SCREENSHOTS) {
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, 'bridge-failure.png'), animations: 'disabled', fullPage: true }).catch(() => {});
      fs.writeFileSync(path.join(process.env.UAI_SCREENSHOTS, 'bridge-failure.html'), await page.content());
    }
    throw error;
  } finally {
    clearInterval(heartbeat); upstream?.closeAllConnections(); upstream?.close(); await browser?.close(); await bridge.stop();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
