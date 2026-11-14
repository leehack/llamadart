/// Cross-platform Flutter UI package for `llamadart Studio`, powered by the
/// pure-Dart `llamadart_studio_core` domain and controller layer.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'src/app/studio_dependencies.dart';
import 'src/app/studio_router.dart';
import 'src/app/studio_theme.dart';
import 'src/widgets/store_widgets.dart';
import 'src/workspaces/shell/studio_shell_screen.dart';

export 'src/app/studio_dependencies.dart';
export 'src/app/studio_router.dart';
export 'src/app/studio_theme.dart';
export 'src/widgets/store_widgets.dart';
export 'src/workspaces/chat/chat_workspace_view.dart';
export 'src/workspaces/coding/coding_workspace_view.dart';
export 'src/workspaces/image/image_workspace_view.dart';
export 'src/workspaces/models/model_hub_workspace_view.dart';
export 'src/workspaces/notes/notebook_workspace_view.dart';
export 'src/workspaces/playground/playground_workspace_view.dart';
export 'src/workspaces/shell/studio_shell_screen.dart';
export 'src/workspaces/speech/speech_workspace_view.dart';

/// Installs production-grade global error boundaries (`FlutterError.onError`,
/// `PlatformDispatcher.instance.onError`, and `ErrorWidget.builder`) so any
/// uncaught widget or async platform error logs cleanly and renders a styled
/// recoverable card instead of a raw framework crash screen.
void installStudioProductionErrorHandlers({
  void Function(Object error, StackTrace? stack)? onReportError,
}) {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    onReportError?.call(details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[llamadart_studio] Uncaught platform error: $error\n$stack');
    onReportError?.call(error, stack);
    return true;
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return StudioErrorFallbackCard(details: details);
  };
}

/// Styled dark/light-aware fallback card rendered when an unexpected widget
/// build error occurs in release or debug mode.
class StudioErrorFallbackCard extends StatelessWidget {
  /// Creates a [StudioErrorFallbackCard].
  const StudioErrorFallbackCard({super.key, required this.details});

  /// Underlying Flutter error details.
  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.dark;
    final summary = humanizeStudioError(details.exception);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Container(
          key: const Key('studio_error_fallback_card'),
          constraints: const BoxConstraints(maxWidth: 440),
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.danger.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: palette.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Component Render Error',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                summary,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Root `MaterialApp.router` widget for `llamadart Studio`.
class LlamadartStudioApp extends StatefulWidget {
  /// Creates a [LlamadartStudioApp] bound to [dependencies].
  const LlamadartStudioApp({super.key, required this.dependencies});

  /// Initialized Studio controllers, ports, and lifecycle coordinator.
  final StudioDependencies dependencies;

  @override
  State<LlamadartStudioApp> createState() => _LlamadartStudioAppState();
}

class _LlamadartStudioAppState extends State<LlamadartStudioApp> {
  late StudioRouterDelegate _routerDelegate;
  final StudioRouteInformationParser _routeParser =
      const StudioRouteInformationParser();

  @override
  void initState() {
    super.initState();
    _routerDelegate = StudioRouterDelegate(
      shellController: widget.dependencies.shellController,
      rootBuilder: (_) => const StudioShellScreen(),
    );
  }

  @override
  void didUpdateWidget(covariant LlamadartStudioApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.dependencies.shellController,
      widget.dependencies.shellController,
    )) {
      _routerDelegate.dispose();
      _routerDelegate = StudioRouterDelegate(
        shellController: widget.dependencies.shellController,
        rootBuilder: (_) => const StudioShellScreen(),
      );
    }
  }

  @override
  void dispose() {
    _routerDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StudioScope(
      deps: widget.dependencies,
      child: StoreSelector<StudioShellState, StudioAppearance>(
        store: widget.dependencies.shellController.store,
        selector: (StudioShellState s) => s.settings.appearance,
        builder: (BuildContext context, StudioAppearance appearance) {
          return MaterialApp.router(
            title: 'llamadart Studio',
            debugShowCheckedModeBanner: false,
            theme: StudioTheme.light(),
            darkTheme: StudioTheme.dark(),
            themeMode: StudioTheme.toThemeMode(appearance),
            routerDelegate: _routerDelegate,
            routeInformationParser: _routeParser,
          );
        },
      ),
    );
  }
}
