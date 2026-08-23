# llamadart docs site

This directory contains the Docusaurus site for `llamadart`.

## Local development

Use Node.js 20.x. The docs CI pins Node 20, and newer major versions can expose
toolchain incompatibilities before Docusaurus and its plugins declare support.

```bash
cd website
npm ci
npm run start
```

## Build and verify (repo root)

```bash
./tool/docs/build_site.sh
./tool/docs/validate_links.sh
```

The build rejects ICNS, JXL, HEIF, and AVIF content because the Docusaurus
image-dimension dependency has no patched release for its infinite-loop
parsers. Convert those images to PNG, JPEG, WebP, or SVG before committing
them. Detection uses file content rather than extensions.

## API docs

The docs site links API references to pub.dev:

- https://pub.dev/documentation/llamadart/latest/

## Versioning

Create a docs snapshot manually:

```bash
cd website
npm ci
npm run docusaurus docs:version <version>
```

Automated version cuts also run on `v*` release tags via repository workflows.
