@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/speech_wav_source_io.dart';

void main() {
  late Directory root;
  late SpeechWavSources sources;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('llamadart_speech_sources_');
    sources = SpeechWavSources(root: root);
  });

  tearDown(() async {
    await sources.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('plays each buffer from a written .wav file', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

    final source = await sources.create(bytes) as DeviceFileSource;

    expect(source.path, endsWith('.wav'));
    expect(source.mimeType, 'audio/wav');
    expect(await File(source.path).readAsBytes(), bytes);
  });

  test('keeps only the latest buffer on disk', () async {
    final first = await sources.create(Uint8List.fromList(<int>[1]));
    final second = await sources.create(Uint8List.fromList(<int>[2]));

    final firstPath = (first as DeviceFileSource).path;
    final secondPath = (second as DeviceFileSource).path;
    expect(secondPath, isNot(firstPath));
    expect(File(firstPath).existsSync(), isFalse);
    expect(await File(secondPath).readAsBytes(), <int>[2]);
  });

  test('dispose deletes every written file', () async {
    final source = await sources.create(Uint8List.fromList(<int>[1]));

    await sources.dispose();

    expect(File((source as DeviceFileSource).path).existsSync(), isFalse);
    expect(root.listSync(), isEmpty);
  });
}
