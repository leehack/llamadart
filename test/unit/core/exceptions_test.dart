import 'package:test/test.dart';
import 'package:llamadart/src/core/exceptions.dart';

void main() {
  group('LlamaException Tests', () {
    test('LlamaModelException properties', () {
      final ex = LlamaModelException('Fail to load', 'err_code_1');
      expect(ex.message, 'Fail to load');
      expect(ex.details, 'err_code_1');
      expect(
        ex.toString(),
        contains('LlamaException: Fail to load (err_code_1)'),
      );
    });

    test('LlamaContextException properties', () {
      final ex = LlamaContextException('Context full');
      expect(ex.message, 'Context full');
      expect(ex.details, isNull);
      expect(ex.toString(), 'LlamaException: Context full');
    });

    test('LlamaInferenceException properties', () {
      final ex = LlamaInferenceException('Gen failed');
      expect(ex.message, 'Gen failed');
      expect(ex.toString(), contains('Gen failed'));
    });

    test('LlamaSpeechException properties', () {
      final ex = LlamaSpeechException('Recognition failed', 'decoder error');
      expect(ex.message, 'Recognition failed');
      expect(ex.details, 'decoder error');
      expect(ex.toString(), contains('Recognition failed'));
    });

    test('LlamaAudioFormatException is a speech exception', () {
      final ex = LlamaAudioFormatException('Unsupported audio', 'stereo');
      expect(ex, isA<LlamaSpeechException>());
      expect(ex.message, 'Unsupported audio');
      expect(ex.details, 'stereo');
    });

    test('LlamaUnsupportedException properties', () {
      final ex = LlamaUnsupportedException('No CUDA');
      expect(ex.message, 'No CUDA');
      expect(ex.toString(), contains('No CUDA'));
    });

    test('LlamaStateException properties', () {
      final ex = LlamaStateException('Not loaded');
      expect(ex.message, 'Not loaded');
      expect(ex.toString(), contains('Not loaded'));
    });
  });
}
