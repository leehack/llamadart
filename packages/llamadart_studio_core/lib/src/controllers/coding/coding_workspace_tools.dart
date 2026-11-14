part of 'coding_workspace_controller.dart';

extension _CodingWorkspaceTools on CodingWorkspaceController {
  List<ToolDefinition> _buildCodingToolsImpl() {
    final root = _store.state.workspaceRoot;
    final workspaceEpoch = _workspaceEpoch;
    final tools = <ToolDefinition>[];
    if (root != null) {
      tools.addAll(<ToolDefinition>[
        ToolDefinition(
          name: 'read',
          description:
              'Read numbered lines from a file inside the workspace before answering or editing.',
          parameters: <ToolParam>[
            ToolParam.string(
              'path',
              description: 'Workspace-relative file path.',
              required: true,
            ),
            ToolParam.integer(
              'startLine',
              description: '1-based start line (defaults to 1).',
            ),
            ToolParam.integer(
              'maxLines',
              description: 'Maximum lines to return (defaults to 200).',
            ),
          ],
          handler: (ToolParams params) async {
            _ensureWorkspaceScope(workspaceEpoch);
            final path = params.getString('path') ?? '';
            final slice = await CodingWorkspaceFs.readFile(
              root,
              path,
              startLine: params.getInt('startLine') ?? 1,
              maxLines: (params.getInt('maxLines') ?? 200).clamp(1, 400),
            );
            _ensureWorkspaceScope(workspaceEpoch);
            return <String, Object?>{
              'path': slice.relativePath,
              'totalLines': slice.totalLines,
              'startLine': slice.startLine,
              'endLine': slice.endLine,
              'truncated': slice.truncated,
              'content': slice.numberedPreview,
            };
          },
        ),
        ToolDefinition(
          name: 'write',
          description:
              'Create a new file or overwrite an existing workspace file.',
          parameters: <ToolParam>[
            ToolParam.string(
              'path',
              description: 'Workspace-relative file path.',
              required: true,
            ),
            ToolParam.string(
              'content',
              description: 'Complete UTF-8 file contents.',
              required: true,
            ),
          ],
          handler: (ToolParams params) async {
            _ensureWorkspaceScope(workspaceEpoch);
            final change = await CodingWorkspaceFs.writeFile(
              root,
              params.getString('path') ?? '',
              params.getString('content') ?? '',
            );
            _recordChange(change, workspaceEpoch: workspaceEpoch);
            return <String, Object?>{
              'status': change.kind.name,
              'path': change.relativePath,
            };
          },
        ),
        ToolDefinition(
          name: 'edit',
          description:
              'Replace an exact verbatim snippet inside an existing workspace file.',
          parameters: <ToolParam>[
            ToolParam.string(
              'path',
              description: 'Workspace-relative file path.',
              required: true,
            ),
            ToolParam.string(
              'findText',
              description: 'Exact verbatim snippet to replace.',
              required: true,
            ),
            ToolParam.string(
              'replaceText',
              description: 'Replacement snippet.',
              required: true,
            ),
            ToolParam.boolean(
              'replaceAll',
              description:
                  'Set true to replace every identical occurrence in the file.',
            ),
          ],
          handler: (ToolParams params) async {
            _ensureWorkspaceScope(workspaceEpoch);
            final change = await CodingWorkspaceFs.patchFile(
              root,
              params.getString('path') ?? '',
              findText: params.getString('findText') ?? '',
              replaceText: params.getString('replaceText') ?? '',
              replaceAll: params.getBool('replaceAll') ?? false,
            );
            _recordChange(change, workspaceEpoch: workspaceEpoch);
            return <String, Object?>{
              'status': 'patched',
              'path': change.relativePath,
            };
          },
        ),
        ToolDefinition(
          name: 'grep',
          description:
              'Search text files in the workspace for a case-insensitive substring.',
          parameters: <ToolParam>[
            ToolParam.string(
              'query',
              description: 'Text or symbol name to search for.',
              required: true,
            ),
            ToolParam.string(
              'extension',
              description:
                  'Optional extension filter such as ".dart" or ".md".',
            ),
          ],
          handler: (ToolParams params) async {
            _ensureWorkspaceScope(workspaceEpoch);
            final matches = await CodingWorkspaceFs.searchCode(
              root,
              params.getString('query') ?? '',
              fileExtension: params.getString('extension'),
            );
            _ensureWorkspaceScope(workspaceEpoch);
            return <String, Object?>{
              'matchCount': matches.length,
              'matches': matches
                  .map(
                    (WorkspaceSearchMatch m) => <String, Object?>{
                      'path': m.relativePath,
                      'line': m.lineNumber,
                      'text': m.lineText,
                    },
                  )
                  .toList(growable: false),
            };
          },
        ),
        ToolDefinition(
          name: 'ls',
          description:
              'List files and directories inside the open workspace folder.',
          parameters: <ToolParam>[
            ToolParam.string(
              'subdir',
              description:
                  'Optional relative subdirectory path (empty for workspace root).',
            ),
            ToolParam.boolean(
              'recursive',
              description: 'Set true to recurse up to 4 folder levels.',
            ),
          ],
          handler: (ToolParams params) async {
            _ensureWorkspaceScope(workspaceEpoch);
            final entries = await CodingWorkspaceFs.listFiles(
              root,
              subdir: params.getString('subdir') ?? '',
              recursive: params.getBool('recursive') ?? false,
              maxEntries: 150,
            );
            _ensureWorkspaceScope(workspaceEpoch);
            return <String, Object?>{
              'root': root,
              'count': entries.length,
              'entries': entries
                  .map(
                    (WorkspaceFileEntry e) => <String, Object?>{
                      'path': e.relativePath,
                      'type': e.isDirectory ? 'dir' : 'file',
                      if (!e.isDirectory) 'bytes': e.sizeBytes,
                    },
                  )
                  .toList(growable: false),
            };
          },
        ),
      ]);

      if (_store.state.allowShellCommandTool) {
        tools.add(
          ToolDefinition(
            name: 'bash',
            description:
                'Execute a shell command inside the workspace root (user-enabled).',
            parameters: <ToolParam>[
              ToolParam.string(
                'command',
                description: 'Shell command to execute (e.g. "dart analyze").',
                required: true,
              ),
            ],
            handler: (ToolParams params) async {
              _ensureWorkspaceScope(workspaceEpoch);
              final command = params.getString('command') ?? '';
              if (_store.state.confirmShellCommands) {
                final approved = await _requestShellApproval(root, command);
                if (!approved) {
                  return <String, Object?>{
                    'approved': false,
                    'rejected': true,
                    'command': command,
                    'error':
                        'Command execution declined by user before running.',
                  };
                }
              }
              _ensureWorkspaceScope(workspaceEpoch);
              final output = await CodingWorkspaceFs.runCommand(root, command);
              _ensureWorkspaceScope(workspaceEpoch);
              return <String, Object?>{
                'exitCode': output.exitCode,
                'elapsedMs': output.elapsedMs,
                'stdout': output.stdout,
                if (output.stderr.isNotEmpty) 'stderr': output.stderr,
              };
            },
          ),
        );
      }
    }

    // Also include active connected MCP server tools (`mcp_dart`).
    tools.addAll(_mcp.buildActiveToolDefinitions());
    return tools;
  }
}
