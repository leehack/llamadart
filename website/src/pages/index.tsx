import Head from '@docusaurus/Head';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';
import CodeBlock from '@theme/CodeBlock';

type LandingCard = {
  title: string;
  description: string;
  to: string;
  cta: string;
};

const journeyCards: LandingCard[] = [
  {
    title: 'Start in 10 minutes',
    description: 'Install, load a GGUF model, and stream your first response.',
    to: '/docs/getting-started/quickstart',
    cta: 'Open quickstart'
  },
  {
    title: 'Ship chat and tools',
    description: 'Build tool calling, structured chat prompts, and streaming UX.',
    to: '/docs/guides/tool-calling',
    cta: 'Read guides'
  },
  {
    title: 'Tune for production',
    description: 'Choose backends and tune context/runtime parameters.',
    to: '/docs/configuration/runtime-parameters',
    cta: 'Tune runtime'
  },
  {
    title: 'Run OpenAI-style server',
    description: 'Expose local models over HTTP for existing OpenAI clients.',
    to: '/docs/examples/llamadart-server',
    cta: 'See server example'
  }
];

const featureCards: LandingCard[] = [
  {
    title: 'Model lifecycle',
    description: 'Predictable loading/unloading flow and resource cleanup patterns.',
    to: '/docs/guides/model-lifecycle',
    cta: 'Lifecycle guide'
  },
  {
    title: 'Generation and streaming',
    description: 'Token streaming patterns for CLI apps, servers, and Flutter UIs.',
    to: '/docs/guides/generation-and-streaming',
    cta: 'Streaming guide'
  },
  {
    title: 'Multimodal',
    description: 'Image + text prompting with platform-specific constraints.',
    to: '/docs/guides/multimodal',
    cta: 'Multimodal guide'
  },
  {
    title: 'Platform matrix',
    description: 'Understand native/web support boundaries before shipping.',
    to: '/docs/platforms/support-matrix',
    cta: 'Support matrix'
  },
  {
    title: 'Performance tuning',
    description: 'Tune context length, threads, and generation settings safely.',
    to: '/docs/guides/performance-tuning',
    cta: 'Tuning guide'
  },
  {
    title: 'Troubleshooting',
    description: 'Fast fixes for model loading, runtime, and platform issues.',
    to: '/docs/troubleshooting/common-issues',
    cta: 'Debug issues'
  }
];

const maintainerCards: LandingCard[] = [
  {
    title: 'Maintainer overview',
    description: 'Repository ownership map and routine responsibilities.',
    to: '/docs/maintainers/docs-site',
    cta: 'Maintainer docs'
  },
  {
    title: 'Runtime ownership',
    description: 'Where to change native runtime, web bridge, and assets.',
    to: '/docs/maintainers/runtime-ownership',
    cta: 'Ownership boundaries'
  },
  {
    title: 'Release checklist',
    description: 'Versioning, docs cut, and post-release verification sequence.',
    to: '/docs/maintainers/release-workflow',
    cta: 'Release workflow'
  }
];

const siteUrl = 'https://llamadart.leehack.com';
const socialCardUrl = `${siteUrl}/img/social-card.png`;
const homepageSchema = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareSourceCode',
  name: 'llamadart',
  description:
    'Run GGUF and LiteRT-LM models locally from Dart and Flutter across native and web.',
  codeRepository: 'https://github.com/leehack/llamadart',
  license: 'https://github.com/leehack/llamadart/blob/main/LICENSE',
  programmingLanguage: 'Dart',
  runtimePlatform: ['Android', 'iOS', 'macOS', 'Linux', 'Windows', 'Web'],
  image: socialCardUrl,
  url: siteUrl,
  sameAs: [
    'https://github.com/leehack/llamadart',
    'https://pub.dev/packages/llamadart'
  ]
};

