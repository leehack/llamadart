import 'path_security.dart';

Map<String, dynamic> buildChatPaths({
  required bool apiKeyEnabled,
  required String modelId,
}) {
  return <String, dynamic>{
    '/v1/chat/completions': <String, dynamic>{
      'post': <String, dynamic>{
        'tags': <String>['Chat'],
        'summary': 'Create chat completion',
        'description':
            'Function tools use the standard client-managed Chat Completions '
            'flow. The server returns assistant `tool_calls`; your client '
            'executes each call, appends a `role: "tool"` result with the '
            'matching `tool_call_id`, then submits the updated transcript.',
        'operationId': 'createChatCompletion',
        'security': operationSecurity(apiKeyEnabled),
        'requestBody': <String, dynamic>{
          'required': true,
          'content': <String, dynamic>{
            'application/json': <String, dynamic>{
              'schema': <String, dynamic>{
                r'$ref': '#/components/schemas/ChatCompletionRequest',
              },
              'examples': _buildChatRequestExamples(modelId),
            },
          },
        },
        'responses': <String, dynamic>{
          '200': <String, dynamic>{
            'description':
                'Chat completion response (JSON when `stream=false`, SSE when `stream=true`).',
            'content': <String, dynamic>{
              'application/json': <String, dynamic>{
                'schema': <String, dynamic>{
                  r'$ref': '#/components/schemas/ChatCompletionResponse',
                },
              },
              'text/event-stream': <String, dynamic>{
                'schema': <String, dynamic>{
                  'type': 'string',
                  'description':
                      'SSE stream of `chat.completion.chunk` payloads followed by `data: [DONE]`.',
                },
              },
            },
          },
          '400': <String, dynamic>{
            r'$ref': '#/components/responses/BadRequestError',
          },
          '401': <String, dynamic>{
            r'$ref': '#/components/responses/UnauthorizedError',
          },
          '429': <String, dynamic>{
            r'$ref': '#/components/responses/RateLimitError',
          },
          '500': <String, dynamic>{
            r'$ref': '#/components/responses/ServerError',
          },
        },
      },
    },
  };
}

Map<String, dynamic> _buildChatRequestExamples(String modelId) {
  return <String, dynamic>{
    'basic': <String, dynamic>{
      'summary': 'Basic completion',
      'value': <String, dynamic>{
        'model': modelId,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'You are concise.'},
          <String, dynamic>{
            'role': 'user',
            'content': 'Give one sentence about Seoul.',
          },
        ],
        'max_tokens': 128,
      },
    },
    'streaming': <String, dynamic>{
      'summary': 'Streaming completion (SSE)',
      'value': <String, dynamic>{
        'model': modelId,
        'stream': true,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Write a short poem.'},
        ],
      },
    },
    'tool_call_initial': <String, dynamic>{
      'summary': 'Tool call: request a function',
      'description':
          'Run this request first. Execute the returned function call in your '
          'client; then copy its full assistant message and exact call ID into '
          'the follow-up example.',
      'value': <String, dynamic>{
        'model': modelId,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is the weather in Seoul?',
          },
        ],
        'tools': _weatherTools(),
        'tool_choice': 'required',
      },
    },
    'tool_call_streaming': <String, dynamic>{
      'summary': 'Tool call: request a function (SSE)',
      'description':
          'Accumulate `delta.tool_calls` fragments by index until the stream '
          'finishes with `finish_reason: "tool_calls"`, then use the same '
          'client-managed follow-up flow.',
      'value': <String, dynamic>{
        'model': modelId,
        'stream': true,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is the weather in Seoul?',
          },
        ],
        'tools': _weatherTools(),
        'tool_choice': 'required',
      },
    },
    'tool_call_streaming_with_thinking': <String, dynamic>{
      'summary': 'Tool call: capped reasoning + function request (SSE)',
      'description':
          'llama.cpp/Qwen extension: this request limits reasoning to 128 '
          'tokens, then streams `reasoning_content` followed by the function '
          'call. Accumulate reasoning and `delta.tool_calls` fragments '
          'independently until the stream finishes.',
      'value': <String, dynamic>{
        'model': modelId,
        'stream': true,
        'enable_thinking': true,
        'thinking_budget_tokens': 128,
        'temperature': 0,
        'max_tokens': 512,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content':
                'Before using a tool, reason briefly about why it is needed. '
                'You must call get_weather to answer the user and must not '
                'answer directly.',
          },
          <String, dynamic>{
            'role': 'user',
            'content': 'What is the weather in Seoul?',
          },
        ],
        'tools': _weatherTools(),
        'tool_choice': 'auto',
      },
    },
    'tool_result_follow_up': <String, dynamic>{
      'summary': 'Tool call: submit the function result',
      'description':
          'The call ID below is illustrative. Replace the assistant message '
          'and `tool_call_id` with the exact values from step 1 after your '
          'client executes the function. The standard tool-result message does '
          'not need a `name` field.',
      'value': <String, dynamic>{
        'model': modelId,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is the weather in Seoul?',
          },
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_example',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Seoul"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_weather_example',
            'content':
                '{"location":"Seoul","condition":"sunny","temperature_c":23}',
          },
        ],
        'tools': _weatherTools(),
        'tool_choice': 'none',
      },
    },
  };
}

List<Map<String, dynamic>> _weatherTools() {
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'get_weather',
        'description': 'Get the current weather for a location.',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'location': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['location'],
        },
      },
    },
  ];
}
