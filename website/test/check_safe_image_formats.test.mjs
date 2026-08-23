import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  detectBlockedFormat,
  scanFiles,
} from '../scripts/check_safe_image_formats.mjs';

function isoContainer(brand) {
  return Buffer.concat([
    Buffer.from([0, 0, 0, 24]),
    Buffer.from('ftyp'),
    Buffer.from(brand),
    Buffer.alloc(12),
  ]);
}

function jxlContainer({zeroSizedSignature = false} = {}) {
  return Buffer.concat([
    Buffer.from(zeroSizedSignature ? [0, 0, 0, 0] : [0, 0, 0, 12]),
    Buffer.from('JXL '),
    zeroSizedSignature ? Buffer.alloc(0) : Buffer.from([0x0d, 0x0a, 0x87, 0x0a]),
    isoContainer('jxl '),
  ]);
}

test('detects every image-size parser with an unpatched advisory', () => {
  assert.equal(detectBlockedFormat(Buffer.from('icns payload')), 'ICNS');
  assert.equal(detectBlockedFormat(Buffer.from([0xff, 0x0a, 0, 0])), 'JXL');
  assert.equal(
    detectBlockedFormat(jxlContainer()),
    'JXL',
  );
  assert.equal(
    detectBlockedFormat(jxlContainer({zeroSizedSignature: true})),
    'JXL',
  );

  for (const brand of [
    'avif',
    'mif1',
    'msf1',
    'heic',
    'heix',
    'hevc',
    'hevx',
  ]) {
    assert.equal(detectBlockedFormat(isoContainer(brand)), 'HEIF/AVIF');
  }
});

test('keeps supported docs formats and other ISO containers allowed', () => {
  const allowed = [
    Buffer.from([0x89, 0x50, 0x4e, 0x47]),
    Buffer.from([0xff, 0xd8, 0xff, 0xe0]),
    Buffer.from('GIF89a'),
    Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'),
    isoContainer('isom'),
    isoContainer('mp42'),
    Buffer.alloc(0),
  ];
  for (const header of allowed) {
    assert.equal(detectBlockedFormat(header), null);
  }
});

test('scans by content even when the extension is misleading', (context) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'llamadart-image-check-'));
  context.after(() => rmSync(directory, {recursive: true, force: true}));
  const disguised = path.join(directory, 'safe-looking.png');
  const safe = path.join(directory, 'logo.svg');
  writeFileSync(disguised, Buffer.from('icns payload'));
  writeFileSync(safe, Buffer.from('<svg/>'));

  assert.deepEqual(scanFiles([disguised, safe]), [
    {file: disguised, format: 'ICNS'},
  ]);
});
