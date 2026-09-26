'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { materialize } = require('../launcher');
const sha = bytes => crypto.createHash('sha1').update('blob ' + bytes.length + '\0').update(bytes).digest('hex');

function fixture(t, extras = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-bridge-package-'));
  t.after(() => {
    assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep));
    fs.rmSync(root, { recursive: true, force: true });
  });
  const entries = { 'server.js': "require('node:fs').writeFileSync(require('node:path').join(__dirname,'started.txt'),'started');",
    'web/index.html': '<html>Bridge</html>', 'web/icon.png': Buffer.from([0, 128, 255, 13, 10]), ...extras };
  const files = Object.entries(entries).map(([name, value]) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value), target = path.join(root, name + '.txt');
    fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
    return { path: name, size: bytes.length, sha: sha(bytes) };
  });
  return { root, manifest: { revision: 'a'.repeat(40), files }, entries };
}

test('a .txt launcher restores executable and binary files without renaming in the executor', t => {
  const { root, manifest } = fixture(t);
  fs.copyFileSync(path.join(__dirname, '../launcher.js'), path.join(root, 'launcher.js.txt'));
  const entry = path.join(root, 'start.txt');
  fs.writeFileSync(entry, "require('./launcher.js.txt').launch(" + JSON.stringify(manifest) + ');');
  const result = spawnSync(process.execPath, [entry], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(root, 'runtime/started.txt'), 'utf8'), 'started');
  assert.deepEqual(fs.readFileSync(path.join(root, 'runtime/web/icon.png')), Buffer.from([0, 128, 255, 13, 10]));
});

test('all hashes and sizes are verified before any runnable file is changed', t => {
  const { root, manifest } = fixture(t);
  materialize(manifest, root);
  fs.writeFileSync(path.join(root, 'runtime/server.js'), 'old working version');
  fs.writeFileSync(path.join(root, 'web/icon.png.txt'), Buffer.from([0, 128, 254, 13, 10]));
  assert.throws(() => materialize(manifest, root), /verification failed/);
  assert.equal(fs.readFileSync(path.join(root, 'runtime/server.js'), 'utf8'), 'old working version');
  fs.writeFileSync(path.join(root, 'web/icon.png.txt'), 'truncated');
  assert.throws(() => materialize(manifest, root), /Incomplete/);
});

test('missing files, duplicate names, unsafe paths and invalid manifests are rejected', t => {
  const { root, manifest } = fixture(t);
  for (const name of ['../escape.js', '/absolute.js', 'web/../../escape.js', 'web\\escape.js', 'web/name:stream', 'web/name.']) {
    assert.throws(() => materialize({ ...manifest, files: [...manifest.files, { path: name, size: 1, sha: 'a'.repeat(40) }] }, root), /path|entry/);
  }
  assert.throws(() => materialize({ ...manifest, files: [...manifest.files, manifest.files[0]] }, root), /entry/);
  assert.throws(() => materialize({ ...manifest, revision: 'main' }, root), /manifest/);
  assert.throws(() => materialize({ ...manifest, files: manifest.files.filter(f => f.path !== 'server.js') }, root), /missing/);
  fs.unlinkSync(path.join(root, 'server.js.txt'));
  assert.throws(() => materialize(manifest, root), /ENOENT/);
});

test('a junction cannot redirect extracted files outside the package', t => {
  const { root, manifest } = fixture(t);
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'uai-bridge-outside-'));
  t.after(() => { assert.ok(path.resolve(outside).startsWith(path.resolve(os.tmpdir()) + path.sep)); fs.rmSync(outside, { recursive: true, force: true }); });
  fs.symlinkSync(outside, path.join(root, 'runtime'), process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => materialize(manifest, root), /symbolic link/);
  assert.deepEqual(fs.readdirSync(outside), []);
});
