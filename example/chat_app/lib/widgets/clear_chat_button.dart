import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class ClearChatButton extends StatelessWidget {
  const ClearChatButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        if (provider.messages.isEmpty) return const SizedBox.shrink();
        return IconButton(
          onPressed: () => provider.clearConversation(),
          icon: const Icon(Icons.delete_sweep_rounded),
          tooltip: 'Clear Chat',
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7),
        );
      },
    );
  }
}
