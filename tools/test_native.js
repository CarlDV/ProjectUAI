'use strict';

// Sequential, fail-fast verification. It never runs during implementation.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const logDir = path.join(root, 'refer', 'native-verification');
fs.mkdirSync(logDir, { recursive: true });
const results = [];
const reportPath = path.join(logDir, 'results.json');
const startedAt = new Date().toISOString();
const luajit = process.env.LUAJIT || 'luajit';
const toolPath = path.join(root, 'refer', 'native-tools', 'luau', process.platform === 'win32' ? 'luau-compile.exe' : 'luau-compile');
const compiler = process.env.LUAU_COMPILE || (fs.existsSync(toolPath) ? toolPath : 'luau-compile');
function report(complete) {
  fs.writeFileSync(reportPath, JSON.stringify({ startedAt, complete, coverage: 'Synthetic behavioral contracts and native syntax; not Roblox renderer or host coverage', results }, null, 2) + '\n');
}
function run(label, command, args) {
  const index = results.length + 1;
  const logFile = String(index).padStart(2, '0') + '-' + label.replace(/[^a-z0-9]+/gi, '-').toLowerCase() + '.log';
  process.stdout.write('RUN ' + label + '\n');
  const start = Date.now();
  const child = spawnSync(command, args, { cwd: root, encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024 });
  const output = (child.stdout || '') + (child.stderr || '') + (child.error ? child.error.message + '\n' : '');
  fs.writeFileSync(path.join(logDir, logFile), output);
  const summaries = output.split(/\r?\n/).filter(line => /\b(checks passed|assertions|scenarios,|failures|tests passed|checks,|parsed \d)\b/i.test(line));
  const result = { label, command, args, exitCode: child.status, seconds: (Date.now() - start) / 1000, log: logFile, summaries };
  results.push(result); report(false);
  if (child.status !== 0) {
    const lines = output.split(/\r?\n/);
    const details = [];
    for (let line = 0; line < lines.length; line++) {
      if (/^\s*FAIL\b|\berror:|stack traceback:|^\s+- /.test(lines[line])) {
        details.push(...lines.slice(line, line + 6).map(value => value.slice(0, 700)));
      }
    }
    process.stderr.write('FAIL ' + label + '\n' + (details.length ? details.join('\n').slice(-16000) : output.slice(-16000)));
    process.stderr.write('\nVerification stopped. Fix implementation, then restart this command from the beginning.\n');
    process.exit(1);
  }
  process.stdout.write('PASS ' + label + ' (' + result.seconds.toFixed(1) + 's)' + (summaries.length ? ': ' + summaries.at(-1) : '') + '\n');
}

report(false);
run('Standalone UI library build and agent reference', process.execPath, ['tools/build_ui_lib.js']);
run('Standalone UI library freshness', process.execPath, ['tools/build_ui_lib.js', '--check']);
run('Native bundle build', luajit, ['tools/bundle.lua', '--native']);
run('Generated native tool catalog', process.execPath, ['tools/build_site.js']);
run('Bundle freshness and deterministic manifest', process.execPath, ['tools/build_site.js', '--bundle-only', '--check']);
run('Generated catalog freshness', process.execPath, ['tools/build_site.js', '--check']);
run('Native static checker', luajit, ['test/check.lua', '--native']);
run('Main native suite', luajit, ['test/run.lua', '--native']);
const helpers = new Set(['run.lua', 'check.lua', 'luau.lua', 'coding_fixture.lua', 'workspace_fixture.lua', 'mobile_snapshots.lua', 'native_performance.lua']);
const outOfScope = new Set(['bridge_install.lua', 'web_runtime.lua']);
const focused = fs.readdirSync(path.join(root, 'test')).filter(file => file.endsWith('.lua') && !helpers.has(file) && !outOfScope.has(file)).sort();
const priority = ['native_improvements.lua', 'native_workspace.lua', 'code_workspace.lua', 'coding_tab.lua', 'coding_layout.lua', 'execution_tools.lua', 'execution_ui.lua', 'chat_loops.lua'];
const rank = file => priority.includes(file) ? priority.indexOf(file) : priority.length;
focused.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b, 'en'));
for (const file of focused) run('Focused ' + file, luajit, ['test/' + file]);
run('Mock harness self-test', luajit, ['test/mock/selftest.lua']);
run('Native performance contracts', luajit, ['test/native_performance.lua']);

const exclusions = new Set(['net/bridge', 'net/bridge_commands', 'net/relay', 'runtime/bridge_install', 'ui/panels/cowork']);
const nativeSources = [];
function collect(directory) {
  for (const entry of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
    const file = directory + '/' + entry.name;
    if (entry.isDirectory()) collect(file);
    else if (file.endsWith('.lua') && !exclusions.has(file.slice(4, -4))) nativeSources.push(file);
  }
}
collect('src'); collect('ui-lib/src'); collect('ui-lib/examples');
nativeSources.sort(); nativeSources.push('init.lua', 'dist/uai.lua', 'dist/uai-ui.lua');
run('Official Luau compiler', compiler, ['--null', ...nativeSources]);
run('Native verification script syntax', process.execPath, ['--check', 'tools/test_native.js']);
run('Native build script syntax', process.execPath, ['--check', 'tools/build_site.js']);
run('UI library build script syntax', process.execPath, ['--check', 'tools/build_ui_lib.js']);
report(true);
process.stdout.write('Native verification passed: ' + results.length + ' stages, ' + focused.length + ' focused suites. Evidence: refer/native-verification/results.json\n');
