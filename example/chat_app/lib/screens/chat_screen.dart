import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';
import '../widgets/pruning_indicator.dart';
import '../widgets/runtime_status_panel.dart';
import '../widgets/welcome_view.dart';
import 'manage_models_screen.dart';

class ChatScreen extends StatefulWidget {
  final VoidCallback? onOpenModelSelection;
  final bool showModelSelectionAction;

  const ChatScreen({
    super.key,
    this.onOpenModelSelection,
    this.showModelSelectionAction = true,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _wasGenerating = false;
  bool _showScrollToBottom = false;
  bool _autoFollowScrollScheduled = false;
  ChatProvider? _providerForListener;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<ChatProvider>();
      _providerForListener = provider;
      provider.addListener(_onProviderUpdate);
    });
  }

  @override
  void dispose() {
    _providerForListener?.removeListener(_onProviderUpdate);
    _autoFollowScrollScheduled = false;
    _scrollController.removeListener(_onScrollChanged);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;

    final diff = _distanceFromBottom();
    final shouldShow = diff > 220;

    if (shouldShow != _showScrollToBottom && mounted) {
      setState(() {
        _showScrollToBottom = shouldShow;
      });
    }
  }

  void _onProviderUpdate() {
    if (!mounted) return;
    final provider = _providerForListener;
    if (provider == null) {
      return;
    }

    final shouldAutoFollowAfterGeneration = _distanceFromBottom() < 1200;

    if (provider.isGenerating) {
      _scheduleAutoFollowScroll();
    }

    if (_wasGenerating && !provider.isGenerating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        if (shouldAutoFollowAfterGeneration) {
          _scrollToBottom(force: true);
        }
        if (provider.isReady) {
          _focusNode.requestFocus();
        }
      });
    }
    _wasGenerating = provider.isGenerating;
  }

  void _scheduleAutoFollowScroll() {
    if (_autoFollowScrollScheduled) {
      return;
    }

    _autoFollowScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoFollowScrollScheduled = false;
      if (!mounted) {
        return;
      }
      _scrollToBottom();
    });
  }

  void _scrollToBottom({bool force = false}) {
    if (!_scrollController.hasClients) return;

    final pos = _scrollController.position;
    final diff = _distanceFromBottom();

    if (force || diff < 50) {
      _scrollController.jumpTo(pos.maxScrollExtent);
    } else if (diff < 500) {
      _scrollController.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    if (_showScrollToBottom) {
      setState(() {
        _showScrollToBottom = false;
      });
    }
  }

  double _distanceFromBottom() {
    if (!_scrollController.hasClients) {
      return 0;
    }

    final pos = _scrollController.position;
    final distance = pos.maxScrollExtent - pos.pixels;
    return distance < 0 ? 0 : distance;
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    final provider = context.read<ChatProvider>();
    if (text.isEmpty && provider.stagedParts.isEmpty) return;

    provider.sendMessage(text);
    _controller.value = TextEditingValue.empty;
    _focusNode.requestFocus();
  }

  void _openModelSelection() {
    final callback = widget.onOpenModelSelection;
    if (callback != null) {
      callback();
      return;
    }

    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const ManageModelsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: Stack(
        children: [
          Column(
            children: [
              const PruningIndicator(),
              const RuntimeStatusPanel(),
              Expanded(
                child: Consumer<ChatProvider>(
                  builder: (context, provider, _) {
                    if (provider.messages.isEmpty) {
                      return WelcomeView(
                        isInitializing: provider.isInitializing,
                        error: provider.error,
                        modelPath: provider.modelPath,
                        isLoaded: provider.isLoaded,
                        loadingProgress: provider.loadingProgress,
                        onRetry: () => provider.loadModel(),
                        onSelectModel: widget.showModelSelectionAction
                            ? _openModelSelection
                            : null,
                      );
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: provider.messages.length,
                      itemBuilder: (context, index) {
                        final message = provider.messages[index];
                        var isNextSame = false;
                        if (index + 1 < provider.messages.length) {
                          isNextSame =
                              provider.messages[index + 1].isUser ==
                              message.isUser;
                        }
                        final isStreamingMessage =
                            provider.isGenerating &&
                            !message.isUser &&
                            !message.isInfo &&
                            index == provider.messages.length - 1;
                        return MessageBubble(
                          message: message,
                          isNextSame: isNextSame,
                          isStreaming: isStreamingMessage,
                          onRegenerate:
                              index == provider.messages.length - 1 &&
                                  provider.canRegenerateLastResponse
                              ? () =>
                                    unawaited(provider.regenerateLastResponse())
                              : null,
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
          if (_showScrollToBottom)
            Positioned(
              right: 20,
              bottom: 100,
              child: FloatingActionButton.small(
                heroTag: 'scroll-to-bottom',
                onPressed: _scrollToBottom,
                tooltip: 'Jump to latest',
                child: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ),
        ],
      ),
    );
  }
}
