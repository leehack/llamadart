@TestOn('vm && (mac-os || linux)')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

void main() {
  for (final legacy in [false, true]) {
    test('native conversation template setter, legacy=$legacy', () async {
      final dir = await Directory.systemTemp.createTemp('litert_template_');
      final library =
          '${dir.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
      final result = await Process.run('cc', [
        '-shared',
        '-fPIC',
        if (legacy) '-DOMIT_TEMPLATE_SETTER',
        'test/fixtures/litert_lm/conversation_template.c',
        '-o',
        library,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final client = LiteRtLmRuntimeClient(libraryPath: library);
      try {
        await client.initialize(modelPath: 'fixture.litertlm', backend: 'cpu');
        if (legacy) {
          expect(
            () => client.createConversation(
              promptTemplate: 'required',
              npuBackend: true,
            ),
            throwsA(isA<LlamaUnsupportedException>()),
          );
          // A runtime without this optional setter still supports requests
          // which preserve its native model template.
          client.createConversation(npuBackend: true);
          expect(
            client.renderMessageToString({'role': 'user', 'content': 'Hi'}),
            '',
          );
        } else {
          const template = '{{ messages }}\n<think>\n\n</think>\n\n';
          const system =
              'Keep literal JSON: {"content":"hello"} and Unicode: 안녕';
          client.createConversation(
            promptTemplate: template,
            systemMessage: system,
            npuBackend: true,
          );
          final readSystem = DynamicLibrary.open(library)
              .lookupFunction<
                Pointer<Utf8> Function(),
                Pointer<Utf8> Function()
              >('fixture_system_message');
          expect(jsonDecode(readSystem().toDartString()), system);
          expect(
            client.renderMessageToString({'role': 'user', 'content': 'Hi'}),
            template,
          );
          client.createConversation(npuBackend: true);
          expect(
            client.renderMessageToString({'role': 'user', 'content': 'Hi'}),
            '',
          );
        }
      } finally {
        client.dispose();
        await dir.delete(recursive: true);
      }
    });
  }
}
