import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {loadSiteConfig} from '@docusaurus/core/lib/server/config.js';

test('version navigation preserves all versions and the stable indexing policy', async () => {
  const siteDir = fileURLToPath(new URL('..', import.meta.url));
  const {siteConfig} = await loadSiteConfig({siteDir});
  const selectors = siteConfig.themeConfig.navbar.items.filter(
    (item) => item.type === 'docsVersionDropdown',
  );
  assert.equal(selectors.length, 1);
  assert.equal(selectors[0].dropdownItemsBefore, undefined);
  assert.equal(selectors[0].dropdownItemsAfter, undefined);
  const [, options] = siteConfig.presets.find(([preset]) => preset === 'classic');
  assert.equal(options.docs.lastVersion, undefined);
  assert.equal(options.docs.onlyIncludeVersions, undefined);
  const versions = JSON.parse(readFileSync(new URL('../versions.json', import.meta.url), 'utf8'));
  assert.ok(versions.length > 1);
  assert.notEqual(options.docs.versions[versions[0]]?.noIndex, true);
  assert.equal(options.docs.versions.current.noIndex, true);
  for (const version of versions.slice(1)) {
    assert.equal(options.docs.versions[version].noIndex, true);
  }
});
