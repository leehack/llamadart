import 'package:relic/io_adapter.dart';

import 'cli/server_cli_config.dart';
import '../features/openai_api/openai_api.dart';
import 'runtime/runtime.dart';
import 'shutdown_signal.dart';

/// Boots and runs the HTTP server using parsed CLI config.
Future<void> runServerFromConfig(ServerCliConfig config) async {
  final serverEngine = await createInitializedServerEngine(config);

  Future<void> Function()? closeServer;
  try {
    final apiServer = OpenAiApiServer(
      engine: serverEngine,
      modelId: config.modelId,
      apiKey: config.apiKey,
      enableRequestLogs: config.enableDartLogs,
    );

    final server = await apiServer.buildApp().serve(
      address: config.address,
      port: config.port,
    );
    closeServer = server.close;

    printServerStartup(config);

    await waitForShutdownSignal();
    printServerStopping();
  } finally {
    if (closeServer != null) {
      await closeServer();
    }
    await serverEngine.engine.dispose();
  }
}
