import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSAny? _previousEngine;

String liteRtWebFakeOutput = 'ok';

void installLiteRtWebRuntimeFake() {
  liteRtWebFakeOutput = 'ok';
  _previousEngine = globalContext.getProperty<JSAny?>('LiteRtLmEngine'.toJS);
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
  globalContext.setProperty('LiteRtLmEngine'.toJS, constructor);
}

void restoreLiteRtWebRuntime() {
  final previous = _previousEngine;
  if (previous == null) {
    globalContext.delete('LiteRtLmEngine'.toJS);
  } else {
    globalContext.setProperty('LiteRtLmEngine'.toJS, previous);
  }
  _previousEngine = null;
}