export default function Home(): JSX.Element {
  return (
    <Layout
      title="llamadart documentation"
      description="Run GGUF and LiteRT-LM models locally from Dart and Flutter across Android, iOS, macOS, Linux, Windows, and web."
    >
      <Head>
        <meta
          name="keywords"
          content="llamadart, Dart, Flutter, llama.cpp, LiteRT-LM, GGUF, litertlm, local inference, on-device AI"
        />
        <script type="application/ld+json">
          {JSON.stringify(homepageSchema)}
        </script>
      </Head>
      <main className="landingRoot">
        <section className="heroShell">
          <div className="heroLeft">
            <p className="heroKicker">Dart + Flutter local inference runtime</p>
            <h1>Build offline-ready AI features with llamadart</h1>
            <p className="heroLead">
              Documentation for product engineers and maintainers shipping local
              LLM features across Android, iOS, macOS, Linux, Windows, and web.
            </p>
            <div className="heroActions">
              <Link className="button button--primary button--lg" to="/docs/intro">
                Read Documentation
              </Link>
              <Link className="button button--secondary button--lg" to="/api">
                API on pub.dev
              </Link>
              <a
                className="button button--secondary button--lg"
                href="https://leehack-llamadart.static.hf.space"
                target="_blank"
                rel="noreferrer"
              >
                Try Chat App Demo
              </a>
            </div>
            <ul className="heroChecklist">
              <li>Single Dart API across native and browser targets</li>
              <li>GGUF and LiteRT-LM model routing</li>
              <li>OpenAI-compatible local server example included</li>
            </ul>
            <div className="platformChips" aria-label="Supported platforms">
              <span>Android</span>
              <span>iOS</span>
              <span>macOS</span>
              <span>Linux</span>
              <span>Windows</span>
              <span>Web</span>
            </div>
          </div>

          <aside className="heroRight" aria-label="Quick start examples">
            <h2>Quick start examples</h2>
            <CodeBlock language="bash" title="terminal">
{`dart pub add llamadart`}
            </CodeBlock>
            <CodeBlock language="dart" title="minimal generation">
{`import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());

  try {
    await engine.loadModel('path/to/model.gguf');
    await for (final token in engine.generate('Hello from llamadart')) {
      print(token);
    }
  } finally {
    await engine.dispose();
  }
}`}
            </CodeBlock>
            <p className="heroAsideText">
              For OpenAI-compatible HTTP flows, start from{' '}
              <Link to="/docs/examples/llamadart-server">
                <code>llamadart_server</code>
              </Link>
              .
            </p>
          </aside>
        </section>

        <section className="sectionShell" aria-label="Documentation paths">
          <header className="sectionHeader">
            <p className="sectionKicker">Start here</p>
            <h2>Choose a path based on what you are shipping</h2>
          </header>
          <div className="pathGrid">
            {journeyCards.map((card: LandingCard) => (
              <article key={card.title} className="pathCard">
                <h3>{card.title}</h3>
                <p>{card.description}</p>
                <Link to={card.to}>{card.cta}</Link>
              </article>
            ))}
          </div>
        </section>

        <section className="sectionShell" aria-label="Feature guides">
          <header className="sectionHeader">
            <p className="sectionKicker">Core guides</p>
            <h2>Reference docs for real production workflows</h2>
          </header>
          <div className="featureGrid">
            {featureCards.map((card: LandingCard) => (
              <article key={card.title} className="featureCard">
                <h3>{card.title}</h3>
                <p>{card.description}</p>
                <Link to={card.to}>{card.cta}</Link>
              </article>
            ))}
          </div>
        </section>

        <section className="sectionShell maintainerShell" aria-label="Maintainer docs">
          <header className="sectionHeader">
            <p className="sectionKicker">Maintainers</p>
            <h2>llamadart-specific maintenance and release operations</h2>
          </header>
          <div className="maintainerGrid">
            {maintainerCards.map((card: LandingCard) => (
              <article key={card.title} className="maintainerCard">
                <h3>{card.title}</h3>
                <p>{card.description}</p>
                <Link to={card.to}>{card.cta}</Link>
              </article>
            ))}
          </div>
        </section>
      </main>
    </Layout>
  );
}
