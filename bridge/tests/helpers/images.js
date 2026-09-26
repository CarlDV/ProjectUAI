'use strict';
const zlib = require('node:zlib');
const samples = require('../fixtures/images.json');
const PNG_SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const chunk = Buffer.alloc(data.length + 12);
  chunk.writeUInt32BE(data.length); chunk.write(type, 4, 'ascii'); data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(chunk.subarray(4, -4)), chunk.length - 4);
  return chunk;
}
function makePng(width, height) {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  const pixels = Buffer.alloc(height * (1 + width * 4));
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const at = y * (1 + width * 4) + 1 + x * 4;
    pixels[at] = 187; pixels[at + 1] = 108 + y % 60; pixels[at + 2] = 68 + x % 50; pixels[at + 3] = 255;
  }
  return Buffer.concat([PNG_SIG, pngChunk('IHDR', ihdr), pngChunk('IDAT', zlib.deflateSync(pixels)), pngChunk('IEND', Buffer.alloc(0))]);
}
function sample(format, width, height) {
  const data = samples[format + '-' + width + 'x' + height];
  if (!data) throw Error('Missing image fixture ' + format + ' ' + width + 'x' + height);
  return Buffer.from(data, 'base64');
}
const makeJpeg = (w, h) => sample('jpeg', w, h);
const makeWebp = (w, h) => sample('webp', w, h);
function makeAnimatedWebp() {
  const bytes = Buffer.alloc(30); bytes.write('RIFF'); bytes.writeUInt32LE(22, 4); bytes.write('WEBP', 8);
  bytes.write('VP8X', 12); bytes.writeUInt32LE(10, 16); bytes[20] = 2;
  return bytes;
}
module.exports = { makePng, makeJpeg, makeWebp, makeAnimatedWebp, pngChunk, PNG_SIG };
