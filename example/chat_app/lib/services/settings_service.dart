import 'package:shared_preferences/shared_preferences.dart';
import 'package:llamadart/llamadart.dart';
import '../models/chat_settings.dart';

class SettingsService {
  static const _keyModelPath = 'model_path';
  static const _keyBackend = 'preferred_backend';
  static const _keyTemp = 'temperature';
  static const _keyTopK = 'top_k';
  static const _keyTopP = 'top_p';
  static const _keyContext = 'context_size';
  static const _keyLogLevel = 'log_level';

  Future<ChatSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return ChatSettings(
      modelPath: prefs.getString(_keyModelPath),
      preferredBackend: GpuBackend.values[prefs.getInt(_keyBackend) ?? 0],
      temperature: prefs.getDouble(_keyTemp) ?? 0.7,
      topK: prefs.getInt(_keyTopK) ?? 40,
      topP: prefs.getDouble(_keyTopP) ?? 0.9,
      contextSize: prefs.getInt(_keyContext) ?? 0,
      logLevel: LlamaLogLevel
          .values[prefs.getInt(_keyLogLevel) ?? LlamaLogLevel.warn.index],
    );
  }

  Future<void> saveSettings(ChatSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    if (settings.modelPath != null) {
      await prefs.setString(_keyModelPath, settings.modelPath!);
    }
    await prefs.setInt(_keyBackend, settings.preferredBackend.index);
    await prefs.setDouble(_keyTemp, settings.temperature);
    await prefs.setInt(_keyTopK, settings.topK);
    await prefs.setDouble(_keyTopP, settings.topP);
    await prefs.setInt(_keyContext, settings.contextSize);
    await prefs.setInt(_keyLogLevel, settings.logLevel.index);
  }
}
