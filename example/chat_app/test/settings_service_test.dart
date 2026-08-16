import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService context size', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('preserves explicit auto context size from storage', () async {
      SharedPreferences.setMockInitialValues({'context_size': 0});

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.contextSize, 0);
    });

    test('defaults tool calling to disabled', () async {
      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.toolsEnabled, isFalse);
    });

    test('defaults preferred backend to auto', () async {
      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.preferredBackend, GpuBackend.auto);
      expect(settings.autoTuneModelParams, isTrue);
      expect(settings.batchSize, 0);
      expect(settings.microBatchSize, 0);
    });

    test('persists logical and micro batch sizes', () async {
      final service = SettingsService();
      const settings = ChatSettings(batchSize: 256, microBatchSize: 64);

      await service.saveSettings(settings);
      final restored = await service.loadSettings();

      expect(restored.batchSize, 256);
      expect(restored.microBatchSize, 64);
    });

    test('persists the selected live speech sidecar independently', () async {
      final service = SettingsService();

      expect(await service.loadLiveSpeechModelId(), isNull);
      await service.saveLiveSpeechModelId('litert-parakeet-tdt-0.6b-v3-i8');

      expect(
        await service.loadLiveSpeechModelId(),
        'litert-parakeet-tdt-0.6b-v3-i8',
      );
    });

    test('enables live dictation by default and persists opt-out', () async {
      final service = SettingsService();

      expect(await service.loadLiveSpeechEnabled(), isTrue);
      await service.saveLiveSpeechEnabled(false);

      expect(await service.loadLiveSpeechEnabled(), isFalse);
    });

    test('persists Auto intent after resolving partial GPU offload', () async {
      final service = SettingsService();
      const settings = ChatSettings(
        preferredBackend: GpuBackend.auto,
        gpuLayers: 66,
        contextSize: 4096,
        autoTuneModelParams: true,
        autoTuneRequestedContextSize: 16384,
      );

      await service.saveSettings(settings);
      final restored = await service.loadSettings();

      expect(restored.gpuLayers, 66);
      expect(restored.contextSize, 4096);
      expect(restored.autoTuneModelParams, isTrue);
      expect(restored.autoTuneRequestedContextSize, 16384);
    });

    test(
      'does not infer Auto intent for a legacy manual layer value',
      () async {
        SharedPreferences.setMockInitialValues({
          'preferred_backend': GpuBackend.auto.index,
          'gpu_layers': 48,
        });

        final service = SettingsService();
        final settings = await service.loadSettings();

        expect(settings.autoTuneModelParams, isFalse);
      },
    );

    test('falls back to auto for invalid backend index', () async {
      SharedPreferences.setMockInitialValues({'preferred_backend': 999});

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.preferredBackend, GpuBackend.auto);
    });

    test('falls back to defaults for invalid log level indices', () async {
      SharedPreferences.setMockInitialValues({
        'log_level': 999,
        'native_log_level': -1,
      });

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.logLevel, LlamaLogLevel.none);
      expect(settings.nativeLogLevel, LlamaLogLevel.warn);
    });

    test('normalizes invalid legacy context size values', () async {
      SharedPreferences.setMockInitialValues({'context_size': 128});

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.contextSize, 4096);
    });

    test('saves zero context size for auto mode', () async {
      final service = SettingsService();
      const settings = ChatSettings(contextSize: 0);

      await service.saveSettings(settings);
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getInt('context_size'), 0);
    });

    test('persists direct model media capabilities', () async {
      final service = SettingsService();
      const settings = ChatSettings(
        modelSupportsVision: false,
        modelSupportsAudio: true,
        modelSupportsSpeechToText: true,
        modelSupportsTextToSpeech: true,
        directMediaInput: true,
      );

      await service.saveSettings(settings);
      final restored = await service.loadSettings();

      expect(restored.modelSupportsVision, isFalse);
      expect(restored.modelSupportsAudio, isTrue);
      expect(restored.modelSupportsSpeechToText, isTrue);
      expect(restored.modelSupportsTextToSpeech, isTrue);
      expect(restored.directMediaInput, isTrue);
    });

    test(
      'migrates existing native Gemma 4 LiteRT-LM selections to audio',
      () async {
        SharedPreferences.setMockInitialValues({
          'model_path': '/models/gemma-4-E2B-it.litertlm',
        });

        final service = SettingsService();
        final settings = await service.loadSettings();

        expect(settings.modelSupportsAudio, isTrue);
        expect(settings.directMediaInput, isTrue);
      },
    );

    test('migrates the catalog Qwen3-ASR filename to typed STT', () async {
      SharedPreferences.setMockInitialValues({
        'model_path': '/models/Qwen3-ASR-0.6B-Q8_0.gguf',
      });

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.modelSupportsSpeechToText, isTrue);
    });

    test('preserves an explicit disabled Qwen3-ASR STT setting', () async {
      SharedPreferences.setMockInitialValues({
        'model_path': '/models/Qwen3-ASR-0.6B-Q8_0.gguf',
        'model_supports_speech_to_text': false,
      });

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.modelSupportsSpeechToText, isFalse);
    });

    test('migrates the catalog Qwen3-TTS filename to typed TTS', () async {
      SharedPreferences.setMockInitialValues({
        'model_path': '/models/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf',
      });

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.modelSupportsTextToSpeech, isTrue);
    });

    test('preserves an explicit disabled Qwen3-TTS setting', () async {
      SharedPreferences.setMockInitialValues({
        'model_path': '/models/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf',
        'model_supports_text_to_speech': false,
      });

      final service = SettingsService();
      final settings = await service.loadSettings();

      expect(settings.modelSupportsTextToSpeech, isFalse);
    });

    test('migrates saved Unsloth UD Qwen model paths to Q4_K_M', () async {
      SharedPreferences.setMockInitialValues({
        'model_path':
            'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-UD-Q4_K_XL.gguf?download=true',
      });

      final service = SettingsService();
      final settings = await service.loadSettings();
      final prefs = await SharedPreferences.getInstance();

      expect(
        settings.modelPath,
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
      );
      expect(
        prefs.getString('model_path'),
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
      );
    });
  });
}
