import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const blockedHeifBrands = new Set([
  'avif',
  'mif1',
  'msf1',
  'heic',
  'heix',
  'hevc',
  'hevx',
]);
// Match image-size/fromFile's read window so the gate sees every byte that
// Docusaurus can pass to a vulnerable parser.
const maxInputSize = 512 * 1024;

function findBoxBrand(input, name) {
  let offset = 0;
  while (offset + 12 <= input.length) {
    const size = input.readUInt32BE(offset);
    const boxName = input.subarray(offset + 4, offset + 8).toString('ascii');
    if (boxName === name) {
      return input.subarray(offset + 8, offset + 12).toString('ascii');
    }
    offset += size > 0 ? size : 8;
  }
  return null;
}

/**
 * Returns the vulnerable image-size parser selected by the file header.
 *
 * GHSA-w3rx-r6r6-pgpr affects ICNS. GHSA-5p2g-fcmc-qvqq affects JXL and
 * HEIF. image-size@2.0.2 is the final published version and has no patched
 * replacement, so the docs build rejects content that can reach those
 * parsers before Docusaurus loads it.
 */
export function detectBlockedFormat(header) {
  if (header.subarray(0, 4).toString('ascii') === 'icns') {
    return 'ICNS';
  }
  if (header[0] === 0xff && header[1] === 0x0a) {
    return 'JXL';
  }

  const boxType = header.subarray(4, 8).toString('ascii');
  if (boxType === 'JXL ' && findBoxBrand(header, 'ftyp') === 'jxl ') {
    return 'JXL';
  }
  const brand = header.subarray(8, 12).toString('ascii');
  if (boxType === 'ftyp' && blockedHeifBrands.has(brand)) {
    return 'HEIF/AVIF';
  }
  return null;
}

export function scanFiles(files) {
  const findings = [];
  for (const file of files) {
    let header;
    try {
      header = readFileSync(file).subarray(0, maxInputSize);
    } catch (error) {
      if (error?.code === 'EISDIR' || error?.code === 'ENOENT') {
        continue;
      }
      throw error;
    }

    const format = detectBlockedFormat(header);
    if (format !== null) {
      findings.push({file, format});
    }
  }
  return findings;
}

function trackedWebsiteFiles(repoRoot) {
  const output = execFileSync(
    'git',
    ['ls-files', '-z', '--', 'website'],
    {cwd: repoRoot},
  );
  return output
    .toString()
    .split('\0')
    .filter(Boolean)
    .map((file) => path.join(repoRoot, file));
}

export function runCheck(repoRoot) {
  const files = trackedWebsiteFiles(repoRoot);
  const findings = scanFiles(files);
  if (findings.length === 0) {
    console.log(
      `[docs] Safe image formats: checked ${files.length} tracked website files.`,
    );
    return 0;
  }

  for (const {file, format} of findings) {
    const relativePath = path.relative(repoRoot, file);
    console.error(
      `${relativePath}: ${format} content reaches an unpatched image-size ` +
        'infinite-loop parser. Convert it to PNG, JPEG, WebP, or SVG.',
    );
  }
  return 1;
}

const scriptPath = fileURLToPath(import.meta.url);
if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  const repoRoot = path.resolve(path.dirname(scriptPath), '..', '..');
  process.exitCode = runCheck(repoRoot);
}
