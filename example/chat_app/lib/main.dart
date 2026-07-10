import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'providers/chat_provider.dart';
import 'screens/app_shell_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const List<String> _emojiFontFallback = <String>[
    'Noto Color Emoji',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'Segoe UI Symbol',
    'EmojiOne Color',
  ];

  late final AppLifecycleListener _listener;
  final ChatProvider _chatProvider = ChatProvider();

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onDetach: () {
        unawaited(_chatProvider.shutdown());
      },
      onExitRequested: () async {
        await _chatProvider.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    unawaited(_chatProvider.shutdown());
    _chatProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final darkColorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF9CB2FF),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFFAFC1FF),
          onPrimary: const Color(0xFF14214A),
          surface: const Color(0xFF0D1118),
          surfaceContainerLowest: const Color(0xFF090C12),
          surfaceContainerLow: const Color(0xFF11161F),
          surfaceContainer: const Color(0xFF151A23),
          surfaceContainerHigh: const Color(0xFF191F29),
          surfaceContainerHighest: const Color(0xFF212834),
          outline: const Color(0xFF566171),
          outlineVariant: const Color(0xFF303845),
        );

    return ChangeNotifierProvider.value(
      value: _chatProvider,
      child: MaterialApp(
        title: 'llamadart chat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1D273A),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamilyFallback: _emojiFontFallback,
          textTheme: GoogleFonts.manropeTextTheme(),
          appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
        ),
        darkTheme: ThemeData(
          colorScheme: darkColorScheme,
          scaffoldBackgroundColor: darkColorScheme.surfaceContainerLowest,
          useMaterial3: true,
          fontFamilyFallback: _emojiFontFallback,
          textTheme: GoogleFonts.manropeTextTheme(ThemeData.dark().textTheme),
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            backgroundColor: Colors.transparent,
          ),
          cardTheme: const CardThemeData(elevation: 0),
          drawerTheme: DrawerThemeData(
            backgroundColor: darkColorScheme.surface,
            scrimColor: Colors.black.withValues(alpha: 0.68),
          ),
          dividerTheme: DividerThemeData(
            color: darkColorScheme.outlineVariant.withValues(alpha: 0.55),
            thickness: 1,
          ),
        ),
        themeMode: ThemeMode.dark,
        home: const AppShellScreen(),
      ),
    );
  }
}
