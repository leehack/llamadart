import 'dart:async';

import 'package:flutter/foundation.dart';
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
  final ValueChanged<String>? onOpenModelFilename;
  final bool showModelSelectionAction;

  const ChatScreen({
    super.key,
    this.onOpenModelSelection,
    this.onOpenModelFilename,
    this.showModelSelectionAction = true,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const double _pinToBottomThreshold = 48.0;
  static const double _showScrollButtonThreshold = 140.0;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _isPinnedToBottom = true;
  bool _wasGenerating = false;
  bool _showScrollToBottom = false;
  bool _autoFollowScrollScheduled = false;
  ChatProvider? _providerForListener;
  String? _lastConversationId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<ChatProvider>();
      _providerForListener = provider;
      _lastConversationId = provider.activeConversationId;
      provider.addListener(_onProviderUpdate);
      if (provider.messages.isNotEmpty) {
        _scrollToBottom(force: true);
      }
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
    final isNearBottom = diff <= _pinToBottomThreshold;
    if (isNearBottom != _isPinnedToBottom) {
      _isPinnedToBottom = isNearBottom;
    }

    final shouldShow = diff > _showScrollButtonThreshold;
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

    // Reset scroll state on conversation switch so the new thread starts at the bottom.
    final currentConversationId = provider.activeConversationId;
    if (currentConversationId != _lastConversationId) {
      _lastConversationId = currentConversationId;
      _isPinnedToBottom = true;
      if (_showScrollToBottom) {
        setState(() {
          _showScrollToBottom = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToBottom(force: true);
      });
      _wasGenerating = provider.isGenerating;
      return;
    }

    // Follow streaming ONLY if the user is pinned to the bottom.
    if (provider.isGenerating) {
      if (_isPinnedToBottom) {
        _scheduleAutoFollowScroll();
      }
    }

    // When generation completes, only jump if pinned to bottom.
    if (_wasGenerating && !provider.isGenerating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        if (_isPinnedToBottom) {
          _scrollToBottom(force: true);
          if (provider.isReady) {
            _focusNode.requestFocus();
          }
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
      if (!mounted || !_isPinnedToBottom) {
        return;
      }
      _scrollToBottom(force: true);
    });
  }

  void _scrollToBottom({bool force = false}) {
    if (!_scrollController.hasClients) return;

    final pos = _scrollController.position;
    final diff = _distanceFromBottom();

    if (force || diff < 50) {
      _scrollController.jumpTo(pos.maxScrollExtent);
      if (force) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_isPinnedToBottom || !_scrollController.hasClients) {
            return;
          }
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        });
      }
    } else if (diff < 500) {
      _scrollController.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    _isPinnedToBottom = true;
    if (_showScrollToBottom && mounted) {
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

    _isPinnedToBottom = true;
    provider.sendMessage(text);
    _controller.value = TextEditingValue.empty;
    _focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToBottom(force: true);
      }
    });
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

  void _openQuickStartModel(String filename) {
    final callback = widget.onOpenModelFilename;
    if (callback != null) {
      callback(filename);
      return;
    }
    _openModelSelection();
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
                    final messages = provider.messages;
                    if (messages.isEmpty) {
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
                        onQuickStartModel: widget.showModelSelectionAction
                            ? _openQuickStartModel
                            : null,
                      );
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        var isNextSame = false;
                        if (index + 1 < messages.length) {
                          isNextSame =
                              messages[index + 1].isUser == message.isUser;
                        }
                        final isStreamingMessage =
                            provider.isGenerating &&
                            !message.isUser &&
                            !message.isInfo &&
                            index == messages.length - 1;
                        return MessageBubble(
                          message: message,
                          isNextSame: isNextSame,
                          isStreaming: isStreamingMessage,
                          onRegenerate:
                              index == messages.length - 1 &&
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
                onPressed: () => _scrollToBottom(force: true),
                tooltip: 'Jump to latest',
                child: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  semanticLabel: kIsWeb ? null : 'Jump to latest',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
