import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'models/chat_model.dart';
import 'screens/model_selection_screen.dart';
import 'package:llamadart/llamadart.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Auto-scrolling and generation status listener
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ChatProvider>();

      // Auto-open model selection if no model is selected
      if (provider.modelPath == null) {
        _openModelSelection();
      }

      // Add listener for auto-scrolling
      provider.addListener(_onProviderUpdate);
    });
  }

  bool _wasGenerating = false;

  void _onProviderUpdate() {
    final provider = context.read<ChatProvider>();

    // Auto-scroll while generating
    if (provider.isGenerating) {
      _scrollToBottom();
    }

    // Restore focus when generation finishes
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

      // If we are already at the bottom (or very close), auto-follow
      if (diff < 50) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      } else if (diff < 500) {
        // If we are somewhat close, animate smoothly
        _scrollController.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
      // If diff >= 500, user is likely reading history, so don't snap them down
    }
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    context.read<ChatProvider>().sendMessage(text);
    _controller.clear();
    _focusNode.requestFocus(); // Keep focus

    // Scroll to bottom
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
      MaterialPageRoute(
        builder: (context) => const ModelSelectionScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      body: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Column(
          children: [
            if (context.watch<ChatProvider>().isPruning)
              Container(
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
            Expanded(
              child: Consumer<ChatProvider>(
                builder: (context, provider, _) {
                  if (provider.messages.isEmpty) {
                    return _buildWelcomeScreen(provider);
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 120, 16, 24),
                    itemCount: provider.messages.length,
                    itemBuilder: (context, index) {
                      final message = provider.messages[index];
                      // Check if next message is from same user for grouping
                      bool isNextSame = false;
                      if (index + 1 < provider.messages.length) {
                        isNextSame = provider.messages[index + 1].isUser ==
                            message.isUser;
                      }
                      return _buildMessageBubble(message, isNextSame);
                    },
                  );
                },
              ),
            ),
            _buildInputArea(context),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor:
          Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(color: Colors.transparent),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
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
              Consumer<ChatProvider>(
                builder: (context, provider, _) {
                  if (!provider.isReady) return const SizedBox.shrink();
                  final percent = provider.maxTokens > 0
                      ? (provider.currentTokens / provider.maxTokens)
                      : 0.0;
                  final color = percent > 0.9
                      ? Colors.red
                      : (percent > 0.7 ? Colors.orange : Colors.green);

                  return Text(
                    'Context: ${provider.currentTokens} / ${provider.maxTokens} tokens',
                    style: TextStyle(
                      fontSize: 10,
                      color: color.withValues(alpha: 0.7),
                      fontWeight: FontWeight.bold,
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
      actions: [
        Consumer<ChatProvider>(
          builder: (context, provider, _) {
            if (provider.messages.isEmpty) return const SizedBox.shrink();
            return IconButton(
              onPressed: () => provider.clearConversation(),
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Clear Chat',
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7),
            );
          },
        ),
        Consumer<ChatProvider>(
          builder: (context, provider, _) {
            // Status dot
            final color = provider.isGenerating
                ? Colors.green
                : (provider.isReady ? Colors.blue : Colors.orange);

            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: IconButton(
                onPressed: () => _showModelSettings(context),
                icon: Stack(
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
                ),
                tooltip: 'Settings',
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildWelcomeScreen(ChatProvider provider) {
    if (provider.isInitializing) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Loading Model...',
              style: GoogleFonts.outfit(
                fontSize: 18,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ),
      );
    }

    if (provider.error != null) {
      return Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .errorContainer
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.2),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_rounded,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Something went wrong',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                provider.error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  if (provider.isInitializing) return; // Added this line
                  provider.loadModel();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Empty State
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Start a conversation',
            style: GoogleFonts.outfit(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            provider.modelPath != null
                ? (provider.isLoaded
                    ? 'Model Loaded: ${provider.modelPath!.split('/').last}'
                    : 'Model Selected: ${provider.modelPath!.split('/').last}')
                : 'No model selected',
            style: TextStyle(
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 32),
          if (!provider.isLoaded)
            FilledButton.icon(
              onPressed: provider.modelPath == null
                  ? _openModelSelection
                  : () => provider.loadModel(),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
              icon: Icon(provider.modelPath == null
                  ? Icons.file_open_rounded
                  : Icons.power_settings_new_rounded),
              label: Text(
                  provider.modelPath == null ? 'Select Model' : 'Load Model'),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, bool isNextSame) {
    final isUser = message.isUser;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondaryContainer;
    final textColor = isUser
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSecondaryContainer;

    const borderRadius = 20.0;
    final border = BorderRadius.only(
      topLeft: const Radius.circular(borderRadius),
      topRight: const Radius.circular(borderRadius),
      bottomLeft: Radius.circular(isUser ? borderRadius : 4),
      bottomRight: Radius.circular(isUser ? 4 : borderRadius),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: isNextSame ? 4 : 12),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                _buildAvatar(isUser),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: border,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              if (isUser) ...[
                const SizedBox(width: 8),
                _buildAvatar(isUser),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(bool isUser) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isUser
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          isUser ? Icons.person_rounded : Icons.auto_awesome,
          size: 16,
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }

  Widget _buildInputArea(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final isGenerating = provider.isGenerating;
        final enabled = !isGenerating && provider.isReady;

        return Container(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.transparent,
                    ),
                  ),
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter,
                          includeRepeats: false): _sendMessage,
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: enabled,
                      maxLines: 6, // Increased max lines for better UX
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                      ),
                      // onSubmitted: Removed because we handle Enter manually
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: enabled
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: isGenerating
                      ? () => provider.stopGeneration()
                      : (enabled ? _sendMessage : null),
                  icon: isGenerating
                      ? Icon(
                          Icons.stop_rounded,
                          color: Theme.of(context).colorScheme.error,
                        )
                      : Icon(
                          Icons.arrow_upward_rounded,
                          color: enabled
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- settings modal implementation mostly same but better styled ---
  void _showModelSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Consumer<ChatProvider>(
          builder: (context, provider, _) {
            return StatefulBuilder(
              builder: (context, setModalState) {
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                    left: 24,
                    right: 24,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Settings',
                              style: GoogleFonts.outfit(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close_rounded),
                              style: IconButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _buildSettingItem(
                          context,
                          title: 'Model',
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(context);
                              _openModelSelection();
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.description_outlined,
                                      size: 20,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      provider.modelPath?.split('/').last ??
                                          'None',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Icon(Icons.chevron_right,
                                      size: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildSettingItem(
                          context,
                          title: 'Preferred Backend',
                          subtitle: 'Forces a specific driver if available',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: double.infinity,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<GpuBackend>(
                                    value: provider.preferredBackend,
                                    isExpanded: true,
                                    items:
                                        _getAvailableBackends().map((backend) {
                                      return DropdownMenuItem(
                                        value: backend,
                                        child: Text(backend.name.toUpperCase()),
                                      );
                                    }).toList(),
                                    onChanged: (value) {
                                      if (value != null) {
                                        provider.updatePreferredBackend(value);
                                      }
                                    },
                                  ),
                                ),
                              ),
                              if (provider.availableDevices.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Active: ${provider.activeBackend}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Detected: ${provider.availableDevices.join(", ")}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .tertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildSettingItem(
                          context,
                          title: 'Temperature',
                          subtitle: provider.temperature.toStringAsFixed(2),
                          child: Slider(
                            value: provider.temperature,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            onChanged: (value) =>
                                provider.updateTemperature(value),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSettingItem(
                                context,
                                title: 'Top-K',
                                subtitle: provider.topK.toString(),
                                child: Slider(
                                  value: provider.topK.toDouble(),
                                  min: 1,
                                  max: 100,
                                  divisions: 100,
                                  onChanged: (value) =>
                                      provider.updateTopK(value.toInt()),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildSettingItem(
                                context,
                                title: 'Top-P',
                                subtitle: provider.topP.toStringAsFixed(2),
                                child: Slider(
                                  value: provider.topP,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 20,
                                  onChanged: (value) =>
                                      provider.updateTopP(value),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _buildSettingItem(
                          context,
                          title: 'Context Size',
                          subtitle: provider.contextSize == 0
                              ? 'Auto'
                              : provider.contextSize.toString(),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: provider.contextSize,
                                isExpanded: true,
                                items: [0, 2048, 4096, 8192, 16384].map((size) {
                                  return DropdownMenuItem(
                                    value: size,
                                    child: Text(
                                        size == 0 ? "Auto (Native)" : "$size"),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    provider.updateContextSize(value);
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSettingItem(BuildContext context,
      {required String title, String? subtitle, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            if (subtitle != null)
              Flexible(
                child: Text(
                  subtitle,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  List<GpuBackend> _getAvailableBackends() {
    final provider = context.read<ChatProvider>();
    final Set<GpuBackend> backends = {GpuBackend.auto, GpuBackend.cpu};

    for (final device in provider.availableDevices) {
      final d = device.toLowerCase();
      if (d.contains('metal')) backends.add(GpuBackend.metal);
      if (d.contains('vulkan')) backends.add(GpuBackend.vulkan);
      if (d.contains('blas')) backends.add(GpuBackend.blas);
    }

    return backends.toList();
  }
}
