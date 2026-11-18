// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../app/studio_theme.dart';

/// Keeps model-specific tool limits separate from the assistant's response.
class ToolAvailabilityNoticeCard extends StatelessWidget {
  /// Creates a compatibility notice for the current turn.
  const ToolAvailabilityNoticeCard({
    super.key,
    required this.notices,
    required this.onChooseModel,
  });

  /// Unavailable tools and tools restricted to supported inputs.
  final List<StudioToolAvailabilityNotice> notices;

  /// Opens the existing model selection flow.
  final VoidCallback onChooseModel;

  @override
  Widget build(BuildContext context) {
    if (notices.isEmpty) return const SizedBox.shrink();
    final palette = StudioPalette.of(context);
    final unavailable = notices.where((notice) => notice.isUnavailable).length;
    final restricted = notices.length - unavailable;
    final summary = <String>[
      if (unavailable > 0) '$unavailable unavailable',
      if (restricted > 0) '$restricted with limited inputs',
    ].join(' · ');

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const Key('tool_availability_notice_card'),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: palette.amber.withValues(alpha: .08),
          border: Border.all(color: palette.amber.withValues(alpha: .35)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(Icons.info_outline_rounded, color: palette.amber),
          title: const Text('Tool availability for this turn'),
          subtitle: Text(summary),
          children: <Widget>[
            for (final notice in notices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${notice.toolName} · ${notice.isUnavailable ? 'Unavailable' : 'Limited inputs'}',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notice.reason,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('tool_availability_choose_model'),
                onPressed: onChooseModel,
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: const Text('Choose model'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
