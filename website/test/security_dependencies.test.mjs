import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {optimize} from 'svgo';

const lock = JSON.parse(readFileSync(new URL('../package-lock.json', import.meta.url), 'utf8'));

// Issue #519: check nested copies too, so deduplication cannot hide a regression.
for (const [name, minimum] of Object.entries({
  'js-yaml': '4.3.2',
  svgo: '3.3.5',
  colord: '2.9.4',
  joi: '17.13.6',
})) {
  test(`all locked ${name} copies include the security fixes`, () => {
    const copies = Object.entries(lock.packages).filter(([path]) =>
      path.endsWith(`/node_modules/${name}`) || path === `node_modules/${name}`,
    );
    assert.ok(copies.length > 0, `${name} must be present`);
    for (const [path, {version}] of copies) {
      assert.match(version, /^\d+\.\d+\.\d+$/);
      assert.ok(
        version.localeCompare(minimum, 'en', {numeric: true}) >= 0,
        `${path}@${version} is below patched version ${minimum}`,
      );
    }
  });
}

test('SVGO removes executable links while preserving safe SVG content', () => {
  const {data} = optimize(
    '<svg xmlns="http://www.w3.org/2000/svg">' +
      '<a href="data:text/html;base64,PHNjcmlwdD4="><text>unsafe</text></a>' +
      '<a href="https://example.com"><text>safe</text></a>' +
      '<rect width="10" height="20"/></svg>',
    {plugins: ['removeScriptElement']},
  );
  assert.doesNotMatch(data, /data:text\/html/);
  assert.match(data, /href="https:\/\/example.com"/);
  assert.match(data, /<rect width="10" height="20"/);
});
