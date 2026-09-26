#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { root } = require('./helpers/bridge');
const args = process.argv.slice(2);
if (process.env.UAI_SCREENSHOTS) fs.mkdirSync(process.env.UAI_SCREENSHOTS, { recursive: true });
function run(files, test = false) {
  const result = spawnSync(process.execPath, [...(test ? ['--test'] : []), ...files], { cwd: root, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
if (!args.includes('--browser-only')) run(fs.readdirSync(__dirname).filter(name => name.endsWith('.test.js')).sort().map(name => path.join(__dirname, name)), true);
if (args.includes('--browser') || args.includes('--browser-only')) {
  for (const name of ['browser.js', 'browser-workflows.js', 'browser-revamp.js', 'browser-ui-audit.js']) run([path.join(__dirname, name)]);
}
