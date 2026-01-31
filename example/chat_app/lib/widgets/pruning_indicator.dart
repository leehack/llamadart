import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class PruningIndicator extends StatelessWidget {
  const PruningIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<ChatProvider, bool>(
      selector: (_, provider) => provider.isPruning,
      builder: (context, isPruning, child) {
        if (!isPruning) return const SizedBox.shrink();
        return child!;
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 4),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Text(
          'Conversation history pruned to fit context size',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onErrorContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
