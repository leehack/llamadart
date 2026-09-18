import 'dart:convert';

import 'package:flutter/material.dart';

import '../providers/chat_provider.dart';
import '../services/tool_declaration_service.dart';

const ToolDeclarationService _toolDeclarationService = ToolDeclarationService();

enum _ToolDeclarationEditorMode { code, visual }

Future<void> showToolDeclarationsDialog(
  BuildContext context,
  ChatProvider provider,
) async {
  final normalizedDeclarations = provider.toolDeclarations.trim();
  final initialCode =
      (normalizedDeclarations.isEmpty || normalizedDeclarations == '[]')
      ? _prettyJson(provider.defaultToolDeclarations)
      : _prettyJson(provider.toolDeclarations);
  final codeController = TextEditingController(text: initialCode);
  var mode = _ToolDeclarationEditorMode.code;
  var errorText = provider.toolDeclarationsError;
  final visualTools = <_EditableToolDeclaration>[];
  final allToolEditors = <_EditableToolDeclaration>[];

  void replaceVisualTools(List<_EditableToolDeclaration> nextTools) {
    visualTools
      ..clear()
      ..addAll(nextTools);
    allToolEditors.addAll(nextTools);
  }

  void loadVisualFromCode(void Function(void Function()) setState) {
    try {
      final next = _parseEditableToolDeclarations(codeController.text);
      replaceVisualTools(next);
      errorText = null;
      mode = _ToolDeclarationEditorMode.visual;
      setState(() {});
    } catch (e) {
      errorText = _toolDeclarationService.formatError(
        e,
        fallback: 'Function declarations are invalid.',
      );
      setState(() {});
    }
  }

  void loadCodeFromVisual(void Function(void Function()) setState) {
    try {
      codeController.text = _serializeEditableToolDeclarations(visualTools);
      errorText = null;
      mode = _ToolDeclarationEditorMode.code;
      setState(() {});
    } catch (e) {
      errorText = _toolDeclarationService.formatError(
        e,
        fallback: 'Function declarations are invalid.',
      );
      setState(() {});
    }
  }

  try {
    final initialVisualTools = _parseEditableToolDeclarations(
      codeController.text,
    );
    visualTools.addAll(initialVisualTools);
    allToolEditors.addAll(initialVisualTools);
  } on FormatException {
    // Keep visual list empty until the code content becomes valid JSON.
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      return StatefulBuilder(
        builder: (context, setState) {
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840, maxHeight: 760),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Function declarations',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      'Enter the function declarations the model can call. '
                      'Only the built-in getWeather demo runs locally, and it '
                      'returns simulated data; any other declared name returns '
                      'an error result to the model.',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Code Editor'),
                          selected: mode == _ToolDeclarationEditorMode.code,
                          onSelected: (_) {
                            if (mode == _ToolDeclarationEditorMode.visual) {
                              loadCodeFromVisual(setState);
                              return;
                            }
                            mode = _ToolDeclarationEditorMode.code;
                            setState(() {});
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Visual Editor'),
                          selected: mode == _ToolDeclarationEditorMode.visual,
                          onSelected: (_) {
                            if (mode == _ToolDeclarationEditorMode.code) {
                              loadVisualFromCode(setState);
                              return;
                            }
                            mode = _ToolDeclarationEditorMode.visual;
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colorScheme.outlineVariant),
                        ),
                        child: mode == _ToolDeclarationEditorMode.code
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: TextField(
                                  controller: codeController,
                                  expands: true,
                                  maxLines: null,
                                  minLines: null,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    hintText:
                                        'Paste JSON tool declarations here...',
                                  ),
                                ),
                              )
                            : _VisualToolDeclarationsEditor(
                                tools: visualTools,
                                onAdd: () {
                                  final editor =
                                      _EditableToolDeclaration.empty();
                                  visualTools.add(editor);
                                  allToolEditors.add(editor);
                                  setState(() {});
                                },
                                onRemove: (index) {
                                  visualTools.removeAt(index);
                                  setState(() {});
                                },
                              ),
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText!,
                        style: TextStyle(
                          color: colorScheme.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            final resetValue = _prettyJson(
                              provider.defaultToolDeclarations,
                            );
                            codeController.text = resetValue;
                            try {
                              final next = _parseEditableToolDeclarations(
                                resetValue,
                              );
                              replaceVisualTools(next);
                              errorText = null;
                            } on FormatException catch (e) {
                              errorText = e.message;
                            }
                            setState(() {});
                          },
                          child: const Text('Reset'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            String valueToSave;
                            try {
                              valueToSave =
                                  mode == _ToolDeclarationEditorMode.code
                                  ? codeController.text
                                  : _serializeEditableToolDeclarations(
                                      visualTools,
                                    );
                            } catch (e) {
                              errorText = _toolDeclarationService.formatError(
                                e,
                                fallback: 'Function declarations are invalid.',
                              );
                              setState(() {});
                              return;
                            }

                            final success = provider.updateToolDeclarations(
                              valueToSave,
                            );
                            if (!success) {
                              errorText = provider.toolDeclarationsError;
                              setState(() {});
                              return;
                            }

                            Navigator.of(dialogContext).pop();
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );

  codeController.dispose();
  for (final item in allToolEditors) {
    item.dispose();
  }
}

