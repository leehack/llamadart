import {parseLocalURLPath} from '@docusaurus/utils';

const safePathnameExample = 'pathname:///img/example.png';

function visitLocalMarkdownImages(node, callback) {
  if (!node || typeof node !== 'object') {
    return;
  }
  if (node.type === 'image' && typeof node.url === 'string') {
    if (parseLocalURLPath(node.url) !== null) {
      callback(node);
    }
  }
  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      visitLocalMarkdownImages(child, callback);
    }
  }
}

/**
 * Prevents Docusaurus from passing local Markdown images to image-size.
 *
 * image-size@2.0.2 is the latest published release and has unpatched
 * infinite-loop parsers. This plugin runs before Docusaurus' built-in image
 * transform on every MDX compilation, including development hot reloads.
 */
export default function localMarkdownImageGuard() {
  return (tree, file) => {
    visitLocalMarkdownImages(tree, (image) => {
      const source = file?.path ?? '<unknown Markdown file>';
      throw new Error(
        `Local Markdown image "${image.url}" in "${source}" would use ` +
          'Docusaurus\' unpatched image-size parser. Put the asset under ' +
          '`website/static/` and use an explicit pathname URL such as ' +
          `"${safePathnameExample}".`,
      );
    });
  };
}
