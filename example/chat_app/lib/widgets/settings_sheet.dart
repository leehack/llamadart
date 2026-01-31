import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class SettingsSheet extends StatelessWidget {
  final VoidCallback onOpenModelSelection;

  const SettingsSheet({super.key, required this.onOpenModelSelection});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
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
                      onOpenModelSelection();
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              provider.modelPath?.split('/').last ?? 'None',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _buildSettingItem(
                  context,
                  title: 'Log Level',
                  subtitle: 'Controls llama.cpp verbosity',
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<LlamaLogLevel>(
                        value: provider.settings.logLevel,
                        isExpanded: true,
                        items: LlamaLogLevel.values.map((level) {
                          return DropdownMenuItem(
                            value: level,
                            child: Text(level.name.toUpperCase()),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            provider.updateLogLevel(value);
                          }
                        },
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<GpuBackend>(
                            value: provider.preferredBackend,
                            isExpanded: true,
                            items: _getAvailableBackends(provider).map((
                              backend,
                            ) {
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Active: ${provider.activeBackend}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Detected: ${provider.availableDevices.join(", ")}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.tertiary,
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
                    onChanged: (value) => provider.updateTemperature(value),
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
                          onChanged: (value) => provider.updateTopP(value),
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
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: provider.contextSize,
                        isExpanded: true,
                        items: [0, 2048, 4096, 8192, 16384].map((size) {
                          return DropdownMenuItem(
                            value: size,
                            child: Text(size == 0 ? "Auto (Native)" : "$size"),
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
  }

  Widget _buildSettingItem(
    BuildContext context, {
    required String title,
    String? subtitle,
    required Widget child,
  }) {
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

  List<GpuBackend> _getAvailableBackends(ChatProvider provider) {
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
