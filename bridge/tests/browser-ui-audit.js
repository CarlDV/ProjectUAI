// Regression coverage for the UI audit: constrained layouts and live state updates.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { startBridge } = require('./helpers/bridge');
const { makePng } = require('./helpers/images');

function rgb(value) {
  if (value.startsWith('#')) {
    const hex = value.slice(1);
    return (hex.length === 3 ? hex.split('').map(c => c + c) : hex.match(/../g)).map(c => parseInt(c, 16));
  }
  return value.match(/[\d.]+/g).slice(0, 3).map(Number);
}
function contrast(foreground, background) {
  const luminance = color => rgb(color).map(channel => {
    const value = channel / 255;
    return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
  }).reduce((sum, value, index) => sum + value * [.2126, .7152, .0722][index], 0);
  const a = luminance(foreground), b = luminance(background);
  return (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
}

(async () => {
  const bridge = await startBridge();
  let browser, page, heartbeat, sequence = 0;
  const auth = { Authorization: 'Bearer ' + bridge.token, 'content-type': 'application/json' };
  const post = async (route, body) => {
    const response = await fetch(bridge.base + route, { method: 'POST', headers: auth, body: JSON.stringify(body) });
    assert.ok(response.ok, route + ': ' + response.status);
    return response.status === 204 ? null : response.json();
  };
  const state = {
    protocol: 2, runtime: 'web', sessionId: 'audit', player: 'UI Auditor', place: { name: 'Fixture garden' },
    agent: { busy: false, status: 'Ready', model: 'fixture-model', provider: 'Fixture provider' },
    threads: [{ id: 'audit', title: 'Audit conversation', active: true, place: 'Fixture garden' }],
    providers: [
      { id: 'p1', label: 'Provider one', baseUrl: 'http://localhost:1234/v1', model: 'fixture-model', models: ['fixture-model', 'alternate-model'], enabled: true },
      { id: 'p2', label: 'Provider two', baseUrl: 'http://localhost:4321/v1', model: 'other-model', models: ['other-model'], enabled: true },
    ],
    activeProvider: 'p1', presets: [{ id: 'custom', label: 'Custom' }],
    settings: { ui: { density: 'comfortable', transcriptWidth: 'medium', codeTheme: 'dark' }, agent: { effort: 'high', temperature: 1, maxTurns: 24, customInstructions: '' } },
    permissions: { mode: 'ask' }, tools: [], todos: [], loops: [], logs: [], requests: [], subagents: [], questions: [], pendingPermissions: [],
    usage: { total: 2480, requests: 3, cost: .004 }, attachments: { inlineLimit: 8000, maxBytes: 2 * 1024 * 1024, available: true },
  };
  const push = async extra => {
    const marker = 'Fixture provider ' + (++sequence);
    state.agent.provider = marker;
    await post('/api/agent/events', { batchId: 'ui-audit-' + sequence, state, ...extra });
    if (page) await page.waitForFunction(value => document.querySelector('#providerName').textContent === value, marker);
  };
  try {
    await push({ sessionId: 'audit', snapshot: [] });
    heartbeat = setInterval(() => post('/api/agent/events', { batchId: 'ui-audit-heartbeat-' + Date.now(), events: [] }).catch(() => {}), 5000);
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 390, height: 568 }, colorScheme: 'light', reducedMotion: 'reduce' });
    page = await context.newPage(); page.setDefaultTimeout(12000);
    const errors = [], outcomes = new Map();
    let commandError = null, unauthorized = false;
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/command', route => {
      if (unauthorized) return route.fulfill({ status: 401, body: 'Invalid token' });
      const command = route.request().postDataJSON();
      outcomes.set(command.commandId, commandError);
      return route.fulfill({ json: { id: command.commandId } });
    });
    await page.route('**/api/commands/*', route => {
      const error = outcomes.get(new URL(route.request().url()).pathname.split('/').at(-1));
      return route.fulfill({ json: { state: 'completed', result: error ? { ok: false, error } : { ok: true, data: { ok: true } } } });
    });
    const navigate = async name => {
      if (page.viewportSize().width <= 768 && await page.locator('#sidebarToggle').getAttribute('aria-expanded') !== 'true') await page.locator('#sidebarToggle').click();
      await page.locator(`#sidebar [data-page="${name}"]`).first().click();
    };
    const screenshot = async name => {
      if (!process.env.UAI_SCREENSHOTS) return;
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, name + '.png'), animations: 'disabled' });
    };
    const bounds = selector => page.locator(selector).evaluate(node => {
      const rect = node.getBoundingClientRect();
      return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, width: rect.width, height: rect.height,
        clientWidth: node.clientWidth, scrollWidth: node.scrollWidth, clientHeight: node.clientHeight, scrollHeight: node.scrollHeight };
    });
    const withinViewport = async (selector, label) => {
      const rect = await bounds(selector), size = page.viewportSize();
      assert.ok(rect.width > 0 && rect.height > 0 && rect.left >= -1 && rect.top >= -1 && rect.right <= size.width + 1 && rect.bottom <= size.height + 1,
        label + ': ' + JSON.stringify(rect));
    };
    const requestFor = type => page.waitForRequest(request => request.url().endsWith('/api/command') && request.postDataJSON()?.type === type);
    const activeKey = () => page.evaluate(() => document.activeElement.dataset.focusKey);
    const closeModal = async () => { await page.locator('#modalClose').click(); await page.locator('#modal').waitFor({ state: 'hidden' }); };

    await page.goto(bridge.base + '/#t=' + bridge.token);
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#modelLabel').textContent === 'fixture-model');

    const palette = await page.evaluate(() => {
      const css = getComputedStyle(document.documentElement);
      return Object.fromEntries(['textTertiary', 'canvas', 'sidebar', 'surface', 'surfaceRaised', 'surfaceActive', 'sunk'].map(name => [name, css.getPropertyValue('--' + name).trim()]));
    });
    for (const [surface, color] of Object.entries(palette)) if (surface !== 'textTertiary') {
      assert.ok(contrast(palette.textTertiary, color) >= 4.5, 'small light-theme text must meet 4.5:1 on ' + surface);
    }

    // An expanded, valid-sized task list must leave the conversation controls usable.
    state.todos = Array.from({ length: 24 }, (_, index) => ({ id: 'todo-' + index, status: 'pending',
      text: 'Inspect the selected garden objects, confirm their placement, and describe the change before moving to the next step ' + index }));
    await push(); await page.locator('#taskStrip summary').click();
    const tasks = await bounds('#taskStrip'), transcript = await bounds('#transcript');
    assert.ok(tasks.height < page.viewportSize().height / 2, 'expanded tasks must have a height bound');
    assert.ok(tasks.scrollHeight > tasks.clientHeight, 'long task lists must scroll inside the strip');
    assert.ok(transcript.height > 32, 'expanded tasks must leave a usable transcript');
    await withinViewport('#send', 'Send below expanded tasks');
    state.todos[0].status = 'done'; await push();
    assert.equal(await page.locator('#taskStrip details').evaluate(node => node.open), true, 'task updates must preserve disclosure state');
    await screenshot('bridge-audit-tasks');
    state.todos = []; await push();

    // Updating the queue must preserve the in-progress response, checkbox and focus.
    state.questions = [{ id: 'q1', question: 'How should we build this?', options: ['Small', 'Large'], sessionTitle: 'Garden design' }];
    state.pendingPermissions = [{ id: 'perm1', name: 'file_write', sessionId: 'background-work', args: { path: 'garden.lua' } }];
    await push();
    const answer = page.locator('[data-request-key="question:q1"] input[type=text]');
    const remember = page.locator('[data-request-key="permission:perm1"] input[type=checkbox]');
    const draft = 'Keep my unfinished answer';
    assert.match(await page.locator('[data-request-key="permission:perm1"]').textContent(), /background-work/,
      'background permissions must identify their conversation');
    await remember.check(); await answer.fill(draft); await answer.evaluate(node => node.setSelectionRange(5, 12));
    state.questions.unshift({ id: 'q2', question: 'Which color?', options: ['Green', 'Blue'] });
    await push();
    assert.equal(await answer.inputValue(), draft); assert.equal(await remember.isChecked(), true);
    assert.deepEqual(await answer.evaluate(node => ({ focused: document.activeElement === node, start: node.selectionStart, end: node.selectionEnd })),
      { focused: true, start: 5, end: 12 }, 'queue refresh must retain the active answer and selection');
    assert.ok(await answer.getAttribute('aria-labelledby'), 'the custom answer must have a programmatic question label');
    const sentAnswer = requestFor('ask:answer'); await answer.press('Enter');
    const answerCommand = (await sentAnswer).postDataJSON();
    assert.equal(answerCommand.id, 'q1'); assert.equal(answerCommand.text, draft);
    state.questions = []; state.pendingPermissions = []; await push();

    // Place the latest button against the transcript even as the draft grows.
    await page.setViewportSize({ width: 1280, height: 800 });
    const snapshot = Array.from({ length: 20 }, (_, index) => ({ kind: index % 2 ? 'assistant:text' : 'user', sessionId: 'audit',
      text: 'Message ' + index + '\n\n' + 'A paragraph in the conversation. '.repeat(10) }));
    snapshot.push({ kind: 'assistant:text', sessionId: 'audit', text: '```lua\nprint("hello")\n```' });
    await push({ sessionId: 'audit', snapshot });
    const longDraft = Array.from({ length: 15 }, (_, index) => 'Line of a draft ' + index).join('\n');
    await page.locator('#input').fill(longDraft);
    await page.locator('#transcript').evaluate(node => { node.scrollTop = 0; node.dispatchEvent(new Event('scroll')); });
    await page.locator('#latest').waitFor({ state: 'visible' });
    const latest = await bounds('#latest'), composer = await bounds('#composer'), conversation = await bounds('#transcript');
    assert.ok(latest.top >= conversation.top - 1 && latest.bottom <= conversation.bottom + 1 && latest.bottom <= composer.top,
      'Jump to latest must remain above the expanded composer');

    // A redraw caused by removing a different image must not steal keyboard focus.
    await page.locator('#pictureInput').setInputFiles([
      { name: 'garden-one.png', mimeType: 'image/png', buffer: makePng(96, 64) },
      { name: 'garden-two.png', mimeType: 'image/png', buffer: makePng(80, 60) },
    ]);
    await page.waitForFunction(() => document.querySelectorAll('.picture-card[data-status=staged]').length === 2);
    const retainedPicture = await page.locator('.picture-card').nth(1).getAttribute('data-picture-id');
    await page.locator('.picture-remove').nth(1).focus();
    await page.locator('.picture-remove').first().evaluate(node => node.click());
    assert.equal(await page.evaluate(() => document.activeElement.closest('.picture-card')?.dataset.pictureId), retainedPicture,
      'redrawing the tray must preserve focus on the surviving picture control');

    await page.locator('#fileInput').setInputFiles(Array.from({ length: 16 }, (_, index) => ({
      name: 'garden-script-' + index + '.lua', mimeType: 'text/plain', buffer: Buffer.from('return ' + index),
    })));
    await page.waitForFunction(() => document.querySelectorAll('#attachments button').length === 16 && !document.querySelector('#send').disabled);
    for (const size of [{ width: 844, height: 390 }, { width: 320, height: 480 }]) {
      await page.setViewportSize(size);
      await withinViewport('#send', 'Send with a full composer at ' + size.width + 'x' + size.height);
      await page.locator('#send').click({ trial: true });
      const toolbar = await bounds('.composer-toolbar');
      assert.ok(toolbar.scrollWidth <= toolbar.clientWidth + 1, 'composer controls must not overlap horizontally');
      assert.equal(await page.locator('#input').inputValue(), longDraft);
      await screenshot('bridge-audit-composer-' + size.width);
    }
    // All three regions can be present together on the shortest supported layouts.
    state.todos = Array.from({ length: 24 }, (_, index) => ({ id: 'combined-' + index, status: 'pending', text: 'Inspect the garden and record changes before proceeding ' + index }));
    state.questions = [{ id: 'combined-question', question: 'Which garden should be changed?', options: ['Small garden', 'Large garden'] }];
    await push();
    if (!await page.locator('#taskStrip details').evaluate(node => node.open)) await page.locator('#taskStrip summary').click();
    await page.locator('#transcript').evaluate(node => { node.scrollTop = 0; node.dispatchEvent(new Event('scroll')); });
    const combinedTranscript = await bounds('#transcript'), combinedLatest = await bounds('#latest'), questions = await bounds('#questions');
    assert.ok(combinedTranscript.height >= 64, 'combined strips must leave a real transcript scrollport');
    assert.ok(combinedLatest.top >= combinedTranscript.top && combinedLatest.bottom <= combinedTranscript.bottom,
      'latest must stay inside the transcript when tasks, questions and attachments coexist');
    assert.ok(questions.height >= 64 && questions.top >= combinedTranscript.bottom - 1, 'questions must not overlap the transcript');
    assert.equal(await page.locator('#chatPage').evaluate(node => getComputedStyle(node).overflowY), 'auto');
    await page.locator('#chatPage').evaluate(node => { node.scrollTop = node.scrollHeight; });
    await withinViewport('#send', 'Send remains reachable in the combined short-screen state');
    await screenshot('bridge-audit-combined');
    state.todos = []; state.questions = []; await push();
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.locator('#input').fill('');
    while (await page.locator('#attachments button').count()) await page.locator('#attachments button').first().click();
    await page.locator('.picture-remove').click();

    // Live selections must update while their activating buttons still have focus.
    await navigate('cowork');
    await page.locator('[data-focus-key="runtime:game"]').click(); state.runtime = 'game'; await push();
    assert.equal(await page.locator('[data-focus-key="runtime:game"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.locator('[data-focus-key="runtime:web"]').getAttribute('aria-pressed'), 'false');
    assert.equal(await activeKey(), 'runtime:game');
    await navigate('settings');
    await page.locator('[data-focus-key="permission:readonly"]').click(); state.permissions.mode = 'readonly'; await push();
    assert.equal(await page.locator('[data-focus-key="permission:readonly"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await activeKey(), 'permission:readonly');
    await page.getByText('Agent behavior', { exact: true }).click();
    const instructions = page.locator('[data-setting="agent.customInstructions"]');
    await instructions.fill('An unfinished instruction'); await instructions.evaluate(node => node.setSelectionRange(3, 11));
    state.usage.total += 100; await push();
    assert.equal(await instructions.inputValue(), 'An unfinished instruction');
    assert.deepEqual(await instructions.evaluate(node => ({ focused: document.activeElement === node, start: node.selectionStart, end: node.selectionEnd })),
      { focused: true, start: 3, end: 11 }, 'live state updates must preserve active setting edits');
    // A deferred refresh must not remove a button between pointerdown and click.
    const permissionRequest = requestFor('permission-mode');
    const permissionButton = page.locator('[data-focus-key="permission:ask"]');
    await permissionButton.scrollIntoViewIfNeeded();
    const permissionBox = await permissionButton.boundingBox();
    await page.mouse.move(permissionBox.x + permissionBox.width / 2, permissionBox.y + permissionBox.height / 2);
    await page.mouse.down(); state.usage.total += 1; await push(); await page.mouse.up();
    assert.equal((await permissionRequest).postDataJSON().mode, 'ask', 'the button pressed after editing must still receive its click');
    await navigate('providers');
    await page.locator('[data-focus-key="provider:p2:use"]').click(); state.activeProvider = 'p2'; await push();
    assert.equal(await page.locator('[data-focus-key="provider:p2:use"]').textContent(), 'Active');
    assert.equal(await page.locator('[data-focus-key="provider:p1:use"]').textContent(), 'Use');
    assert.equal(await activeKey(), 'provider:p2:use');

    await navigate('chat'); await page.locator('#modelButton').click();
    await page.getByLabel('Provider', { exact: true }).selectOption('p1');
    await page.getByLabel('Search models', { exact: true }).fill('model');
    await page.locator('#modal [data-model="alternate-model"]').click();
    state.providers[0].model = 'alternate-model'; state.agent.model = 'alternate-model'; await push();
    assert.equal(await page.locator('#modal [data-model="alternate-model"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.locator('#modal [data-model="fixture-model"]').getAttribute('aria-pressed'), 'false');
    assert.equal(await page.getByLabel('Search models', { exact: true }).inputValue(), 'model');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.model), 'alternate-model');
    await closeModal();

    await page.locator('#clear').click();
    assert.equal(await page.locator('#clear').getAttribute('aria-label'), 'Confirm clear', 'armed actions must expose their confirmation label');

    // Long content should wrap inside cards, dialogs and independently scrolling lists.
    state.providers[0].baseUrl = 'https://example.test/api/deployments/' + 'deployment'.repeat(18) + '/chat/completions';
    state.providers[0].model = 'model-' + 'version'.repeat(25);
    state.requests = [{ status: 'failed', method: 'POST', url: state.providers[0].baseUrl, ms: 12 }];
    state.threads[0].title = 'T'.repeat(60); await push();
    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      for (const name of ['providers', 'logs']) {
        await navigate(name);
        const panel = await bounds('#panel');
        assert.ok(panel.scrollWidth <= panel.clientWidth + 1, name + ' long content must not overflow at ' + width + 'px');
        assert.equal(await page.locator('#panel .card').evaluateAll(nodes => nodes.every(node => node.scrollWidth <= node.clientWidth + 1)), true);
      }
      await page.locator('#sidebarToggle').click(); await page.locator('.thread-menu').click();
      const title = await bounds('#modalTitle'), close = await bounds('#modalClose'), modal = await bounds('#modal');
      assert.ok(title.scrollWidth <= title.clientWidth + 1 && title.right <= close.left + 1, 'long dialog title must leave room for Close');
      assert.ok(modal.scrollWidth <= modal.clientWidth + 1, 'long dialog title must not widen the modal');
      await withinViewport('#modalClose', 'Close for a long dialog title'); await closeModal();
    }
    state.providers[0].models = Array.from({ length: 14 }, (_, index) => 'meta-llama/llama-3.3-70b-instruct-long-model-name-' + index + ':free');
    state.activeProvider = 'p1'; await push(); await navigate('chat'); await page.locator('#modelButton').click();
    const modelRows = await page.locator('#modal .model-list button').evaluateAll(nodes => nodes.map(node => ({ client: node.clientHeight, scroll: node.scrollHeight,
      top: node.getBoundingClientRect().top, bottom: node.getBoundingClientRect().bottom })));
    assert.equal(modelRows.length, 14);
    modelRows.forEach((row, index) => {
      assert.ok(row.scroll <= row.client + 1, 'model row ' + index + ' must contain its wrapped label');
      if (index) assert.ok(row.top >= modelRows[index - 1].bottom, 'model rows must not overlap');
    });
    await closeModal();

    // The code theme is independent of the browser theme, including hover colors.
    await page.setViewportSize({ width: 1280, height: 800 });
    for (const [theme, codeTheme] of [['dark', 'light'], ['light', 'dark']]) {
      state.settings.ui.codeTheme = codeTheme; await push(); await page.evaluate(value => UAI.theme.set(value), theme);
      await page.locator('.copy-code').last().hover();
      const colors = await page.locator('.copy-code').last().evaluate(node => ({ foreground: getComputedStyle(node).color, background: getComputedStyle(node).backgroundColor }));
      assert.ok(contrast(colors.foreground, colors.background) >= 4.5, codeTheme + ' code Copy hover must be readable in ' + theme + ' browser theme');
    }
    await navigate('settings'); await page.getByText('Workspace appearance', { exact: true }).click();
    const saveError = 'Fixture: this change could not be saved.';
    commandError = saveError; await page.locator('[data-setting="ui.density"]').selectOption('compact');
    await page.waitForFunction(() => document.querySelector('.setting[data-state=error] .save-status')?.textContent.includes('could not be saved'));
    const failureColors = await page.locator('.setting[data-state=error] .save-status').evaluate(node => ({
      actual: getComputedStyle(node).color, danger: getComputedStyle(node).getPropertyValue('--danger').trim(),
    }));
    assert.deepEqual(rgb(failureColors.actual), rgb(failureColors.danger), 'failed settings saves must use the error color');
    commandError = null;

    await page.setViewportSize({ width: 390, height: 844 }); await navigate('providers');
    await page.getByRole('button', { name: '＋ Add provider', exact: true }).click();
    await page.getByLabel('Name', { exact: true }).fill('Audited provider');
    commandError = saveError; await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.waitForFunction(text => document.querySelector('#modalNotice')?.textContent.includes(text), saveError);
    const notice = page.locator('#modalNotice');
    assert.equal(await notice.getAttribute('role'), 'status'); assert.equal(await notice.getAttribute('aria-live'), 'polite');
    assert.equal(await notice.evaluate(node => !!node.closest('dialog[open]')), true, 'dialog errors must be inside the modal top layer');
    await withinViewport('#modalNotice', 'New dialog error');
    assert.equal(await notice.evaluate(node => {
      const rect = node.getBoundingClientRect(), top = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
      return top === node || node.contains(top);
    }), true, 'the dialog error must be visible above its backdrop');
    assert.equal(await page.getByLabel('Name', { exact: true }).inputValue(), 'Audited provider');
    await screenshot('bridge-audit-dialog-error'); await closeModal(); commandError = null;

    // Choosing a conversation from a panel must close mobile navigation and open Chat.
    const threadRequest = requestFor('thread');
    await page.locator('#sidebarToggle').click(); await page.locator('.thread > button').first().click();
    assert.equal((await threadRequest).postDataJSON().id, 'audit');
    await page.waitForFunction(() => document.body.dataset.page === 'chat');
    assert.equal(await page.locator('#sidebarToggle').getAttribute('aria-expanded'), 'false');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'input');

    await navigate('chat'); state.agent.busy = true; await push(); await page.emulateMedia({ forcedColors: 'active' });
    await page.locator('#input').focus();
    const forced = await page.evaluate(() => {
      const glyph = getComputedStyle(document.querySelector('#stop span')), button = getComputedStyle(document.querySelector('#stop'));
      return { glyph: glyph.backgroundColor, button: button.backgroundColor, borderColor: glyph.borderTopColor,
        border: glyph.borderTopStyle !== 'none' && parseFloat(glyph.borderTopWidth) > 0,
        focus: ['input', 'composer'].some(id => { const style = getComputedStyle(document.getElementById(id)); return style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0; }) };
    });
    assert.ok(Math.max(contrast(forced.glyph, forced.button), forced.border ? contrast(forced.borderColor, forced.button) : 1) >= 3,
      'the stop glyph must remain visible in forced colors');
    assert.equal(forced.focus, true, 'the composer must retain a focus indicator in forced colors');
    await screenshot('bridge-audit-forced-colors'); await page.emulateMedia({ forcedColors: 'none' });
    state.agent.busy = false; await push();

    // Reauthentication must remove the modal top layer and move focus to the token.
    await navigate('providers'); await page.getByRole('button', { name: '＋ Add provider', exact: true }).click();
    unauthorized = true; await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.locator('#gate').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#modal').evaluate(node => node.open), false, '401 must dismiss the stale modal');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'gate-token');
    await page.locator('#gate-token').fill(bridge.token);
    assert.equal(await page.locator('#gate-token').inputValue(), bridge.token, 'the token form must remain operable');
    assert.deepEqual(errors, []);
    console.log('UI audit checks passed: bounded tasks/composer, stable pending input, live selections, wrapped content, modal errors/recovery, contrast and forced colors');
  } catch (error) {
    if (page && process.env.UAI_SCREENSHOTS) {
      fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.UAI_SCREENSHOTS, 'bridge-ui-audit-failure.png'), animations: 'disabled' }).catch(() => {});
      fs.writeFileSync(path.join(process.env.UAI_SCREENSHOTS, 'bridge-ui-audit-failure.html'), await page.content());
    }
    throw error;
  } finally {
    clearInterval(heartbeat); await browser?.close(); await bridge.stop();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
