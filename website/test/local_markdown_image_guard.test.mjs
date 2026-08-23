import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

import {loadSiteConfig} from '@docusaurus/core/lib/server/config.js';

import {guardLocalMarkdownImages} from '../plugins/local_markdown_image_guard.mjs';

const websiteDirectory = fileURLToPath(new URL('..', import.meta.url));

function preprocess(fileContent, filePath = 'docs/probe.md') {
  return guardLocalMarkdownImages({fileContent, filePath});
}

test('rejects untracked local images at the shared MDX boundary', () => {
  for (const url of [
    './untracked.icns',
    '../generated/image.jxl?raw=1#preview',
    '@site/static/img/upload.heic',
    '/img/upload.avif',
  ]) {
    assert.throws(
      () => preprocess(`![probe](${url})`, 'docs/untracked.md'),
      (error) => {
        assert.match(error.message, /unpatched image-size parser/);
        assert.match(error.message, /pathname:\/\/\/img\/example\.png/);
        assert.match(error.message, /docs\/untracked\.md/);
        return true;
      },
    );
  }
});

test('re-checks fresh MDX input on every hot-reload preprocess', () => {
  assert.doesNotThrow(() =>
    preprocess(
      '![probe](https://example.com/initial.png)',
      'docs/live-preview.md',
    ),
  );
  assert.throws(
    () =>
      preprocess(
        '![probe](./created-after-start.icns)',
        'docs/live-preview.md',
      ),
    /created-after-start\.icns/,
  );
});

test('rejects images revealed by Docusaurus mdx-code-block unwrapping', () => {
  for (const fence of ['```', '````']) {
    const wrappedImage = `${fence}mdx-code-block
![probe](./wrapped-after-preprocess.icns)
${fence}`;

    assert.throws(
      () => preprocess(wrappedImage, 'docs/compatibility.md'),
      /wrapped-after-preprocess\.icns/,
    );
  }
});

test('allows parser-free pathname, remote, data, and HTML images', () => {
  const input = `
![pathname](pathname:///img/diagram.png)
![remote](https://example.com/diagram.png)
![data](data:image/png;base64,AA==)
<img src="/img/diagram.png" />
`;

  assert.equal(preprocess(input, 'docs/safe.mdx'), input);
});

test('validated site config guards external fallback Markdown', async () => {
  const {siteConfig} = await loadSiteConfig({siteDir: websiteDirectory});
  const preprocessor = siteConfig.markdown.preprocessor;
  assert.equal(typeof preprocessor, 'function');

  const externalReadme = path.resolve(websiteDirectory, '..', 'README.md');
  assert.throws(
    () =>
      preprocessor({
        filePath: externalReadme,
        fileContent: '![external](./unsafe-from-fallback.jxl)',
      }),
    (error) => {
      assert.match(error.message, /unsafe-from-fallback\.jxl/);
      assert.match(error.message, /README\.md/);
      return true;
    },
  );
});
