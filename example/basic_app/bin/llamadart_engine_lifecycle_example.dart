import 'package:llamadart/llamadart.dart';

/// Close dependants before the engine they borrow.
Future<void> closeEngines(
  List<LlamadartEngine<EngineCapabilities>> engines,
) async {
  for (final engine in engines.reversed) {
    await engine.dispose();
  }
}

Future<void> main() async {
  final text = LlamaEngine(LlamaBackend());
  final recognition = SpeechToTextEngine.attach(
    text,
    adapter: const Qwen3AsrAdapter(),
  );
  final synthesis = TextToSpeechEngine.attach(
    text,
    adapter: const Qwen3TtsAdapter(),
  );
  final engines = <LlamadartEngine<EngineCapabilities>>[
    text,
    recognition,
    synthesis,
  ];
  try {
    for (final engine in engines) {
      final capabilities = await engine.capabilities;
      print(capabilities.unsupportedReason ?? capabilities.backendName);
    }
  } finally {
    await closeEngines(engines);
  }
}
