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
  static const _keyThreads = 'threads';
  static const _keyThreadsBatch = 'threads_batch';
  static const _keyLogLevel = 'log_level';
  static const _keyNativeLogLevel = 'native_log_level';
  static const _keyToolsEnabled = 'tools_enabled';
  static const _keyToolDeclarations = 'tool_declarations';
  static const _keyThinkingEnabled = 'thinking_enabled';
  static const _keyThinkingBudgetTokens = 'thinking_budget_tokens';
  static const _keySingleTurnMode = 'single_turn_mode';
  static const _keyModelBytesHint = 'model_bytes_hint';

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
    final effectiveContextSize = switch (savedContextSize) {
      null => 4096,
      0 => 0,
      < 512 => 4096,
      _ => savedContextSize,
    };

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
      gpuLayers: prefs.getInt(_keyGpuLayers) ?? 32,
      numberOfThreads: prefs.getInt(_keyThreads) ?? 0,
      numberOfThreadsBatch: prefs.getInt(_keyThreadsBatch) ?? 0,
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
      modelBytesHint: prefs.getInt(_keyModelBytesHint),
    );
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
    await prefs.setInt(_keyThreads, settings.numberOfThreads);
    await prefs.setInt(_keyThreadsBatch, settings.numberOfThreadsBatch);
    await prefs.setInt(_keyLogLevel, settings.logLevel.index);
    await prefs.setInt(_keyNativeLogLevel, settings.nativeLogLevel.index);
    await prefs.setBool(_keyToolsEnabled, settings.toolsEnabled);
    await prefs.setString(_keyToolDeclarations, settings.toolDeclarations);
    await prefs.setBool(_keyThinkingEnabled, settings.thinkingEnabled);
    await prefs.setInt(_keyThinkingBudgetTokens, settings.thinkingBudgetTokens);
    await prefs.setBool(_keySingleTurnMode, settings.singleTurnMode);
    final modelBytesHint = settings.modelBytesHint;
    if (modelBytesHint != null && modelBytesHint > 0) {
      await prefs.setInt(_keyModelBytesHint, modelBytesHint);
    } else {
      await prefs.remove(_keyModelBytesHint);
    }
  }
}
