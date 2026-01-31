import 'package:llamadart/llamadart.dart';

class ChatSettings {
  final String? modelPath;
  final GpuBackend preferredBackend;
  final double temperature;
  final int topK;
  final double topP;
  final int contextSize;
  final LlamaLogLevel logLevel;

  const ChatSettings({
    this.modelPath,
    this.preferredBackend = GpuBackend.auto,
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.contextSize = 0,
    this.logLevel = LlamaLogLevel.error,
  });

  ChatSettings copyWith({
    String? modelPath,
    GpuBackend? preferredBackend,
    double? temperature,
    int? topK,
    double? topP,
    int? contextSize,
    LlamaLogLevel? logLevel,
  }) {
    return ChatSettings(
      modelPath: modelPath ?? this.modelPath,
      preferredBackend: preferredBackend ?? this.preferredBackend,
      temperature: temperature ?? this.temperature,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      contextSize: contextSize ?? this.contextSize,
      logLevel: logLevel ?? this.logLevel,
    );
  }
}