class _VisualToolDeclarationsEditor extends StatelessWidget {
  final List<_EditableToolDeclaration> tools;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _VisualToolDeclarationsEditor({
    required this.tools,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Text(
                'Functions',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tools.isEmpty
              ? const Center(
                  child: Text(
                    'No function declarations yet.\nAdd one or switch to Code Editor.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: tools.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final tool = tools[index];
                    return Container(
                      key: ValueKey<int>(tool.id),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Text(
                                'Function ${index + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Remove',
                                onPressed: () => onRemove(index),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: tool.nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: tool.descriptionController,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: tool.parametersController,
                            minLines: 5,
                            maxLines: 10,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Parameters JSON Schema',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EditableToolDeclaration {
  static int _nextId = 1;

  final int id;
  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final TextEditingController parametersController;

  _EditableToolDeclaration({
    required String name,
    required String description,
    required String parametersJson,
  }) : id = _nextId++,
       nameController = TextEditingController(text: name),
       descriptionController = TextEditingController(text: description),
       parametersController = TextEditingController(text: parametersJson);

  factory _EditableToolDeclaration.empty() {
    return _EditableToolDeclaration(
      name: '',
      description: '',
      parametersJson: _prettyJson(
        jsonEncode(const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        }),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      throw const FormatException('Each function must have a non-empty name.');
    }

    Object decoded;
    try {
      decoded = jsonDecode(parametersController.text);
    } catch (_) {
      throw FormatException('Function `$name` has invalid parameters JSON.');
    }

    if (decoded is! Map) {
      throw FormatException(
        'Function `$name` parameters must be a JSON object.',
      );
    }

    return <String, dynamic>{
      'name': name,
      'description': descriptionController.text.trim(),
      'parameters': Map<String, dynamic>.from(decoded),
    };
  }

  void dispose() {
    nameController.dispose();
    descriptionController.dispose();
    parametersController.dispose();
  }
}

String _prettyJson(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return rawJson;
  }
}

List<_EditableToolDeclaration> _parseEditableToolDeclarations(String rawJson) {
  Object decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (_) {
    throw const FormatException('Function declarations must be valid JSON.');
  }

  if (decoded is! List) {
    throw const FormatException('Function declarations must be a JSON array.');
  }

  final result = <_EditableToolDeclaration>[];
  for (var i = 0; i < decoded.length; i++) {
    final entry = decoded[i];
    if (entry is! Map) {
      throw FormatException('Function #${i + 1} must be an object.');
    }

    final raw = Map<String, dynamic>.from(entry);
    final functionRaw = raw['function'];
    final functionMap = functionRaw is Map
        ? Map<String, dynamic>.from(functionRaw)
        : raw;

    final name = (functionMap['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      throw FormatException(
        'Function #${i + 1} name must be a non-empty string.',
      );
    }

    final descriptionValue = functionMap['description'];
    if (descriptionValue != null && descriptionValue is! String) {
      throw FormatException('Function #${i + 1} description must be a string.');
    }

    final rawParameters = functionMap['parameters'];
    final parameters = rawParameters == null
        ? <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}}
        : rawParameters is Map
        ? Map<String, dynamic>.from(rawParameters)
        : throw FormatException(
            'Function #${i + 1} parameters must be a JSON object.',
          );

    result.add(
      _EditableToolDeclaration(
        name: name,
        description: descriptionValue as String? ?? '',
        parametersJson: _prettyJson(jsonEncode(parameters)),
      ),
    );
  }
  return result;
}

String _serializeEditableToolDeclarations(
  List<_EditableToolDeclaration> tools,
) {
  final payload = tools.map((tool) => tool.toJson()).toList(growable: false);
  return const JsonEncoder.withIndent('  ').convert(payload);
}
