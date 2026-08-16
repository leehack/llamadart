import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:llamadart/llamadart.dart';

import '../models/chat_settings.dart';

class SettingsService {
  static const _keyModelPath = 'model_path';
  static const _keyMmprojPath = 'mmproj_path';
  static const _keyBackend = 'preferred_backend';
  static const _keyTemp = 'temperature';
  static const _keyTopK = 'top_k';
  static const _keyTopP = 'top_p';
  static const _keyMinP = 'min_p';
  static const _keyPenalty = 'penalty';
  static const _keyContext = 'context_size';
  static const _keyMaxTokens = 'max_tokens';
  static const _keyGpuLayers = 'gpu_layers';
  static const _keyAutoTuneModelParams = 'auto_tune_model_params';
  static const _keyAutoTuneRequestedContext =
      'auto_tune_requested_context_size';
  static const _keyThreads = 'threads';
  static const _keyThreadsBatch = 'threads_batch';
  static const _keyBatchSize = 'batch_size';
  static const _keyMicroBatchSize = 'micro_batch_size';
  static const _keyLogLevel = 'log_level';
  static const _keyNativeLogLevel = 'native_log_level';
  static const _keyToolsEnabled = 'tools_enabled';
  static const _keyToolDeclarations = 'tool_declarations';
  static const _keyThinkingEnabled = 'thinking_enabled';
  static const _keyThinkingBudgetTokens = 'thinking_budget_tokens';
  static const _keySingleTurnMode = 'single_turn_mode';
  static const _keyModelSupportsVision = 'model_supports_vision';
  static const _keyModelSupportsAudio = 'model_supports_audio';
  static const _keyModelSupportsSpeechToText = 'model_supports_speech_to_text';
  static const _keyModelSupportsTextToSpeech = 'model_supports_text_to_speech';
  static const _keyDirectMediaInput = 'direct_media_input';
  static const _keyModelBytesHint = 'model_bytes_hint';
  static const _keyLiveSpeechEnabled = 'live_speech_enabled';
  static const _keyLiveSpeechModelId = 'live_speech_model_id';

  static const Map<String, String> _modelPathMigrations = {
    'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-UD-Q4_K_XL.gguf?download=true':
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
    'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-UD-Q4_K_XL.gguf?download=true':
        'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true',
    'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-UD-Q4_K_XL.gguf?download=true':
        'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true',
    'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-Q4_K_XL.gguf?download=true':
        'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true',
  };

  LlamaLogLevel _parseLogLevel(int? index, LlamaLogLevel fallback) {
    if (index == null || index < 0 || index >= LlamaLogLevel.values.length) {
      return fallback;
    }
    return LlamaLogLevel.values[index];
  }

  bool _isNativeGemma4LiteRtLm(String? modelPath) {
    if (kIsWeb || modelPath == null) {
      return false;
    }
    final normalized = modelPath
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
    return normalized.endsWith('.litertlm') &&
        (normalized.contains('gemma-4') || normalized.contains('gemma4'));
  }

  bool _isQwen3AsrCatalogModel(String? modelPath) {
    if (modelPath == null) {
      return false;
    }
    final filename = modelPath
        .split('?')
        .first
        .split('#')
        .first
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    return filename == 'qwen3-asr-0.6b-q8_0.gguf';
  }

  bool _isQwen3TtsCatalogModel(String? modelPath) {
    if (modelPath == null) {
      return false;
    }
    final filename = modelPath
        .split('?')
        .first
        .split('#')
        .first
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    return filename == 'qwen3-tts-12hz-1.7b-base-q4_k_m.gguf';
  }

  Future<ChatSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModelPath = prefs.getString(_keyModelPath);
    final migratedModelPath =
        _modelPathMigrations[savedModelPath] ?? savedModelPath;
    if (migratedModelPath != null && migratedModelPath != savedModelPath) {
      await prefs.setString(_keyModelPath, migratedModelPath);
    }

    final backendIndex = prefs.getInt(_keyBackend);
    final preferredBackend =
        backendIndex != null &&
            backendIndex >= 0 &&
            backendIndex < GpuBackend.values.length
        ? GpuBackend.values[backendIndex]
        : GpuBackend.auto;
    final savedContextSize = prefs.getInt(_keyContext);
    final savedGpuLayers = prefs.getInt(_keyGpuLayers);
    final effectiveContextSize = switch (savedContextSize) {
      null => 4096,
      0 => 0,
      < 512 => 4096,
      _ => savedContextSize,
    };
    final migrateNativeGemma4Audio = _isNativeGemma4LiteRtLm(migratedModelPath);

