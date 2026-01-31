import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class SettingsIcon extends StatelessWidget {
  const SettingsIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final color = provider.isGenerating
            ? Colors.green
            : (provider.isReady ? Colors.blue : Colors.orange);

        return Stack(
          alignment: Alignment.topRight,
          children: [
            const Icon(Icons.tune_rounded),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
