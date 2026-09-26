'use strict';

// The executor saves every downloaded file with a .txt suffix. Node, running
// outside that filesystem API, restores the real names before loading the bridge.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function contained(root, relative) {
  if (typeof relative !== 'string' || !relative || relative.length > 180 ||
      relative.includes('\\') || relative.split('/').some(part =>
        !part || part === '.' || part === '..' || /[<>:"|?*\x00-\x1f]/.test(part) || /[. ]$/.test(part))) {
    throw Error('Invalid bridge package path');
  }
  const target = path.resolve(root, relative);
  if (!target.startsWith(root + path.sep)) throw Error('Bridge package path leaves its folder');
  return target;
}

function noLinks(root, target) {
  let current = root;
  for (const part of ['', ...path.relative(root, target).split(path.sep)]) {
    if (part) current = path.join(current, part);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      throw Error('Bridge package contains a symbolic link; download it into a regular folder');
    }
  }
}

function materialize(manifest, packageDir = __dirname) {
  if (!manifest || !/^[a-f0-9]{40}$/i.test(manifest.revision) ||
      !Array.isArray(manifest.files) || !manifest.files.length || manifest.files.length > 200) {
    throw Error('Invalid bridge installation manifest. Download the bridge again.');
  }
  const base = path.resolve(packageDir), runtime = path.join(base, 'runtime');
  const seen = new Set();
  let total = 0;
  // Verify the complete package before writing any runnable files.
  const files = manifest.files.map(file => {
    if (!file || typeof file.path !== 'string' || !/^[a-f0-9]{40}$/i.test(file.sha || '')) throw Error('Invalid bridge file entry');
    const source = contained(base, file.path + '.txt');
    const target = contained(runtime, file.path);
    noLinks(base, source); noLinks(base, target);
    if ([...seen].some(name => name.toLowerCase() === file.path.toLowerCase()) || !Number.isInteger(file.size) || file.size < 0 || file.size > 20 * 1024 * 1024) throw Error('Invalid bridge file entry');
    seen.add(file.path);
    if (fs.statSync(source).size !== file.size) throw Error('Incomplete bridge package: ' + file.path);
    const bytes = fs.readFileSync(source);
    total += bytes.length;
    if (bytes.length !== file.size || total > 20 * 1024 * 1024) throw Error('Incomplete bridge package: ' + file.path);
    {
      const sha = crypto.createHash('sha1').update('blob ' + bytes.length + '\0').update(bytes).digest('hex');
      if (sha !== file.sha.toLowerCase()) throw Error('Bridge file verification failed: ' + file.path);
    }
    return { target, bytes };
  });
  if (!seen.has('server.js') || !seen.has('web/index.html')) throw Error('Bridge package is missing its server or web page');
  for (const file of files) {
    fs.mkdirSync(path.dirname(file.target), { recursive: true });
    fs.writeFileSync(file.target, file.bytes);
  }
  return path.join(runtime, 'server.js');
}

function launch(manifest) {
  if (Number(process.versions.node.split('.')[0]) < 18) throw Error('Install Node.js 18 or newer, then run this command again.');
  require(materialize(manifest));
}

module.exports = { launch, materialize };
