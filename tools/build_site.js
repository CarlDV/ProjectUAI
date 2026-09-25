'use strict';

// The root files are the website source. Generated regions use the bundled tool
// registry, and docs/ is an exact publishing mirror. No browser or network needed.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const check = process.argv.includes('--check');
const bundleOnly = process.argv.includes('--bundle-only');
const luajit = process.env.LUAJIT || 'luajit';
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const normalize = text => text.replace(/\r\n/g, '\n').trimEnd();

function verifyBundle() {
  const bundle = normalize(read('dist/uai.lua'));
  let count = 0;
  function walk(directory) {
    for (const item of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
      const file = directory + '/' + item.name;
      if (item.isDirectory()) walk(file);
      else if (item.name.endsWith('.lua')) {
        const id = file.slice(4, -4);
        const wrapped = '__UAI_MODULES["' + id + '"] = (function()\n' +
          normalize(read(file)) + '\nend)()';
        if (!bundle.includes(wrapped)) throw new Error('Bundle is stale at ' + file + '; run luajit tools/bundle.lua.');
        count++;
      }
    }
  }
  walk('src');
  if (count !== [...bundle.matchAll(/^__UAI_MODULES\["[^"]+"\] = \(function\(\)$/gm)].length ||
      !bundle.endsWith(normalize(read('init.lua')))) {
    throw new Error('Bundle does not match the source tree; run luajit tools/bundle.lua.');
  }
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);
}

function replaceRegion(html, name, content) {
  const start = '<!-- site:' + name + ':start -->';
  const end = '<!-- site:' + name + ':end -->';
  const expression = new RegExp(start + '[\\s\\S]*?' + end, 'g');
  if (!expression.test(html)) throw new Error('Missing generated region: ' + name);
  return html.replace(expression, () => start + content + end);
}

function build() {
  verifyBundle();
  const catalog = JSON.parse(execFileSync(luajit, ['tools/site_catalog.lua'], {
    cwd: root, encoding: 'utf8', windowsHide: true, maxBuffer: 4 * 1024 * 1024,
  }));
  const priority = ['instance', 'script', 'fs', 'agentself'];
  const rank = id => priority.includes(id) ? priority.indexOf(id) : priority.length;
  const groups = [...catalog.groups].sort((a, b) =>
    rank(a.id) - rank(b.id) || a.label.localeCompare(b.label, 'en'));
  const risks = { read: 'Read', write: 'Write', danger: 'High impact' };
  const toolNames = new Set();
  const groupIds = new Set(groups.map(group => group.id));
  for (const tool of catalog.tools) {
    if (toolNames.has(tool.name) || !groupIds.has(tool.group) || !risks[tool.risk] || !tool.description) {
      throw new Error('Invalid catalog entry: ' + tool.name);
    }
    toolNames.add(tool.name);
  }
  const groupMarkup = groups.map(group => {
    const tools = catalog.tools.filter(tool => tool.group === group.id);
    if (tools.length !== group.total) throw new Error('Incorrect count for ' + group.id);
    const rows = tools.map(tool => {
      const needs = tool.needs.length
        ? '<span class="tool-needs">Requires ' + tool.needs.map(escapeHtml).join(', ') + '</span>' : '';
      return '              <li class="tool-row" data-tool-name="' + escapeHtml(tool.name) + '">\n' +
        '                <div class="tool-row-heading"><code>' + escapeHtml(tool.name) + '</code>' +
        '<span class="risk risk-' + escapeHtml(tool.risk) + '">' + risks[tool.risk] + '</span></div>\n' +
        '                <p>' + escapeHtml(tool.description) + '</p>' + needs + '\n' +
        '              </li>';
    }).join('\n');
    return '          <details class="tool-group" data-group="' + escapeHtml(group.id) + '"' +
      (group.id === 'instance' ? ' open' : '') + '>\n' +
      '            <summary><span class="tool-group-label">' + escapeHtml(group.label) + '</span>' +
      '<span class="tool-group-count">' + tools.length + ' tools</span><span class="disclosure" aria-hidden="true">+</span></summary>\n' +
      '            <ul class="tool-list">\n' + rows + '\n            </ul>\n' +
      '          </details>';
  }).join('\n');
  const options = groups.map(group => '<option value="' + escapeHtml(group.id) + '">' +
    escapeHtml(group.label) + ' (' + group.total + ')</option>').join('');

  let html = read('index.html').replace(/\r\n/g, '\n');
  for (const [name, content] of Object.entries({
    version: escapeHtml(catalog.version),
    'tool-count': String(catalog.tools.length),
    'group-count': String(groups.length),
    catalog: '\n' + groupMarkup + '\n          ',
    categories: options,
  })) html = replaceRegion(html, name, content);
  for (const match of html.matchAll(/data-tool-ref="([^"]+)"/g)) {
    if (!toolNames.has(match[1])) throw new Error('Website references an unknown tool: ' + match[1]);
  }

  const files = new Map([
    ['index.html', html], ['style.css', read('style.css')], ['script.js', read('script.js')],
  ]);
  const stale = [];
  for (const [file, content] of files) {
    for (const destination of [file, 'docs/' + file]) {
      if (read(destination).replace(/\r\n/g, '\n') === content.replace(/\r\n/g, '\n')) continue;
      if (check) stale.push(destination);
      else fs.writeFileSync(path.join(root, destination), content, 'utf8');
    }
  }
  if (stale.length) throw new Error('Website is stale: ' + stale.join(', ') + '. Run node tools/build_site.js.');
  process.stdout.write('Website ' + (check ? 'verified' : 'built') + ': v' + catalog.version +
    ', ' + catalog.tools.length + ' tools, ' + groups.length + ' groups; root and docs synchronized.\n');
}

try {
  if (bundleOnly) {
    execFileSync(luajit, ['tools/bundle.lua', '--native', '--check'], {
      cwd: root, stdio: 'inherit', windowsHide: true,
    });
  } else build();
}
catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; }
