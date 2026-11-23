import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:material_ui/material_ui.dart';

import 'bridge_bootstrap.dart';
import 'playground_controller.dart';
import 'playground_widgets.dart';

void main() => runApp(const GenkitDartPadApp());

GenkitPlugin _googlePlugin(String key) => googleAI(apiKey: key, store: false);

class GenkitDartPadApp extends StatelessWidget {
  const GenkitDartPadApp({
    super.key,
    this.bootstrapGguf = bootstrapBridge,
    this.bootstrapLiteRt = bootstrapLiteRtLm,
    this.runtimeFactory,
    this.googlePlugin = _googlePlugin,
  });

  final Future<void> Function() bootstrapGguf;
  final Future<void> Function() bootstrapLiteRt;
  final LlamaDartRuntimeFactory? runtimeFactory;
  final GenkitPlugin Function(String key) googlePlugin;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xff17695f),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      // The Navigator provides text-field overlays without changing the
      // about:srcdoc URL in DartPad's preview iframe.
      builder: (_, _) => Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => _Playground(app: this)),
      ),
    );
  }
}

class _Playground extends StatefulWidget {
  const _Playground({required this.app});

  final GenkitDartPadApp app;

  @override
  State<_Playground> createState() => _PlaygroundState();
}

class _PlaygroundState extends State<_Playground> {
  late final _controller = PlaygroundController(
    bootstrapGguf: widget.app.bootstrapGguf,
    bootstrapLiteRt: widget.app.bootstrapLiteRt,
    runtimeFactory: widget.app.runtimeFactory,
    googlePlugin: widget.app.googlePlugin,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (_, _) => PlaygroundView(controller: _controller),
  );
}
