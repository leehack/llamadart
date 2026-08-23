import assert from 'node:assert/strict';
import test from 'node:test';

import localMarkdownImageGuard from '../plugins/local_markdown_image_guard.mjs';

function documentWithImage(url) {
  return {
    type: 'root',
    children: [
      {
        type: 'paragraph',
        children: [{type: 'image', url, alt: 'probe'}],
      },
    ],
  };
}

test('rejects untracked local images at the MDX transform boundary', () => {
  const transform = localMarkdownImageGuard();

  for (const url of [
    './untracked.icns',
    '../generated/image.jxl?raw=1#preview',
    '@site/static/img/upload.heic',
    '/img/upload.avif',
  ]) {
    assert.throws(
      () => transform(documentWithImage(url), {path: 'docs/untracked.md'}),
      (error) => {
        assert.match(error.message, /unpatched image-size parser/);
        assert.match(error.message, /pathname:\/\/\/img\/example\.png/);
        assert.match(error.message, /docs\/untracked\.md/);
        return true;
      },
    );
  }
});

test('re-checks fresh MDX input on every hot-reload transform', () => {
  const transform = localMarkdownImageGuard();
  const file = {path: 'docs/live-preview.md'};

  assert.doesNotThrow(() =>
    transform(documentWithImage('https://example.com/initial.png'), file),
  );
  assert.throws(
    () => transform(documentWithImage('./created-after-start.icns'), file),
    /created-after-start\.icns/,
  );
});

test('allows parser-free pathname, remote, data, and HTML images', () => {
  const transform = localMarkdownImageGuard();
  const tree = {
    type: 'root',
    children: [
      documentWithImage('pathname:///img/diagram.png').children[0],
      documentWithImage('https://example.com/diagram.png').children[0],
      documentWithImage('data:image/png;base64,AA==').children[0],
      {
        type: 'mdxJsxFlowElement',
        name: 'img',
        attributes: [{name: 'src', value: '/img/diagram.png'}],
        children: [],
      },
    ],
  };

  assert.doesNotThrow(() => transform(tree, {path: 'docs/safe.md'}));
});
