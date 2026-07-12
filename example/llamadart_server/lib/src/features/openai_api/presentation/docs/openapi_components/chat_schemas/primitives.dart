Map<String, dynamic> buildChatPrimitiveSchemas() {
  return <String, dynamic>{
    'ChatContentPart': <String, dynamic>{
      'type': 'object',
      'required': <String>['type'],
      'properties': <String, dynamic>{
        'type': <String, dynamic>{
          'type': 'string',
          'enum': <String>['text', 'input_text'],
        },
        'text': <String, dynamic>{'type': 'string'},
      },
      'additionalProperties': true,
    },
    'ToolCallFunction': <String, dynamic>{
      'type': 'object',
      'required': <String>['name', 'arguments'],
      'properties': <String, dynamic>{
        'name': <String, dynamic>{'type': 'string'},
        'arguments': <String, dynamic>{
          'type': 'string',
          'description':
              'JSON-encoded function arguments. Preserve this string exactly '
              'when replaying an assistant tool call.',
        },
      },
      'additionalProperties': true,
    },
    'ToolCall': <String, dynamic>{
      'type': 'object',
      'required': <String>['id', 'type', 'function'],
      'properties': <String, dynamic>{
        'id': <String, dynamic>{'type': 'string', 'minLength': 1},
        'type': <String, dynamic>{
          'type': 'string',
          'enum': <String>['function'],
          'example': 'function',
        },
        'function': <String, dynamic>{
          r'$ref': '#/components/schemas/ToolCallFunction',
        },
      },
      'additionalProperties': true,
    },
    'ChatMessage': <String, dynamic>{
      'type': 'object',
      'required': <String>['role'],
      'description':
          'For the client-managed tool flow, an assistant tool-call message '
          'includes `tool_calls`; each subsequent `role: "tool"` message '
          'includes the matching `tool_call_id` and result content.',
      'example': <String, dynamic>{'role': 'user', 'content': 'Hello!'},
      'properties': <String, dynamic>{
        'role': <String, dynamic>{
          'type': 'string',
          'enum': <String>['system', 'developer', 'user', 'assistant', 'tool'],
        },
        'content': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{
                r'$ref': '#/components/schemas/ChatContentPart',
              },
            },
            <String, dynamic>{'type': 'null'},
          ],
        },
        'reasoning_content': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{'type': 'null'},
          ],
        },
        'tool_call_id': <String, dynamic>{
          'type': 'string',
          'minLength': 1,
          'description':
              'Required for `role: "tool"`; must match an earlier assistant '
              'tool-call ID.',
        },
        'tool_calls': <String, dynamic>{
          'type': 'array',
          'description':
              'Assistant function calls. Replay the returned assistant message '
              'before supplying the corresponding tool result.',
          'items': <String, dynamic>{r'$ref': '#/components/schemas/ToolCall'},
        },
        'name': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional tool name. Standard tool-result messages normally omit '
              'this because `tool_call_id` identifies the function.',
        },
      },
      'additionalProperties': true,
    },
    'ToolDefinition': <String, dynamic>{
      'type': 'object',
      'required': <String>['type', 'function'],
      'example': <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': 'get_weather',
          'description': 'Get weather by city.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'city': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['city'],
          },
        },
      },
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
            'description': <String, dynamic>{'type': 'string'},
            'parameters': <String, dynamic>{'type': 'object'},
          },
          'additionalProperties': true,
        },
      },
      'additionalProperties': true,
    },
  };
}
