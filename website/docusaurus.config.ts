import { readFileSync } from 'node:fs';

import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import { themes as prismThemes } from 'prism-react-renderer';

const siteUrl = 'https://llamadart.leehack.com';
const socialCardPath = 'img/social-card.png';
const socialCardUrl = `${siteUrl}/${socialCardPath}`;
const analyticsTrackingId = process.env.DOCS_GA_MEASUREMENT_ID?.trim();
const publishedDocVersions = JSON.parse(
  readFileSync(new URL('./versions.json', import.meta.url), 'utf8'),
) as string[];
const archivedDocVersions = publishedDocVersions.slice(1);

const docsVersionOptions: Record<string, { noIndex: boolean }> =
  Object.fromEntries(
    archivedDocVersions.map((version: string) => [version, { noIndex: true }]),
  );

if (publishedDocVersions.length > 0) {
  docsVersionOptions.current = { noIndex: true };
}

const classicPreset: Preset.Options = {
  docs: {
    sidebarPath: './sidebars.ts',
    editUrl: 'https://github.com/leehack/llamadart/tree/main/website/',
    versions: docsVersionOptions,
  },
  blog: false,
  sitemap: {
    changefreq: 'weekly',
    priority: 0.6,
    filename: 'sitemap.xml',
    ignorePatterns: ['/api'],
  },
  theme: {
    customCss: './src/css/custom.css',
  },
};

if (analyticsTrackingId) {
  classicPreset.gtag = {
    trackingID: analyticsTrackingId,
    anonymizeIP: true,
  };
}

const config: Config = {
  title: 'llamadart',
  tagline: 'Run llama.cpp from Dart and Flutter across native and web',
  favicon: 'img/logo.svg',

  url: siteUrl,
  baseUrl: '/',

  organizationName: 'leehack',
  projectName: 'llamadart',

  onBrokenLinks: 'throw',
  trailingSlash: false,
  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'throw'
    }
  },
  themes: ['@docusaurus/theme-mermaid'],

  i18n: {
    defaultLocale: 'en',
    locales: ['en']
  },

  presets: [
    [
      'classic',
      classicPreset,
    ],
  ],

  headTags: [
    {
      tagName: 'script',
      attributes: {
        type: 'application/ld+json',
      },
      innerHTML: JSON.stringify({
        '@context': 'https://schema.org',
        '@graph': [
          {
            '@type': 'Organization',
            '@id': `${siteUrl}/#organization`,
            name: 'llamadart contributors',
            url: siteUrl,
            logo: `${siteUrl}/img/logo.svg`,
            sameAs: [
              'https://github.com/leehack/llamadart',
              'https://pub.dev/packages/llamadart',
            ],
          },
          {
            '@type': 'WebSite',
            '@id': `${siteUrl}/#website`,
            name: 'llamadart documentation',
            url: siteUrl,
            description:
              'Run GGUF and LiteRT-LM models locally from Dart and Flutter across native and web.',
            image: socialCardUrl,
            publisher: {
              '@id': `${siteUrl}/#organization`,
            },
            potentialAction: {
              '@type': 'ReadAction',
              target: `${siteUrl}/docs/intro`,
            },
          },
        ],
      }),
    },
  ],

  themeConfig: {
    image: socialCardPath,
    metadata: [
      {
        name: 'description',
        content:
          'Run GGUF and LiteRT-LM models locally from Dart and Flutter across Android, iOS, macOS, Linux, Windows, and web.',
      },
      {
        name: 'keywords',
        content:
          'llamadart, Dart, Flutter, llama.cpp, LiteRT-LM, GGUF, litertlm, local inference, on-device AI',
      },
      {
        name: 'twitter:card',
        content: 'summary_large_image',
      },
    ],
    colorMode: {
      defaultMode: 'light',
      respectPrefersColorScheme: true
    },
    navbar: {
      title: 'llamadart',
      logo: {
        alt: 'llamadart logo',
        src: 'img/logo.svg'
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs'
        },
        {
          to: '/api',
          label: 'API',
          position: 'left'
        },
        {
          href: 'https://pub.dev/packages/llamadart',
          label: 'pub.dev',
          position: 'right'
        },
        {
          href: 'https://github.com/leehack/llamadart',
          label: 'GitHub',
          position: 'right'
        }
      ]
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Introduction',
              to: '/docs/intro'
            },
            {
              label: 'Quickstart',
              to: '/docs/getting-started/quickstart'
            },
            {
              label: 'API Reference',
              to: '/api'
            }
          ]
        },
        {
          title: 'Community',
          items: [
            {
              label: 'Issues',
              href: 'https://github.com/leehack/llamadart/issues'
            }
          ]
        },
        {
          title: 'More',
          items: [
            {
              label: 'Repository',
              href: 'https://github.com/leehack/llamadart'
            },
            {
              label: 'License',
              href: 'https://github.com/leehack/llamadart/blob/main/LICENSE'
            }
          ]
        }
      ],
      copyright: `Copyright © ${new Date().getFullYear()} llamadart contributors.`
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['dart', 'yaml', 'bash', 'json', 'diff']
    }
  } satisfies Preset.ThemeConfig
};

export default config;
