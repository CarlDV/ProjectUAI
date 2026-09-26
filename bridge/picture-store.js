'use strict';

const crypto = require('node:crypto');

// Bounded, in-memory picture registry. Bytes are staged here only for browser
// preview/replay and are never written to disk or the served web tree; a bridge
// restart intentionally invalidates every staged picture. Nothing here ever
// crosses the Roblox boundary -- only a text marker does.

const DEFAULT_LIMITS = {
  pictureBytes: 5 * 1024 * 1024,
  picturesPerSend: 8,
  pictureTotalBytes: 20 * 1024 * 1024,
  pictureTtlMs: 15 * 60 * 1000,
};
const MEDIA_TYPES = ['image/png', 'image/jpeg', 'image/webp'];
const MAX_WIDTH = 4096;
const MAX_HEIGHT = 4096;
const MAX_PIXELS = 12000000;
const MAX_RECORDS = 512; // global guard against many-tiny-file flooding beneath the byte cap
const STATUSES = ['staged', 'queued', 'acked', 'failed', 'expired'];

// Typed error. `code` is the stable machine bucket callers/tests match on; `status`
// is the HTTP status the server maps the same failure to. Both ride one Error.
const CODE_STATUS = { invalid: 400, unsupported: 415, too_large: 413, too_many: 429, conflict: 409, dimensions: 413, expired: 410 };
function fail(code, message, status) {
  const err = new Error(message);
  err.code = code;
  err.status = status || CODE_STATUS[code] || 400;
  return err;
}

function positive(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

// Filenames are display-only. Strip control characters and any path separators
// so a name can never be used to address the filesystem.
function sanitizeName(name) {
  const clean = String(name || '').replace(/[\u0000-\u001f\u007f]/g, '').replace(/[\\/]/g, '_').trim().slice(0, 200);
  return clean || 'picture';
}

// --- container sniffing + bounded dimension parsing -----------------------

function parsePng(buf) {
  if (buf.length < 33 || buf.readUInt32BE(8) !== 13 || buf.toString('latin1', 12, 16) !== 'IHDR') return null;
  const dims = { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
  let at = 8, image = false, ended = false, count = 0;
  while (at + 12 <= buf.length && ++count <= 4096) {
    const size = buf.readUInt32BE(at), end = at + 12 + size;
    const type = buf.toString('latin1', at + 4, at + 8);
    if (end > buf.length || !/^[A-Za-z]{4}$/.test(type)) return null;
    if (crc32(buf.subarray(at + 4, end - 4)) !== buf.readUInt32BE(end - 4)) return null;
    if (type === 'IHDR' && at !== 8) return null;
    if (type === 'acTL' || type === 'fcTL' || type === 'fdAT') throw fail('unsupported', 'Animated PNG is not accepted');
    if (type === 'IDAT' && size > 0) image = true;
    if (type === 'IEND') { ended = size === 0 && end === buf.length; break; }
    at = end;
  }
  return image && ended ? dims : null;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  for (let bit = 0; bit < 8; bit++) n = (n >>> 1) ^ (0xedb88320 & -(n & 1));
  return n >>> 0;
});
function crc32(buf) {
  let crc = 0xffffffff;
  for (const byte of buf) crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 255];
  return (crc ^ 0xffffffff) >>> 0;
}

function parseJpeg(buf) {
  let at = 2, dims, scan = false, segments = 0;
  while (at < buf.length && ++segments <= 65536) {
    if (buf[at++] !== 0xff) return null;
    while (buf[at] === 0xff) at++;
    const marker = buf[at++];
    if (marker === 0xd9) return scan && at === buf.length ? dims : null;
    if (marker === 0xd8 || at + 2 > buf.length) return null;
    const size = buf.readUInt16BE(at);
    if (size < 2 || at + size > buf.length) return null;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (size < 8 || size !== 8 + 3 * buf[at + 7] || !buf[at + 7]) return null;
      dims = { height: buf.readUInt16BE(at + 3), width: buf.readUInt16BE(at + 5) };
    }
    at += size;
    if (marker === 0xda) {
      scan = true;
      while (at < buf.length) {
        if (buf[at] !== 0xff) { at++; continue; }
        if (buf[at + 1] === 0 || (buf[at + 1] >= 0xd0 && buf[at + 1] <= 0xd7)) { at += 2; continue; }
        break;
      }
    }
  }
  return null;
}

