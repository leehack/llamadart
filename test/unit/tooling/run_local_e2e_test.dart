@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/run_local_e2e.dart';

void main() {
  group('run_local_e2e', () {
    test('lists local-only Dart, Flutter, and Web smoke scenarios', () async {
      final result = await runLocalE2e(const ['--list'], projectRoot: '/repo');

      expect(result.exitCode, 0);
      expect(result.stdout, contains('root-template-e2e'));
      expect(result.stdout, contains('root-native-tool-e2e'));
      expect(result.stdout, contains('qwen35-multimodal-macos-repro'));
      expect(result.stdout, contains('webgpu-multimodal-regression'));
      expect(result.stdout, contains('chat-app-model-cache'));
      expect(result.stdout, contains('chat-app-web-real-model-smoke'));
      expect(result.stdout, contains('chat-app-web-litert-gemma4-smoke'));
      expect(result.stdout, contains('bridge-smoke'));
      expect(result.stdout, contains('Dart local-only'));
      expect(result.stdout, contains('Flutter device'));
      expect(result.stdout, contains('Web smoke'));
    });

    test(
      'dry-runs a Flutter device scenario with the requested device',
      () async {
        final result = await runLocalE2e(const [
          '--scenario',
          'chat-app-model-cache',
          '--device',
          'macos',
          '--dry-run',
        ], projectRoot: '/repo');

        expect(result.exitCode, 0);
        expect(result.stdout, contains('chat-app-model-cache'));
        expect(
          result.stdout,
          contains(
            'cd /repo/example/chat_app && flutter test --run-skipped '
            '-t local-only integration_test/model_cache_mmproj_e2e_test.dart '
            '-d macos',
          ),
        );
      },
    );

    test(
      'dry-runs Web real-model smoke with build, serve, and Playwright steps',
      () async {
        final result = await runLocalE2e(const [
          '--scenario',
          'chat-app-web-real-model-smoke',
          '--model-url',
          'http://127.0.0.1:7358/models/tiny.gguf',
          '--expect',
          'ok',
          '--python',
          '/custom/python',
          '--dry-run',
        ], projectRoot: '/repo');

        expect(result.exitCode, 0);
        expect(result.stdout, contains('flutter build web'));
        expect(result.stdout, contains('serve_static_with_headers.py'));
        expect(
          result.stdout,
          contains('playwright_chat_app_real_model_smoke.py'),
        );
        expect(
          result.stdout,
          contains(
            '/custom/python tool/testing/playwright_chat_app_real_model_smoke.py',
          ),
        );
        expect(
          result.stdout,
          contains('--model-url http://127.0.0.1:7358/models/tiny.gguf'),
        );
        expect(result.stdout, contains('--expect ok'));
      },
    );

    test('prefers repo-local Playwright Python by default', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'run_local_e2e_python_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final pythonPath = Platform.isWindows
          ? '${tempDir.path}/.dart_tool/playwright-python/Scripts/python.exe'
          : '${tempDir.path}/.dart_tool/playwright-python/bin/python';
      await File(pythonPath).create(recursive: true);

      final result = await runLocalE2e([
        '--scenario',
        'chat-app-web-litert-gemma4-smoke',
        '--skip-build',
        '--dry-run',
      ], projectRoot: tempDir.path);

      expect(result.exitCode, 0);
      expect(result.stdout, contains(pythonPath));
      expect(
        result.stdout,
        contains('tool/testing/playwright_chat_app_real_model_smoke.py'),
      );
    });

    test(
      'dry-runs Web LiteRT-LM Gemma 4 smoke with LiteRT response capture',
      () async {
        final result = await runLocalE2e(const [
          '--scenario',
          'chat-app-web-litert-gemma4-smoke',
          '--skip-build',
          '--dry-run',
        ], projectRoot: '/repo');

        expect(result.exitCode, 0);
        expect(
          result.stdout,
          contains('playwright_chat_app_real_model_smoke.py'),
        );
        expect(
          result.stdout,
          contains('gemma-4-E2B-it-web.litertlm?download=true'),
        );
        expect(result.stdout, contains('--response-source litert'));
        expect(result.stdout, contains('--backend-index 2'));
        expect(result.stdout, contains('--gpu-layers 999'));
        expect(result.stdout, contains('--penalty 1.1'));
      },
    );

    test('dry-runs WebGPU regression with forwarded runner options', () async {
      final result = await runLocalE2e(const [
        '--scenario',
        'webgpu-multimodal-regression',
        '--port',
        '9123',
        '--python',
        '/custom/python',
        '--skip-build',
        '--dry-run',
      ], projectRoot: '/repo');

      expect(result.exitCode, 0);
      expect(result.stdout, contains('PLAYWRIGHT_GATE_PORT=9123'));
      expect(result.stdout, contains('PLAYWRIGHT_PYTHON=/custom/python'));
      expect(result.stdout, contains('LLAMADART_SKIP_WEB_BUILD=1'));
      expect(
        result.stdout,
        contains('bash tool/testing/run_webgpu_multimodal_regression_gate.sh'),
      );
    });

    test('reports unknown scenarios without executing anything', () async {
      final result = await runLocalE2e(const [
        '--scenario',
        'does-not-exist',
        '--dry-run',
      ], projectRoot: '/repo');

      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Unknown local E2E scenario: does-not-exist'),
      );
      expect(result.stderr, contains('Use --list'));
    });

    test('reports port conflicts before starting Web smoke servers', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);

      final result = await runLocalE2e([
        '--scenario',
        'bridge-smoke',
        '--port',
        '${socket.port}',
      ], projectRoot: '/repo');

      expect(result.exitCode, isNot(0));
      expect(
        result.stdout,
        contains('Running local E2E scenario: bridge-smoke'),
      );
      expect(result.stderr, contains('Port ${socket.port} is already in use'));
    });

    test('reports background server startup failures', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final tempDir = await Directory.systemTemp.createTemp(
        'run_local_e2e_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      await Directory(
        '${tempDir.path}/example/chat_app/web',
      ).create(recursive: true);

      final result = await runLocalE2e([
        '--scenario',
        'bridge-smoke',
        '--python',
        'dart',
        '--port',
        '$port',
      ], projectRoot: tempDir.path);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Background server exited'));
    });
  });
}
