import 'dart:convert';

import 'package:flutter/material.dart';

import 'validation/controller.dart';

void main() => runApp(const ValidationApp());

/// Small interactive entry point for the shared cross-platform test suite.
class ValidationApp extends StatefulWidget {
  /// Creates the QA app independently of the normal chat application.
  const ValidationApp({super.key});

  @override
  State<ValidationApp> createState() => _ValidationAppState();
}

class _ValidationAppState extends State<ValidationApp> {
  final _controller = ValidationController();
  static const _compiledProfile = String.fromEnvironment(
    'VALIDATION_PROFILE',
    defaultValue: 'tiny-gguf-cpu',
  );
  static const _executionPath = String.fromEnvironment(
    'VALIDATION_EXECUTION_PATH',
    defaultValue: 'public_api',
  );
  String _profile = _compiledProfile;
  @override
  void dispose() {
    _controller.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'llamadart validation',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff247a87),
      useMaterial3: true,
    ),
    home: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('llamadart validation')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Run the same package checks on this device.',
                  style: TextStyle(fontSize: 22),
                ),
                const SizedBox(height: 16),
                Text(
                  _executionPath == 'native_c_api'
                      ? 'Direct native control · does not qualify the public Dart path'
                      : 'llamadart public API',
                ),
                DropdownButtonFormField<String>(
                  initialValue: _profile,
                  decoration: const InputDecoration(
                    labelText: 'Model / backend profile',
                  ),
                  items: [
                    for (final id
                        in _compiledProfile.startsWith('npu-')
                            ? [_compiledProfile]
                            : const [
                                'tiny-gguf-cpu',
                                'tiny-gguf-metal',
                                'tiny-gguf-vulkan',
                                'tiny-gguf-cuda',
                                'chat-gguf-cpu',
                                'chat-gguf-metal',
                                'chat-gguf-vulkan',
                                'chat-gguf-cuda',
                                'chat-litert-cpu',
                                'chat-litert-gpu',
                              ])
                      DropdownMenuItem(value: id, child: Text(id)),
                  ],
                  onChanged: _controller.running
                      ? null
                      : (value) => setState(() => _profile = value!),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _controller.running
                          ? null
                          : () => _controller.run(_profile),
                      child: const Text('Run tests'),
                    ),
                    OutlinedButton(
                      onPressed: _controller.running
                          ? _controller.cancel
                          : null,
                      child: const Text('Cancel'),
                    ),
                    OutlinedButton(
                      onPressed: _controller.report == null
                          ? null
                          : () => _controller.host.export(
                              'summary.html',
                              _controller.report!.toHtml(),
                            ),
                      child: const Text('Export report'),
                    ),
                    OutlinedButton(
                      onPressed: _controller.report == null
                          ? null
                          : () => _controller.host.export(
                              'results.json',
                              jsonEncode(_controller.report!.toJson()),
                            ),
                      child: const Text('Export JSON'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_controller.running) const LinearProgressIndicator(),
                Text(
                  _controller.phase,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (_controller.error != null)
                  SelectableText(_controller.error!),
                if (_controller.report != null) ...[
                  Text(
                    'Assertions: ${_controller.report!.assertionsPassed ? 'passed' : 'failed or incomplete'}',
                  ),
                  Text(
                    'Accelerator execution: ${_controller.report!.placement['required'] != true
                        ? 'not required'
                        : _controller.report!.acceleratorVerified
                        ? _controller.report!.placement['reason']
                        : 'unverified; inspect native evidence'}',
                  ),
                  SelectableText(_controller.host.outputLocation),
                ],
                for (final record in _controller.records)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${record['case_id']} · ${record['status']}'),
                    subtitle: Text(
                      '${record['reason'] ?? record['expected'] ?? ''}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
