import 'package:relic/relic.dart';

import '../../../chat_completion/chat_completion.dart';
import '../../../embeddings/embeddings.dart';
import '../../../server_engine/server_engine.dart';
import '../docs/docs.dart';
import 'handlers/chat_completions_handler.dart';
import 'handlers/embeddings_handler.dart';
import 'handlers/system_handlers.dart';
import 'middleware.dart';
import 'routes/openai_routes.dart';
import 'support/generation_gate.dart';

/// OpenAI-compatible HTTP server wrapper for a single loaded model.
class OpenAiApiServer {
  /// The initialized inference engine.
  final ApiServerEngine engine;

  /// Public model ID exposed in API responses.
  final String modelId;

  /// Optional API key required for `/v1/*` endpoints.
  final String? apiKey;

  /// Whether request logs should be emitted.
  final bool enableRequestLogs;

  /// Model creation timestamp used in model listing responses.
  final int modelCreated;

  final bool _isApiKeyEnabled;
  final String _swaggerUiHtml;

  final ChatCompletionService _chatCompletionService;
  final EmbeddingsService _embeddingsService;
  final GenerationGate _generationGate;

  late final OpenAiSystemHandlers _systemHandlers = OpenAiSystemHandlers(
    engine: engine,
    modelId: modelId,
    modelCreated: modelCreated,
    apiKeyEnabled: _isApiKeyEnabled,
    swaggerUiHtml: _swaggerUiHtml,
    generationGate: _generationGate,
  );

  late final ChatCompletionsHandler _chatCompletionsHandler =
      ChatCompletionsHandler(
        modelId: modelId,
        chatCompletionService: _chatCompletionService,
        generationGate: _generationGate,
      );

  late final EmbeddingsHandler _embeddingsHandler = EmbeddingsHandler(
    modelId: modelId,
    embeddingsService: _embeddingsService,
    generationGate: _generationGate,
  );

  /// Creates a server wrapper around [engine].
  OpenAiApiServer({
    required this.engine,
    required this.modelId,
    this.apiKey,
    this.enableRequestLogs = false,
    int? modelCreated,
  }) : modelCreated =
           modelCreated ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
       _isApiKeyEnabled = apiKey != null && apiKey.isNotEmpty,
       _swaggerUiHtml = buildSwaggerUiHtml(
         specUrl: '/openapi.json',
         title: 'llamadart OpenAI-compatible API Docs',
       ),
       _chatCompletionService = ChatCompletionService(engine: engine),
       _embeddingsService = EmbeddingsService(engine: engine),
       _generationGate = GenerationGate(engine);

  /// Builds and configures a [RelicApp] instance.
  RelicApp buildApp() {
    final app = RelicApp();

    if (enableRequestLogs) {
      app.use('/', logRequests());
    }

    app
      ..use('/', createCorsMiddleware())
      ..use('/v1', createApiKeyMiddleware(apiKey));

    registerOpenAiRoutes(
      app,
      systemHandlers: _systemHandlers,
      chatCompletionsHandler: _chatCompletionsHandler,
      embeddingsHandler: _embeddingsHandler,
    );

    return app;
  }
}
