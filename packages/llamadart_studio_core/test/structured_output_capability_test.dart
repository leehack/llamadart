@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

class _NoSchemaBackend extends FakeSpeculativeFallbackBackend
    implements BackendGrammarConstraintsSupport {
  @override
  bool get supportsGrammarConstraints => false;
}

void main() {
  for (final unsupported in [true, false]) {
    test(
      unsupported
          ? 'strict schema refuses unsupported runtime before generation'
          : 'non-object schema refuses before generation',
      () async {
        final dir = await Directory.systemTemp.createTemp('studio_schema_');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/test.gguf');
        await file.writeAsBytes([0x47, 0x47, 0x55, 0x46]);
        final backend = unsupported
            ? _NoSchemaBackend()
            : FakeSpeculativeFallbackBackend();
        final port = DirectLlamaInferencePort(backend: backend);
        addTearDown(port.dispose);
        const settings = StudioSettings(
          toolsEnabled: false,
          thinkingEnabled: false,
        );
        await port.loadModel(
          assets: ResolvedModelAssets(
            descriptor: StudioModelDescriptor(
              id: 'test',
              name: 'Test',
              description: 'Test',
              category: StudioModelCategory.chat,
              filename: 'test.gguf',
              sourceUri: file.path,
            ),
            primarySource: ModelSource.path(file.path),
          ),
          settings: settings,
          isWeb: false,
        );
        expect(
          port.runtimeStore.state.capabilities!.supportsStructuredOutput,
          !unsupported,
        );
        await expectLater(
          port
              .streamTurn(
                StudioTurnRequest(
                  history: [
                    StudioMessage(
                      id: 'u',
                      role: StudioRole.user,
                      text: 'Return an object',
                      createdAt: DateTime.now(),
                    ),
                  ],
                  settings: settings,
                  systemPrompt: '',
                  jsonSchema: unsupported ? '{"type":"object"}' : '[]',
                ),
              )
              .toList(),
          throwsA(
            unsupported
                ? isA<LlamaUnsupportedException>()
                : isA<LlamaArgumentException>(),
          ),
        );
        expect(backend.recordedSpeculativeFlags, isEmpty);
      },
    );
  }
}