// Returns { width, height } or throws for animated/invalid WebP.
function parseWebp(buf) {
  if (buf.length < 26 || buf.readUInt32LE(4) + 8 !== buf.length) return null;
  let at = 12, dims, canvas, count = 0;
  while (at + 8 <= buf.length && ++count <= 4096) {
    const fourcc = buf.toString('latin1', at, at + 4), size = buf.readUInt32LE(at + 4), start = at + 8;
    if (start + size > buf.length) return null;
    if (fourcc === 'ANIM' || fourcc === 'ANMF') throw fail('unsupported', 'Animated WebP is not accepted');
    if (fourcc === 'VP8X') {
      if (at !== 12 || size !== 10) return null;
      if (buf[start] & 0x02) throw fail('unsupported', 'Animated WebP is not accepted');
      canvas = { width: 1 + buf.readUIntLE(start + 4, 3), height: 1 + buf.readUIntLE(start + 7, 3) };
    } else if (fourcc === 'VP8 ' || fourcc === 'VP8L') {
      if (dims) return null;
      if (fourcc === 'VP8 ') {
        if (size < 10 || buf[start] & 1 || buf.toString('hex', start + 3, start + 6) !== '9d012a') return null;
        dims = { width: buf.readUInt16LE(start + 6) & 0x3fff, height: buf.readUInt16LE(start + 8) & 0x3fff };
      } else {
        if (size < 5 || buf[start] !== 0x2f) return null;
        const bits = buf.readUInt32LE(start + 1);
        dims = { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
      }
    }
    at = start + size + (size & 1);
  }
  if (at !== buf.length || !dims || (canvas && (canvas.width !== dims.width || canvas.height !== dims.height))) return null;
  return dims;
}

// Sniff the true container from magic bytes and return {mediaType, width, height}.
// Rejects SVG/HTML/other and animated WebP; never trusts the declared type.
function inspect(buf) {
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47 && buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a) {
    const dims = parsePng(buf);
    if (!dims) throw fail('dimensions', 'Unreadable PNG header; cannot determine dimensions', 400);
    return { mediaType: 'image/png', ...dims };
  }
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    const dims = parseJpeg(buf);
    if (!dims) throw fail('dimensions', 'Unreadable JPEG header; cannot determine dimensions', 400);
    return { mediaType: 'image/jpeg', ...dims };
  }
  if (buf.length >= 12 && buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP') {
    const dims = parseWebp(buf); // may throw for animated
    if (!dims) throw fail('dimensions', 'Unreadable WebP header; cannot determine dimensions', 400);
    return { mediaType: 'image/webp', ...dims };
  }
  throw fail('unsupported', 'Unsupported or unrecognized image container', 415);
}

