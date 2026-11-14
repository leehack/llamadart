import 'dart:async';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Parses browser/deep-link URLs (`/chat`, `/coding`, `/notes`, `/speech`,
/// `/image`, `/playground`, `/models`) into [StudioWorkspace] values.
class StudioRouteInformationParser
    extends RouteInformationParser<StudioWorkspace> {
  /// Creates a [StudioRouteInformationParser].
  const StudioRouteInformationParser();

  @override
  Future<StudioWorkspace> parseRouteInformation(
    RouteInformation routeInformation,
  ) {
    final path = routeInformation.uri.path;
    return SynchronousFuture<StudioWorkspace>(StudioWorkspace.fromRoute(path));
  }

  @override
  RouteInformation? restoreRouteInformation(StudioWorkspace configuration) {
    return RouteInformation(uri: Uri.parse('/${configuration.routeSegment}'));
  }
}

/// Synchronizes [StudioShellController]'s `activeWorkspace` with Flutter's
/// declarative `Router` API.
class StudioRouterDelegate extends RouterDelegate<StudioWorkspace>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<StudioWorkspace> {
  /// Creates a [StudioRouterDelegate].
  StudioRouterDelegate({
    required this.shellController,
    required this.rootBuilder,
  }) : navigatorKey = GlobalKey<NavigatorState>() {
    _sub = shellController.store
        .select((StudioShellState s) => s.activeWorkspace)
        .listen((_) => notifyListeners());
  }

  /// Shell controller owning the active workspace state.
  final StudioShellController shellController;

  /// Root shell widget builder.
  final WidgetBuilder rootBuilder;

  @override
  final GlobalKey<NavigatorState> navigatorKey;

  StreamSubscription<StudioWorkspace>? _sub;

  @override
  StudioWorkspace get currentConfiguration =>
      shellController.state.activeWorkspace;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      pages: <Page<void>>[
        MaterialPage<void>(
          key: const ValueKey<String>('studio_shell_root'),
          child: Builder(builder: rootBuilder),
        ),
      ],
      onDidRemovePage: (_) {},
    );
  }

  @override
  Future<void> setNewRoutePath(StudioWorkspace configuration) {
    shellController.selectWorkspace(configuration);
    return SynchronousFuture<void>(null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
