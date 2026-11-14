// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../app/studio_theme.dart';

/// Animates [child] with a subtle upward slide and opacity fade on mount,
/// automatically respecting `MediaQuery.disableAnimationsOf(context)`.
class FadeSlideEntry extends StatelessWidget {
  /// Creates a [FadeSlideEntry].
  const FadeSlideEntry({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
    this.offsetY = 10,
  });

  /// Content widget to reveal.
  final Widget child;

  /// Entrance transition duration.
  final Duration duration;

  /// Initial vertical displacement in logical pixels.
  final double offsetY;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (BuildContext context, double t, Widget? inner) {
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * offsetY),
            child: inner,
          ),
        );
      },
    );
  }
}

/// Crisp status indicator dot with an optional subtle breathing halo when
/// [pulsing] is `true`.
class StatusPulseDot extends StatefulWidget {
  /// Creates a [StatusPulseDot].
  const StatusPulseDot({
    super.key,
    required this.color,
    this.pulsing = false,
    this.size = 8,
  });

  /// Core dot color.
  final Color color;

  /// Whether to animate a breathing ring around the dot.
  final bool pulsing;

  /// Diameter of the inner dot in logical pixels.
  final double size;

  @override
  State<StatusPulseDot> createState() => _StatusPulseDotState();
}

class _StatusPulseDotState extends State<StatusPulseDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant StatusPulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (widget.pulsing && !disableAnimations) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      );
      if (!_controller!.isAnimating) {
        _controller!.repeat(reverse: true);
      }
    } else {
      _controller?.stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!widget.pulsing || controller == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        final haloAlpha = (0.14 + (0.28 * controller.value)).clamp(0.0, 1.0);
        return Container(
          width: widget.size + 6,
          height: widget.size + 6,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: haloAlpha),
          ),
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// Blinking inline accent caret rendered at the tail of streaming output.
class StreamingCursor extends StatefulWidget {
  /// Creates a [StreamingCursor].
  const StreamingCursor({super.key});

  @override
  State<StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<StreamingCursor>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.disableAnimationsOf(context)) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 520),
      )..repeat(reverse: true);
    } else {
      _controller?.stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final controller = _controller;
    final bar = Container(
      width: 7,
      height: 15,
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: palette.accent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    if (controller == null) {
      return bar;
    }
    return FadeTransition(opacity: controller, child: bar);
  }
}

/// Smoothly animated horizontal progress or score bar.
class AnimatedScoreBar extends StatelessWidget {
  /// Creates an [AnimatedScoreBar].
  const AnimatedScoreBar({
    super.key,
    required this.fraction,
    this.color,
    this.height = 7,
  });

  /// Normalized fill ratio (`0.0 .. 1.0`).
  final double fraction;

  /// Optional fill color (defaults to [StudioPalette.accent]).
  final Color? color;

  /// Bar height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final fillColor = color ?? palette.accent;
    final clamped = fraction.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: palette.borderSubtle.withValues(alpha: 0.65),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: clamped),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double value, _) {
            return FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact technical pill badge used for capability tags, fit status, and
/// telemetry readouts.
class StudioPillBadge extends StatelessWidget {
  /// Creates a [StudioPillBadge].
  const StudioPillBadge({
    super.key,
    required this.label,
    this.icon,
    this.foreground,
    this.background,
    this.borderColor,
    this.monospace = false,
  });

  /// Badge text.
  final String label;

  /// Optional leading icon.
  final IconData? icon;

  /// Foreground text/icon color.
  final Color? foreground;

  /// Pill fill color.
  final Color? background;

  /// Optional hairline border color.
  final Color? borderColor;

  /// Whether to render [label] with the Studio monospace font stack.
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final fg = foreground ?? palette.textSecondary;
    final bg = background ?? palette.surfaceElevated;
    final border = borderColor ?? palette.borderSubtle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fg,
                fontFamilyFallback: monospace
                    ? StudioTheme.monoFontFallback
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Official `llamadart` **LD** vector brand badge matching the native Studio
/// app icon across macOS, iOS, Android, Web, and Windows.
class LlamadartBrandMark extends StatelessWidget {
  /// Creates a [LlamadartBrandMark] of square [size].
  const LlamadartBrandMark({super.key, this.size = 28});

  /// Logical width and height of the rounded brand tile.
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.25;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF111A2E), Color(0xFF090D16)],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: const Color(0xFF94A3B8).withValues(alpha: 0.24),
        ),
      ),
      child: CustomPaint(painter: const _LlamadartMarkPainter()),
    );
  }
}

class _LlamadartMarkPainter extends CustomPainter {
  const _LlamadartMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.shortestSide / 240.0) * 0.84;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale, scale);
    canvas.translate(-135, -120);

    final lPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF60A5FA), Color(0xFF2563EB)],
      ).createShader(const Rect.fromLTWH(50, 40, 90, 160));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(50, 40, 35, 160),
        const Radius.circular(12),
      ),
      lPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(50, 165, 90, 35),
        const Radius.circular(12),
      ),
      lPaint,
    );

    final dPath = Path()
      ..moveTo(120, 40)
      ..lineTo(140, 40)
      ..arcTo(
        const Rect.fromLTWH(60, 40, 160, 160),
        -1.5707963267948966,
        3.141592653589793,
        false,
      )
      ..lineTo(120, 200)
      ..lineTo(120, 165)
      ..lineTo(140, 165)
      ..arcTo(
        const Rect.fromLTWH(95, 75, 90, 90),
        1.5707963267948966,
        -3.141592653589793,
        false,
      )
      ..lineTo(120, 75)
      ..close();

    final dPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFF67E8F9), Color(0xFF0284C7)],
      ).createShader(const Rect.fromLTWH(120, 40, 100, 160));

    canvas.drawPath(dPath, dPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LlamadartMarkPainter oldDelegate) => false;
}