// Spec constructor takes flat limit params. A nested { limits } object is also
// accepted (the current server passes one) and is merged first, so flat params
// win when both are present.
function createPictureStore(options = {}) {
  const cfg = { ...(options && options.limits), ...options };
  const pictureBytes = positive(cfg.pictureBytes, DEFAULT_LIMITS.pictureBytes);
  const picturesPerSend = positive(cfg.picturesPerSend, DEFAULT_LIMITS.picturesPerSend);
  const pictureTotalBytes = positive(cfg.pictureTotalBytes, DEFAULT_LIMITS.pictureTotalBytes);
  const pictureTtlMs = positive(cfg.pictureTtlMs, DEFAULT_LIMITS.pictureTtlMs);
  const maxWidth = positive(cfg.maxWidth, MAX_WIDTH);
  const maxHeight = positive(cfg.maxHeight, MAX_HEIGHT);
  const maxPixels = positive(cfg.maxPixels, MAX_PIXELS);
  const graceMs = pictureTtlMs; // tombstone window after idle expiry before full eviction

  const records = new Map();

  const publicMeta = r => ({ id: r.id, browserId: r.browserId, sessionId: r.sessionId, name: r.name, mediaType: r.mediaType,
    bytes: r.bytes, sha256: r.sha256, width: r.width, height: r.height, status: r.status,
    createdAt: r.createdAt, expiresAt: r.expiresAt, commandId: r.commandId });
  const fullMeta = r => ({ ...publicMeta(r), commandId: r.commandId });

  // Idle TTL: expired once untouched for longer than the TTL, or once explicitly
  // tombstoned by sweep()/markStatus('expired').
  function expired(r, now = Date.now()) { return r.status === 'expired' || now - r.lastAccess > pictureTtlMs; }

  function totalBytes(now) {
    let sum = 0;
    for (const r of records.values()) if (!expired(r, now)) sum += r.bytes;
    return sum;
  }
  function ownerCount(browserId, sessionId, now) {
    let n = 0;
    for (const r of records.values()) if (!expired(r, now) && r.status !== 'acked' && r.browserId === browserId && r.sessionId === sessionId) n += 1;
    return n;
  }

  // Free bytes but keep a light metadata stub so get() can still report
  // {expired:true} rather than an indistinguishable {null} unknown.
  function tombstone(r, now) { r.status = 'expired'; r.expiredAt = now; r.data = null; }

  function policy() {
    return { limits: { pictureBytes, picturesPerSend, pictureTotalBytes, pictureTtlMs },
      mediaTypes: MEDIA_TYPES.slice(), maxWidth, maxHeight, maxPixels };
  }

  function stage({ id, browserId, sessionId, name, declaredType, mediaType, bytes } = {}) {
    if (typeof id !== 'string' || !/^pic_[\w-]{8,64}$/.test(id)) throw fail('invalid', 'Invalid picture ID');
    if (typeof browserId !== 'string' || !/^[\w-]{1,100}$/.test(browserId)) throw fail('invalid', 'Missing or invalid browser ID');
    if (typeof sessionId !== 'string' || !/^[\w-]{1,100}$/.test(sessionId)) throw fail('invalid', 'Missing or invalid session ID');
    if (!Buffer.isBuffer(bytes) || !bytes.length) throw fail('invalid', 'Empty picture body');
    if (bytes.length > pictureBytes) throw fail('too_large', 'Picture exceeds the per-picture byte limit');

    const info = inspect(bytes); // throws typed errors for bad/animated/unsupported containers
    const declared = declaredType != null ? declaredType : mediaType;
    if (declared && String(declared).toLowerCase().trim() !== info.mediaType) throw fail('unsupported', 'Declared media type does not match the image bytes');
    const extension = String(name || '').match(/\.([^.]+)$/)?.[1]?.toLowerCase();
    if (extension && !({ 'image/png': ['png'], 'image/jpeg': ['jpg', 'jpeg'], 'image/webp': ['webp'] })[info.mediaType].includes(extension)) {
      throw fail('unsupported', 'Filename extension does not match the image bytes');
    }
    if (!info.width || !info.height) throw fail('dimensions', 'Could not determine image dimensions', 400);
    if (info.width > maxWidth || info.height > maxHeight) throw fail('dimensions', 'Picture exceeds the maximum dimensions');
    if (info.width * info.height > maxPixels) throw fail('dimensions', 'Picture exceeds the maximum pixel count');

    const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
    const now = Date.now();
    const existing = records.get(id);
    if (existing && (existing.browserId !== browserId || existing.sessionId !== sessionId)) throw fail('conflict', 'Picture ID belongs to another owner');
    if (existing && expired(existing, now)) throw fail('expired', 'Picture expired; attach it again');
    if (existing && !expired(existing, now)) {
      // Idempotent re-upload only when the same bytes arrive under the same owner.
      if (existing.sha256 !== sha256 || existing.bytes !== bytes.length) throw fail('conflict', 'Picture ID already staged with different content');
      if (existing.browserId !== browserId || existing.sessionId !== sessionId) throw fail('conflict', 'Picture ID belongs to another owner');
      existing.lastAccess = now;
      existing.expiresAt = now + pictureTtlMs;
      if (existing.status === 'failed') { existing.status = 'staged'; existing.commandId = null; existing.discard = false; }
      return publicMeta(existing);
    }

    sweep();
    if (ownerCount(browserId, sessionId, now) >= picturesPerSend) throw fail('too_many', 'Too many staged pictures for this session; remove some first');
    if (totalBytes(now) + bytes.length > pictureTotalBytes) throw fail('too_many', 'Total staged picture bytes exceeded; remove some pictures');
    if (records.size >= MAX_RECORDS) throw fail('too_many', 'Too many staged pictures; remove some first');

    const record = { id, browserId, sessionId, name: sanitizeName(name), mediaType: info.mediaType,
      bytes: bytes.length, sha256, width: info.width, height: info.height, status: 'staged',
      createdAt: now, lastAccess: now, expiresAt: now + pictureTtlMs, commandId: null, data: bytes, expiredAt: null };
    records.set(id, record);
    return publicMeta(record);
  }

  // Returns { meta, bytes } for the authenticated owner, { expired:true } once the
  // TTL/eviction has passed for an owned record, or null for unknown id / wrong
  // owner (indistinguishable on purpose so ownership cannot be probed).
  function get(id, { browserId, sessionId } = {}) {
    const r = records.get(id);
    if (!r) return null;
    if (r.browserId !== browserId || r.sessionId !== sessionId) return null;
    if (expired(r)) return { expired: true };
    r.lastAccess = Date.now();
    r.expiresAt = r.lastAccess + pictureTtlMs;
    return { meta: fullMeta(r), bytes: r.data };
  }

  function remove(id, owner) {
    const r = records.get(id);
    if (!r) return false;
    if (owner && (r.browserId !== owner.browserId || r.sessionId !== owner.sessionId)) return false;
    // A queued/acked picture backs an in-flight or delivered command; mark it for
    // cleanup rather than yanking it out from under the command.
    if (r.status === 'queued') { r.discard = true; return true; }
    records.delete(id);
    return true;
  }

  function markQueued(ids, commandId) {
    for (const id of Array.isArray(ids) ? ids : (ids ? [ids] : [])) {
      const r = records.get(id);
      if (r && !expired(r)) { r.status = 'queued'; r.commandId = commandId; }
    }
  }

  function markStatus(id, status) {
    if (!STATUSES.includes(status)) return;
    const r = records.get(id);
    if (!r) return;
    if (status === 'expired') { tombstone(r, Date.now()); return; }
    if (!expired(r)) {
      r.status = status;
      if ((status === 'acked' || status === 'failed') && r.discard) records.delete(id);
    }
  }

  function catalog(sessionId) {
    const now = Date.now();
    const out = [];
    for (const r of records.values()) {
      if (r.sessionId !== sessionId || expired(r, now)) continue;
      out.push(fullMeta(r));
      if (out.length >= picturesPerSend * 4) break;
    }
    return out;
  }

  // Called from a server interval. First pass tombstones idle-expired records
  // (frees their bytes); second pass drops the stub after a grace window.
  function sweep() {
    const now = Date.now();
    for (const [id, r] of records) {
      if (r.status !== 'expired' && now - r.lastAccess > pictureTtlMs) tombstone(r, now);
      if (r.status === 'expired' && r.expiredAt != null && now - r.expiredAt > graceMs) records.delete(id);
    }
  }

  // No timer is started here (the server drives sweep()); close() just drops all
  // staged bytes for an explicit shutdown/reset.
  function close() { records.clear(); }

  function clearSession(sessionId) {
    for (const [id, record] of records) if (record.sessionId === sessionId) records.delete(id);
  }

  return { policy, stage, get, remove, markQueued, markStatus, catalog, sweep, cleanup: sweep, clearSession, close };
}

module.exports = { createPictureStore, DEFAULT_LIMITS, MEDIA_TYPES, MAX_WIDTH, MAX_HEIGHT, MAX_PIXELS };
