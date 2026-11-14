import 'dart:convert';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../mcp_skills/mcp_and_skills_sheet.dart';
import '../store_widgets.dart';
import '../studio_motion.dart';

part 'inspector_advanced_engine.dart';
part 'inspector_hardware_tab.dart';
part 'inspector_tabs_secondary.dart';

/// Collapsible 4-tab Session Inspector (`Hardware`, `Prompt`, `Sampling`,
/// `Tools`) exposing full `llamadart` runtime capabilities.
class SessionInspectorPanel extends StatefulWidget {
  /// Creates a [SessionInspectorPanel].
  const SessionInspectorPanel({super.key, this.onClose});

  /// Optional callback invoked when the close icon is tapped.
  final VoidCallback? onClose;

  @override
  State<SessionInspectorPanel> createState() => _SessionInspectorPanelState();
}

class _SessionInspectorPanelState extends State<SessionInspectorPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _systemPromptController = TextEditingController();
  final TextEditingController _jsonSchemaController = TextEditingController();
  final TextEditingController _customToolsController = TextEditingController();
  final TextEditingController _ropeBaseController = TextEditingController();
  final TextEditingController _ropeScaleController = TextEditingController();
  String? _syncedConversationId;
  String? _syncedSystemPrompt;
  String? _syncedJsonSchema;
  String? _syncedCustomToolsSource;
  double? _syncedRopeBase;
  double? _syncedRopeScale;
  bool _ropeControllersInitialized = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _systemPromptController.dispose();
    _jsonSchemaController.dispose();
    _customToolsController.dispose();
    _ropeBaseController.dispose();
    _ropeScaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final deps = StudioScope.of(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.sidebar,
        border: Border(left: BorderSide(color: palette.borderSubtle)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
              child: Row(
                children: <Widget>[
                  Icon(Icons.tune_rounded, size: 17, color: palette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session Inspector',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: 'Close Inspector',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: palette.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: palette.borderSubtle,
              labelStyle: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
              tabs: const <Widget>[
                Tab(text: 'Hardware'),
                Tab(text: 'Prompt'),
                Tab(text: 'Sampling'),
                Tab(text: 'Tools'),
              ],
            ),
            Expanded(
              child: StoreBuilder<StudioShellState>(
                store: deps.shellController.store,
                builder: (BuildContext context, StudioShellState shellState) {
                  return StoreBuilder<StudioRuntimeSnapshot>(
                    store: deps.modelHubController.runtimeStore,
                    builder:
                        (
                          BuildContext context,
                          StudioRuntimeSnapshot runtimeSnapshot,
                        ) {
                          return StoreBuilder<ChatWorkspaceState>(
                            store: deps.chatController.store,
                            builder:
                                (
                                  BuildContext context,
                                  ChatWorkspaceState chatState,
                                ) {
                                  _syncTextControllers(
                                    chatState.activeConversation,
                                    shellState.settings,
                                  );
                                  return TabBarView(
                                    controller: _tabController,
                                    children: <Widget>[
                                      _buildHardwareTab(
                                        context,
                                        deps,
                                        shellState.settings,
                                        runtimeSnapshot,
                                      ),
                                      _buildPromptTab(
                                        context,
                                        deps,
                                        shellState.settings,
                                        chatState.activeConversation,
                                      ),
                                      _buildSamplingTab(
                                        context,
                                        deps,
                                        shellState.settings,
                                      ),
                                      _buildToolsTab(
                                        context,
                                        deps,
                                        shellState.settings,
                                      ),
                                    ],
                                  );
                                },
                          );
                        },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _syncTextControllers(
    StudioConversation? activeConv,
    StudioSettings settings,
  ) {
    if (activeConv != null) {
      final conversationChanged = _syncedConversationId != activeConv.id;
      if ((conversationChanged ||
              _syncedSystemPrompt != activeConv.systemPrompt) &&
          _systemPromptController.text != activeConv.systemPrompt) {
        _systemPromptController.text = activeConv.systemPrompt;
      }
      final schema = activeConv.jsonSchema ?? '';
      if ((conversationChanged || _syncedJsonSchema != schema) &&
          _jsonSchemaController.text.trim() != schema) {
        _jsonSchemaController.text = schema;
      }
      _syncedConversationId = activeConv.id;
      _syncedSystemPrompt = activeConv.systemPrompt;
      _syncedJsonSchema = schema;
    }
    if (_syncedCustomToolsSource != settings.customToolDeclarationsJson) {
      _syncedCustomToolsSource = settings.customToolDeclarationsJson;
      if (_customToolsController.text != settings.customToolDeclarationsJson) {
        _customToolsController.text = settings.customToolDeclarationsJson;
      }
    }
    if (!_ropeControllersInitialized ||
        _syncedRopeBase != settings.ropeFrequencyBase) {
      _syncedRopeBase = settings.ropeFrequencyBase;
      final currentParsed = double.tryParse(_ropeBaseController.text.trim());
      if (currentParsed != settings.ropeFrequencyBase) {
        _ropeBaseController.text = settings.ropeFrequencyBase?.toString() ?? '';
      }
    }
    if (!_ropeControllersInitialized ||
        _syncedRopeScale != settings.ropeFrequencyScale) {
      _syncedRopeScale = settings.ropeFrequencyScale;
      final currentParsed = double.tryParse(_ropeScaleController.text.trim());
      if (currentParsed != settings.ropeFrequencyScale) {
        _ropeScaleController.text =
            settings.ropeFrequencyScale?.toString() ?? '';
      }
    }
    _ropeControllersInitialized = true;
  }

  void _updateState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }
}

String _formatGiB(int bytes) {
  final gib = bytes / (1024 * 1024 * 1024);
  return '${gib.toStringAsFixed(1)} GB';
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        letterSpacing: 0.7,
        fontWeight: FontWeight.w700,
        color: palette.textMuted,
      ),
    );
  }
}

class _SliderControl extends StatelessWidget {
  const _SliderControl({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                valueLabel,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
