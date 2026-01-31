import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class ChatAppBarTitle extends StatelessWidget {
  const ChatAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.auto_awesome,
            color: Theme.of(context).colorScheme.primary,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Llama Chat',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
            const _ContextIndicator(),
          ],
        ),
      ],
    );
  }
}

class _ContextIndicator extends StatelessWidget {
  const _ContextIndicator();

  @override
  Widget build(BuildContext context) {
    return Selector<ChatProvider, (bool, int, int)>(
      selector: (_, p) => (p.isReady, p.currentTokens, p.maxTokens),
      builder: (context, data, _) {
        final (isReady, currentTokens, maxTokens) = data;
        if (!isReady) return const SizedBox.shrink();

        final percent = maxTokens > 0 ? (currentTokens / maxTokens) : 0.0;
        final color = percent > 0.9
            ? Colors.red
            : (percent > 0.7 ? Colors.orange : Colors.green);

        return Text(
          'Context: $currentTokens / $maxTokens tokens',
          style: TextStyle(
            fontSize: 10,
            color: color.withValues(alpha: 0.7),
            fontWeight: FontWeight.bold,
          ),
        );
      },
    );
  }
}
