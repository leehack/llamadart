import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSAny? _previousEngine;
JSAny? _previousBackendEnum;

String liteRtWebFakeOutput = 'ok';

void installLiteRtWebRuntimeFake() {
  liteRtWebFakeOutput = 'ok';
  _previousEngine = globalContext.getProperty<JSAny?>('LiteRtLmEngine'.toJS);
  _previousBackendEnum = globalContext.getProperty<JSAny?>(
    'LiteRtLmBackendEnum'.toJS,
  );
  final constructor = JSObject();
  constructor.setProperty(
    'create'.toJS,
    ((JSObject settings) {
      final engine = JSObject();
      engine.setProperty(
        'createConversation'.toJS,
        ((JSObject config) {
          config.getProperty<JSAny?>('preface'.toJS);
          final conversation = JSObject();
          conversation.setProperty(
            'getHistory'.toJS,
            (() => Future<JSAny?>.value(<JSAny?>[].toJS).toJS).toJS,
          );
          conversation.setProperty('cancel'.toJS, (() {}).toJS);
          conversation.setProperty(
            'delete'.toJS,
            (() => Future<JSAny?>.value(null).toJS).toJS,
          );
          conversation.setProperty(
            'sendMessageStreaming'.toJS,
            ((String prompt) {
              final stream = JSObject();
              stream.setProperty(
                'getReader'.toJS,
                (() {
                  var sent = false;
                  final reader = JSObject();
                  reader.setProperty(
                    'read'.toJS,
                    (() {
                      final result = JSObject()
                        ..setProperty('done'.toJS, sent.toJS);
                      if (!sent) {
                        result.setProperty(
                          'value'.toJS,
                          liteRtWebFakeOutput.toJS,
                        );
                      }
                      sent = true;
                      return Future<JSObject>.value(result).toJS;
                    }).toJS,
                  );
                  reader.setProperty(
                    'cancel'.toJS,
                    (() => Future<JSAny?>.value(null).toJS).toJS,
                  );
                  reader.setProperty('releaseLock'.toJS, (() {}).toJS);
                  return reader;
                }).toJS,
              );
              return stream;
            }).toJS,
          );
          return Future<JSObject>.value(conversation).toJS;
        }).toJS,
      );
      engine.setProperty(
        'delete'.toJS,
        (() => Future<JSAny?>.value(null).toJS).toJS,
      );
      return Future<JSObject>.value(engine).toJS;
    }).toJS,
  );
  globalContext.setProperty(
    'LiteRtLmBackendEnum'.toJS,
    {'CPU': 3, 'GPU_ARTISAN': 2, 'GPU': 4}.jsify(),
  );
  globalContext.setProperty('LiteRtLmEngine'.toJS, constructor);
}

void restoreLiteRtWebRuntime() {
  final previous = _previousEngine;
  if (previous == null) {
    globalContext.delete('LiteRtLmEngine'.toJS);
  } else {
    globalContext.setProperty('LiteRtLmEngine'.toJS, previous);
  }
  final previousBackendEnum = _previousBackendEnum;
  if (previousBackendEnum == null) {
    globalContext.delete('LiteRtLmBackendEnum'.toJS);
  } else {
    globalContext.setProperty('LiteRtLmBackendEnum'.toJS, previousBackendEnum);
  }
  _previousEngine = null;
  _previousBackendEnum = null;
}
