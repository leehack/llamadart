// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../app/studio_dependencies.dart';
import 'store_widgets.dart';

/// Runs a model action and presents failures while its originating view exists.
Future<void> runModelLoadAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Model load failed: ${humanizeStudioError(error, sensitiveValues: <String>[StudioScope.of(context).modelHubController.state.bearerToken])}',
        ),
      ),
    );
  }
}

/// Retains Chat model load failures and offers the original action for retry.
class ModelLoadErrorBanner extends StatelessWidget {
  /// Creates a model load failure banner.
  const ModelLoadErrorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = StudioScope.of(context).modelHubController;
    return StoreBuilder<ModelHubState>(
      store: hub.store,
      builder: (context, state) {
        final error = state.activationErrorMessage;
        if (error == null) return const SizedBox.shrink();
        return MaterialBanner(
          key: const Key('chat_model_load_error'),
          content: Text('Could not load model: $error'),
          leading: const Icon(Icons.error_outline_rounded),
          actions: <Widget>[
            TextButton(
              key: const Key('retry_chat_model_load'),
              onPressed: state.activatingDescriptor != null
                  ? null
                  : () =>
                        runModelLoadAction(context, hub.retryLastChatModelLoad),
              child: const Text('Retry'),
            ),
          ],
        );
      },
    );
  }
}
