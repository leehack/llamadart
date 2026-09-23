import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/decision_cli_options.dart';
import 'package:test/test.dart';

DecisionCliOptions _parse(List<String> arguments) =>
    parseDecisionCliOptions(createDecisionArgParser().parse(arguments));

void main() {
  group('parseDecisionCliOptions', () {
    test('defaults to the pinned Hugging Face backbone and head', () {
      final options = _parse(const []);

      for (final (source, file) in [
        (options.modelSource, 'laya-Q8_0.gguf'),
        (options.headSource, 'laya-head.safetensors'),
      ]) {
        final pinned = ModelSource.huggingFace(
          repoId: 'fr0stbit3/laya-gguf',
          revision: 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c',
          filePath: file,
        );
        expect(source.canonicalKey, pinned.canonicalKey);
      }
      expect(options.configSource, isNull);
      expect(options.state, isNull);
      expect(options.forceCpu, isFalse);
      expect(options.threads, 0);
      expect(options.printJson, isFalse);
    });

    test('reads every option', () {
      final options = _parse(const [
        '-m',
        '/models/laya-F16.gguf',
        '--head',
        '/models/model.safetensors',
        '--config',
        '/models/rl_agent_config.json',
        '--cpu',
        '--threads',
        '8',
        '--json',
      ]);

      expect(options.modelSource.path, '/models/laya-F16.gguf');
      expect(options.headSource.path, '/models/model.safetensors');
      expect(options.configSource?.path, '/models/rl_agent_config.json');
      expect(options.forceCpu, isTrue);
      expect(options.threads, 8);
      expect(options.printJson, isTrue);
    });

    test('decodes a JSON object or array state', () {
      expect(_parse(const ['-s', '{"body": "Refund me", "tier": 2}']).state, {
        'body': 'Refund me',
        'tier': 2,
      });
      expect(_parse(const ['--state', '["a", 1]']).state, ['a', 1]);
    });

    test('keeps any other state as text', () {
      for (final text in const [
        'Billed twice for March.',
        '[URGENT] checkout is down',
        '42',
        '"quoted"',
        '',
      ]) {
        expect(_parse(['--state', text]).state, text);
      }
    });

    test('rejects an empty or unsupported source for each file option', () {
      for (final option in const ['--model', '--head', '--config']) {
        for (final (source, reason) in const [
          ('', 'must not be empty'),
          ('ftp://host/laya.gguf', 'Unsupported model source scheme: ftp'),
        ]) {
          expect(
            () => _parse([option, source]),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                allOf(startsWith('$option: '), contains(reason)),
              ),
            ),
          );
        }
      }
    });

    test('rejects a negative or non-integer thread count', () {
      for (final threads in const ['-1', 'four', '1.5']) {
        expect(
          () => _parse(['--threads', threads]),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('--threads'),
            ),
          ),
        );
      }
    });
  });

  group('modelParams', () {
    test('uses a 512-token context on the default GPU backend', () {
      final params = _parse(const []).modelParams;

      expect(params.contextSize, 512);
      expect(params.preferredBackend, GpuBackend.auto);
      expect(params.gpuLayers, ModelParams.maxGpuLayers);
      expect(params.numberOfThreadsBatch, 0);
    });

    test('maps --cpu and --threads to the CPU backend and batch threads', () {
      final params = _parse(const ['--cpu', '--threads', '6']).modelParams;

      expect(params.contextSize, 512);
      expect(params.preferredBackend, GpuBackend.cpu);
      expect(params.gpuLayers, 0);
      expect(params.numberOfThreadsBatch, 6);
      expect(params.numberOfThreads, 0);
    });
  });

  test('buildDecisionHelpText shows usage and examples', () {
    final parser = createDecisionArgParser();

    final text = buildDecisionHelpText(parser);

    expect(text, startsWith('llamadart Decision Example\n'));
    expect(text, contains(parser.usage));
    expect(text, contains('Examples:'));
  });
}
