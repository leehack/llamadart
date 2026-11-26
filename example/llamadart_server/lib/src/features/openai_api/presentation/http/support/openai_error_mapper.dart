import 'package:llamadart/llamadart.dart';

import '../../../../shared/shared.dart';

const _requestParams = <String, String>{
  'temp': 'temperature',
  'topP': 'top_p',
  'presencePenalty': 'presence_penalty',
  'frequencyPenalty': 'frequency_penalty',
  'logitBias': 'logit_bias',
};

/// Converts unexpected exceptions into server errors.
///
/// A [LlamaArgumentException] reports a request the model cannot accept, so it
/// becomes a 400 invalid request.
OpenAiHttpException toServerError(Object error, String prefix) {
  if (error is LlamaArgumentException) {
    return OpenAiHttpException.invalidRequest(
      error.message,
      param: _requestParams[error.name],
    );
  }
  return OpenAiHttpException.server('$prefix: $error');
}
