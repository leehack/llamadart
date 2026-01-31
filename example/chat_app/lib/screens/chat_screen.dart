import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import 'model_selection_screen.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/welcome_view.dart';
import '../widgets/chat_app_bar_title.dart';
import '../widgets/pruning_indicator.dart';
import '../widgets/clear_chat_button.dart';
import '../widgets/settings_icon.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  bool _wasGenerating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ChatProvider>();
      if (provider.modelPath == null) {
        _openModelSelection();
      }
      provider.addListener(_onProviderUpdate);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onProviderUpdate() {
    if (!mounted) return;
    final provider = context.read<ChatProvider>();

    if (provider.isGenerating) {
      _scrollToBottom();
    }

    if (_wasGenerating && !provider.isGenerating && provider.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
    _wasGenerating = provider.isGenerating;
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      final diff = pos.maxScrollExtent - pos.pixels;

      if (diff < 50) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      } else if (diff < 500) {
        _scrollController.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    context.read<ChatProvider>().sendMessage(text);
    _controller.clear();
    _focusNode.requestFocus();

    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _openModelSelection() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const ModelSelectionScreen()),
    );
  }

  void _showModelSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) =>
          SettingsSheet(onOpenModelSelection: _openModelSelection),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
        child: Column(
          children: [
            const PruningIndicator(),
            Expanded(
              child: Consumer<ChatProvider>(
                builder: (context, provider, _) {
                  if (provider.messages.isEmpty) {
                    return WelcomeView(
                      isInitializing: provider.isInitializing,
                      error: provider.error,
                      modelPath: provider.modelPath,
                      isLoaded: provider.isLoaded,
                      onRetry: () => provider.loadModel(),
                      onSelectModel: _openModelSelection,
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 120, 16, 24),
                    itemCount: provider.messages.length,
                    itemBuilder: (context, index) {
                      final message = provider.messages[index];
                      bool isNextSame = false;
                      if (index + 1 < provider.messages.length) {
                        isNextSame =
                            provider.messages[index + 1].isUser ==
                            message.isUser;
                      }
                      return MessageBubble(
                        message: message,
                        isNextSame: isNextSame,
                      );
                    },
                  );
                },
              ),
            ),
            ChatInput(
              onSend: _sendMessage,
              controller: _controller,
              focusNode: _focusNode,
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: Theme.of(
        context,
      ).colorScheme.surface.withValues(alpha: 0.8),
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(color: Colors.transparent),
        ),
      ),
      title: const ChatAppBarTitle(),
      actions: [
        const ClearChatButton(),
        IconButton(
          onPressed: _showModelSettings,
          icon: const SettingsIcon(),
          tooltip: 'Settings',
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}
