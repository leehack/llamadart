Map<String, dynamic> buildChatResponseSchemas({required String modelId}) {
  return <String, dynamic>{
    'ChatCompletionMessage': <String, dynamic>{
      'type': 'object',
      'required': <String>['role'],
      'properties': <String, dynamic>{
        'role': <String, dynamic>{'type': 'string', 'example': 'assistant'},
        'content': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{'type': 'null'},
          ],
        },
        'reasoning_content': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{'type': 'null'},
          ],
        },
        'tool_calls': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{r'$ref': '#/components/schemas/ToolCall'},
        },
      },
      'additionalProperties': true,
    },
    'ChatCompletionChoice': <String, dynamic>{
      'type': 'object',
      'required': <String>['index', 'message', 'finish_reason'],
      'properties': <String, dynamic>{
        'index': <String, dynamic>{'type': 'integer'},
        'message': <String, dynamic>{
          r'$ref': '#/components/schemas/ChatCompletionMessage',
        },
        'finish_reason': <String, dynamic>{
          'oneOf': <dynamic>[
            <String, dynamic>{'type': 'string'},
            <String, dynamic>{'type': 'null'},
          ],
        },
        'logprobs': <String, dynamic>{
          r'$ref': '#/components/schemas/ChatCompletionLogprobs',
        },
      },
    },
    'ChatCompletionLogprobs': <String, dynamic>{
      'type': 'object',
      'description':
          'Present when the request set `logprobs`. Streaming chunks carry '
          'the tokens that arrived since the previous chunk.',
      'required': <String>['content'],
      'properties': <String, dynamic>{
        'content': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            r'$ref': '#/components/schemas/ChatCompletionTokenLogprob',
          },
        },
      },
    },
    'ChatCompletionTokenLogprob': <String, dynamic>{
      'type': 'object',
      'required': <String>['token', 'logprob', 'bytes', 'top_logprobs'],
      'properties': <String, dynamic>{
        'token': <String, dynamic>{'type': 'string'},
        'id': <String, dynamic>{
          'type': 'integer',
          'description': 'Token ID in the loaded model.',
        },
        'logprob': <String, dynamic>{'type': 'number'},
        'bytes': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'integer'},
        },
        'top_logprobs': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            'type': 'object',
            'required': <String>['token', 'logprob', 'bytes'],
            'properties': <String, dynamic>{
              'token': <String, dynamic>{'type': 'string'},
              'id': <String, dynamic>{'type': 'integer'},
              'logprob': <String, dynamic>{'type': 'number'},
              'bytes': <String, dynamic>{
                'type': 'array',
                'items': <String, dynamic>{'type': 'integer'},
              },
            },
          },
        },
      },
    },
    'Usage': <String, dynamic>{
      'type': 'object',
      'required': <String>[
        'prompt_tokens',
        'completion_tokens',
        'total_tokens',
      ],
      'properties': <String, dynamic>{
        'prompt_tokens': <String, dynamic>{'type': 'integer'},
        'completion_tokens': <String, dynamic>{'type': 'integer'},
        'total_tokens': <String, dynamic>{'type': 'integer'},
      },
    },
    'ChatCompletionResponse': <String, dynamic>{
      'type': 'object',
      'required': <String>[
        'id',
        'object',
        'created',
        'model',
        'choices',
        'usage',
      ],
      'properties': <String, dynamic>{
        'id': <String, dynamic>{'type': 'string'},
        'object': <String, dynamic>{
          'type': 'string',
          'example': 'chat.completion',
        },
        'created': <String, dynamic>{'type': 'integer'},
        'model': <String, dynamic>{'type': 'string', 'example': modelId},
        'choices': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            r'$ref': '#/components/schemas/ChatCompletionChoice',
          },
        },
        'usage': <String, dynamic>{r'$ref': '#/components/schemas/Usage'},
      },
    },
  };
}
