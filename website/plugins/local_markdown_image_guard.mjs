import {parseLocalURLPath} from '@docusaurus/utils';
import remarkMdx from 'remark-mdx';
import remarkParse from 'remark-parse';
import {unified} from 'unified';

const safePathnameExample = 'pathname:///img/example.png';
const markdownParser = unified().use(remarkParse).use(remarkMdx);

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
 * Prevents every Docusaurus MDX loader from passing local images to image-size.
 *
 * Docusaurus shares this synchronous preprocessor with docs, pages, and its
 * fallback loader for Markdown imported from outside content directories.
 */
export function guardLocalMarkdownImages({fileContent, filePath}) {
  const tree = markdownParser.parse(fileContent);
  visitLocalMarkdownImages(tree, (image) => {
    throw new Error(
      `Local Markdown image "${image.url}" in "${filePath}" would use ` +
        'Docusaurus\' unpatched image-size parser. Put the asset under ' +
        '`website/static/` and use an explicit pathname URL such as ' +
        `"${safePathnameExample}".`,
    );
  });
  return fileContent;
}
