import {parseLocalURLPath, unwrapMdxCodeBlocks} from '@docusaurus/utils';
import remarkMdx from 'remark-mdx';
import remarkParse from 'remark-parse';
import {unified} from 'unified';

const safePathnameExample = 'pathname:///img/example.png';
const markdownParsers = [
  unified().use(remarkParse).use(remarkMdx),
  unified().use(remarkParse),
];

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
  // Docusaurus applies this compatibility transform immediately after the
  // custom preprocessor and before its real MDX parse. Scan the same content so
  // a fenced mdx-code-block cannot reveal a local image after this guard runs.
  const content = unwrapMdxCodeBlocks(fileContent);
  // The callback does not receive the final format, and front matter can make
  // Docusaurus reinterpret an .md file as plain Markdown after preprocessing.
  // Fail closed by scanning both grammars that its loader can select.
  for (const parser of markdownParsers) {
    const tree = parser.parse(content);
    visitLocalMarkdownImages(tree, (image) => {
      throw new Error(
        `Local Markdown image "${image.url}" in "${filePath}" would use ` +
          'Docusaurus\' unpatched image-size parser. Put the asset under ' +
          '`website/static/` and use an explicit pathname URL such as ' +
          `"${safePathnameExample}".`,
      );
    });
  }
  return fileContent;
}
