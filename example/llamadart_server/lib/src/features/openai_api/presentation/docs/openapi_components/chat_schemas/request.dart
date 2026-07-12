Map<String, dynamic> buildChatRequestSchemas({required String modelId}) {
  return <String, dynamic>{
    'ChatCompletionRequest': <String, dynamic>{
      'type': 'object',
      'required': <String>['model', 'messages'],
      'description':
          'Function calls are returned to the client for execution. Submit a '
          'follow-up request containing the assistant tool-call message and '
          'matching `role: "tool"` results.',
      'example': <String, dynamic>{
        'model': modelId,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'You are concise.'},
          <String, dynamic>{
            'role': 'user',
            'content': 'Give one sentence about Seoul.',
          },
        ],
        'max_tokens': 128,
        'enable_thinking': false,
      },
      'properties': <String, dynamic>{
        'model': <String, dynamic>{'type': 'string', 'example': modelId},
        'messages': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            r'$ref': '#/components/schemas/ChatMessage',
          },
          'example': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hello!'},
          ],
        },
        'stream': <String, dynamic>{'type': 'boolean', 'default': false},
        'enable_thinking': <String, dynamic>{
          'type': 'boolean',
          'default': false,
          'description':
              'Enable model reasoning output in `reasoning_content`. '
              'Disabled by default for the default Qwen3.6 27B model.',
        },
        'parallel_tool_calls': <String, dynamic>{
          'type': 'boolean',
          'default': false,
          'description':
              'Allow multiple function calls in one response when the active '
              'model template supports parallel tool calls.',
        },
        'max_tokens': <String, dynamic>{'type': 'integer', 'minimum': 1},
        'temperature': <String, dynamic>{'type': 'number'},
        'top_p': <String, dynamic>{'type': 'number'},
        'seed': <String, dynamic>{'type': 'integer'},
        'n': <String, dynamic>{
          'type': 'integer',
          'enum': <int>[1],
          'description': 'This example currently supports only `n = 1`.',
        },
        'stop': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
            },
          ],
        },
        'tools': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            r'$ref': '#/components/schemas/ToolDefinition',
          },
        },
        'tool_choice': <String, dynamic>{
          'description':
              'Use a string to choose automatic behavior, or the object form '
              'to require one named function from `tools`.',
          'oneOf': <dynamic>[
            <String, dynamic>{
              'type': 'string',
              'enum': <String>['none', 'auto', 'required'],
            },
            <String, dynamic>{
              'type': 'object',
              'required': <String>['type', 'function'],
              'properties': <String, dynamic>{
                'type': <String, dynamic>{
                  'type': 'string',
                  'enum': <String>['function'],
                },
                'function': <String, dynamic>{
                  'type': 'object',
                  'required': <String>['name'],
                  'properties': <String, dynamic>{
                    'name': <String, dynamic>{'type': 'string'},
                  },
                  'additionalProperties': false,
                },
              },
              'additionalProperties': false,
            },
          ],
        },
      },
      'additionalProperties': true,
    },
  };
}