    return ChatSettings(
      modelPath: migratedModelPath,
      mmprojPath: prefs.getString(_keyMmprojPath),
      preferredBackend: preferredBackend,
      temperature: prefs.getDouble(_keyTemp) ?? 0.7,
      topK: prefs.getInt(_keyTopK) ?? 40,
      topP: prefs.getDouble(_keyTopP) ?? 0.9,
      minP: prefs.getDouble(_keyMinP) ?? 0.0,
      penalty: prefs.getDouble(_keyPenalty) ?? 1.1,
      contextSize: effectiveContextSize,
      maxTokens: prefs.getInt(_keyMaxTokens) ?? 4096,
      gpuLayers: savedGpuLayers ?? 32,
      autoTuneModelParams:
          prefs.getBool(_keyAutoTuneModelParams) ??
          (preferredBackend == GpuBackend.auto &&
              (savedGpuLayers == null ||
                  savedGpuLayers == 32 ||
                  savedGpuLayers >= 99)),
      autoTuneRequestedContextSize:
          prefs.getInt(_keyAutoTuneRequestedContext) ?? effectiveContextSize,
      numberOfThreads: prefs.getInt(_keyThreads) ?? 0,
      numberOfThreadsBatch: prefs.getInt(_keyThreadsBatch) ?? 0,
      batchSize: prefs.getInt(_keyBatchSize) ?? 0,
      microBatchSize: prefs.getInt(_keyMicroBatchSize) ?? 0,
      logLevel: _parseLogLevel(prefs.getInt(_keyLogLevel), LlamaLogLevel.none),
      nativeLogLevel: _parseLogLevel(
        prefs.getInt(_keyNativeLogLevel),
        LlamaLogLevel.warn,
      ),
      toolsEnabled: prefs.getBool(_keyToolsEnabled) ?? false,
      toolDeclarations: prefs.getString(_keyToolDeclarations) ?? '[]',
      thinkingEnabled: prefs.getBool(_keyThinkingEnabled) ?? true,
      thinkingBudgetTokens: prefs.getInt(_keyThinkingBudgetTokens) ?? 0,
      singleTurnMode: prefs.getBool(_keySingleTurnMode) ?? false,
      modelSupportsVision: prefs.getBool(_keyModelSupportsVision) ?? false,
      modelSupportsAudio:
          prefs.getBool(_keyModelSupportsAudio) ?? migrateNativeGemma4Audio,
      modelSupportsSpeechToText:
          prefs.getBool(_keyModelSupportsSpeechToText) ??
          _isQwen3AsrCatalogModel(migratedModelPath),
      modelSupportsTextToSpeech:
          prefs.getBool(_keyModelSupportsTextToSpeech) ??
          _isQwen3TtsCatalogModel(migratedModelPath),
      directMediaInput:
          prefs.getBool(_keyDirectMediaInput) ?? migrateNativeGemma4Audio,
      modelBytesHint: prefs.getInt(_keyModelBytesHint),
    );
  }

  /// Loads the globally selected live-dictation sidecar identifier.
  Future<String?> loadLiveSpeechModelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLiveSpeechModelId);
  }

  /// Loads whether the app-owned live-dictation feature is enabled.
  Future<bool> loadLiveSpeechEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLiveSpeechEnabled) ?? true;
  }

  /// Persists whether the app-owned live-dictation feature is enabled.
  Future<void> saveLiveSpeechEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLiveSpeechEnabled, enabled);
  }

  /// Persists the globally selected live-dictation sidecar identifier.
  Future<void> saveLiveSpeechModelId(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLiveSpeechModelId, modelId);
  }

  Future<void> saveSettings(ChatSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    if (settings.modelPath != null) {
      await prefs.setString(_keyModelPath, settings.modelPath!);
    }
    if (settings.mmprojPath != null) {
      await prefs.setString(_keyMmprojPath, settings.mmprojPath!);
    } else {
      await prefs.remove(_keyMmprojPath);
    }
    await prefs.setInt(_keyBackend, settings.preferredBackend.index);
    await prefs.setDouble(_keyTemp, settings.temperature);
    await prefs.setInt(_keyTopK, settings.topK);
    await prefs.setDouble(_keyTopP, settings.topP);
    await prefs.setDouble(_keyMinP, settings.minP);
    await prefs.setDouble(_keyPenalty, settings.penalty);
    await prefs.setInt(_keyContext, settings.contextSize);
    await prefs.setInt(_keyMaxTokens, settings.maxTokens);
    await prefs.setInt(_keyGpuLayers, settings.gpuLayers);
    await prefs.setBool(_keyAutoTuneModelParams, settings.autoTuneModelParams);
    final autoTuneRequestedContextSize = settings.autoTuneRequestedContextSize;
    if (autoTuneRequestedContextSize != null) {
      await prefs.setInt(
        _keyAutoTuneRequestedContext,
        autoTuneRequestedContextSize,
      );
    } else {
      await prefs.remove(_keyAutoTuneRequestedContext);
    }
    await prefs.setInt(_keyThreads, settings.numberOfThreads);
    await prefs.setInt(_keyThreadsBatch, settings.numberOfThreadsBatch);
    await prefs.setInt(_keyBatchSize, settings.batchSize);
    await prefs.setInt(_keyMicroBatchSize, settings.microBatchSize);
    await prefs.setInt(_keyLogLevel, settings.logLevel.index);
    await prefs.setInt(_keyNativeLogLevel, settings.nativeLogLevel.index);
    await prefs.setBool(_keyToolsEnabled, settings.toolsEnabled);
    await prefs.setString(_keyToolDeclarations, settings.toolDeclarations);
    await prefs.setBool(_keyThinkingEnabled, settings.thinkingEnabled);
    await prefs.setInt(_keyThinkingBudgetTokens, settings.thinkingBudgetTokens);
    await prefs.setBool(_keySingleTurnMode, settings.singleTurnMode);
    await prefs.setBool(_keyModelSupportsVision, settings.modelSupportsVision);
    await prefs.setBool(_keyModelSupportsAudio, settings.modelSupportsAudio);
    await prefs.setBool(
      _keyModelSupportsSpeechToText,
      settings.modelSupportsSpeechToText,
    );
    await prefs.setBool(
      _keyModelSupportsTextToSpeech,
      settings.modelSupportsTextToSpeech,
    );
    await prefs.setBool(_keyDirectMediaInput, settings.directMediaInput);
    final modelBytesHint = settings.modelBytesHint;
    if (modelBytesHint != null && modelBytesHint > 0) {
      await prefs.setInt(_keyModelBytesHint, modelBytesHint);
    } else {
      await prefs.remove(_keyModelBytesHint);
    }
  }
}
