// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Semantic color tokens attached to [ThemeData] for `llamadart Studio`.
@immutable
class StudioPalette extends ThemeExtension<StudioPalette> {
  /// Creates a [StudioPalette].
  const StudioPalette({
    required this.canvas,
    required this.sidebar,
    required this.surfaceElevated,
    required this.borderSubtle,
    required this.borderStrong,
    required this.accent,
    required this.accentMuted,
    required this.teal,
    required this.amber,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });

  /// Root window canvas color.
  final Color canvas;

  /// Sidebar & inspector rail background.
  final Color sidebar;

  /// Elevated card/composer surface.
  final Color surfaceElevated;

  /// Hairline divider border.
  final Color borderSubtle;

  /// Emphasized interactive border.
  final Color borderStrong;

  /// Primary electric indigo/cobalt accent.
  final Color accent;

  /// Translucent accent tint for selected pills.
  final Color accentMuted;

  /// Telemetry / success emerald-teal accent.
  final Color teal;

  /// Warning / tight-memory amber accent.
  final Color amber;

  /// Error / OOM crimson accent.
  final Color danger;

  /// Primary body/heading foreground.
  final Color textPrimary;

  /// Secondary label foreground.
  final Color textSecondary;

  /// Muted metadata/timestamp foreground.
  final Color textMuted;

  /// Dark graphite Studio palette matching the interactive design preview.
  static const StudioPalette dark = StudioPalette(
    canvas: Color(0xFF0B0F19),
    sidebar: Color(0xFF0E1422),
    surfaceElevated: Color(0xFF141C2E),
    borderSubtle: Color(0xFF1E293B),
    borderStrong: Color(0xFF334155),
    accent: Color(0xFF6366F1),
    accentMuted: Color(0x266366F1),
    teal: Color(0xFF14B8A6),
    amber: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF64748B),
  );

  /// Crisp light Studio palette.
  static const StudioPalette light = StudioPalette(
    canvas: Color(0xFFF8FAFC),
    sidebar: Color(0xFFF1F5F9),
    surfaceElevated: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFFE2E8F0),
    borderStrong: Color(0xFFCBD5E1),
    accent: Color(0xFF4F46E5),
    accentMuted: Color(0x1A4F46E5),
    teal: Color(0xFF0D9488),
    amber: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF64748B),
  );

  /// Resolves the active [StudioPalette] from [context].
  static StudioPalette of(BuildContext context) {
    return Theme.of(context).extension<StudioPalette>() ?? dark;
  }

  @override
  StudioPalette copyWith({
    Color? canvas,
    Color? sidebar,
    Color? surfaceElevated,
    Color? borderSubtle,
    Color? borderStrong,
    Color? accent,
    Color? accentMuted,
    Color? teal,
    Color? amber,
    Color? danger,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
  }) {
    return StudioPalette(
      canvas: canvas ?? this.canvas,
      sidebar: sidebar ?? this.sidebar,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderStrong: borderStrong ?? this.borderStrong,
      accent: accent ?? this.accent,
      accentMuted: accentMuted ?? this.accentMuted,
      teal: teal ?? this.teal,
      amber: amber ?? this.amber,
      danger: danger ?? this.danger,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
    );
  }

  @override
  StudioPalette lerp(covariant ThemeExtension<StudioPalette>? other, double t) {
    if (other is! StudioPalette) {
      return this;
    }
    return StudioPalette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      teal: Color.lerp(teal, other.teal, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
    );
  }
}

/// Builds light and dark Material 3 [ThemeData] for `llamadart Studio`.
abstract final class StudioTheme {
  /// Converts [StudioAppearance] to Flutter's [ThemeMode].
  static ThemeMode toThemeMode(StudioAppearance appearance) {
    return switch (appearance) {
      StudioAppearance.system => ThemeMode.system,
      StudioAppearance.light => ThemeMode.light,
      StudioAppearance.dark => ThemeMode.dark,
    };
  }

  /// Monospace font family stack for telemetry, tokens, and JSON schemas.
  static const List<String> monoFontFallback = <String>[
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'monospace',
  ];

  /// Formats a primary command shortcut badge (`⌘K` on Apple hosts,
  /// `Ctrl+K` on Windows/Linux/Android).
  static String shortcutLabel(BuildContext context, String key) {
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    return isApple ? '⌘$key' : 'Ctrl+$key';
  }

  /// Builds the dark Studio theme.
  static ThemeData dark() => _build(Brightness.dark, StudioPalette.dark);

  /// Builds the light Studio theme.
  static ThemeData light() => _build(Brightness.light, StudioPalette.light);

  static ThemeData _build(Brightness brightness, StudioPalette p) {
    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.canvas,
      primary: p.accent,
      secondary: p.teal,
      error: p.danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.canvas,
      dividerColor: p.borderSubtle,
      extensions: <ThemeExtension<dynamic>>[p],
      cardTheme: CardThemeData(
        color: p.surfaceElevated,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.borderSubtle),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceElevated,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.accent, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceElevated,
        selectedColor: p.accentMuted,
        side: BorderSide(color: p.borderSubtle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: TextStyle(fontSize: 12, color: p.textSecondary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.surfaceElevated,
        contentTextStyle: TextStyle(color: p.textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.borderStrong),
        ),
      ),
    );
  }
}
