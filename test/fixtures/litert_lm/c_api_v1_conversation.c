#include "c_api_v1_text.c"
#include <assert.h>
#include <stdint.h>
#include <pthread.h>

#ifndef PROXY_ABI
#define PROXY_ABI 2
#endif
#ifndef FINISH_ABI
#define FINISH_ABI 1
#endif

typedef void (*owned_callback)(void *, char *, bool, char *);
typedef struct {
  owned_callback callback;
  void *data;
  int reason;
} proxy;
typedef struct { const char *text, *error; bool final; } borrowed_chunk;
typedef void (*chunk_callback)(void *, const borrowed_chunk *);
static int copies, proxies, created, deleted, waits, cancels, sends;
static bool active, drained, cancelled;
static chunk_callback receiver;
static void *receiver_data;

int fixture_copies(void) { return copies; }
int fixture_proxies(void) { return proxies; }
int fixture_created(void) { return created; }
int fixture_deleted(void) { return deleted; }
int fixture_waits(void) { return waits; }
int fixture_cancels(void) { return cancels; }
int fixture_sends(void) { return sends; }
#ifndef OMIT_PROXY_MARKER
int32_t stream_proxy_callback_abi_version(void) { return PROXY_ABI; }
#endif
#ifndef OMIT_FINISH_MARKER
int32_t stream_proxy_finish_reason_abi_version(void) { return FINISH_ABI; }
#endif
int32_t stream_proxy_get_finish_reason(void *data) { return ((proxy *)data)->reason; }
static char *copy_string(const char *text) {
  if (!text) return NULL;
  ++copies; return strdup(text);
}
static void forward(void *data, const borrowed_chunk *chunk) {
  proxy *context = data;
  if (chunk->final) context->reason = cancelled ? 4 : chunk->error ? 5 : 1;
  context->callback(context->data, copy_string(chunk->text), chunk->final, copy_string(chunk->error));
}
#ifndef OMIT_PROXY_CREATE
void *stream_proxy_create(owned_callback callback, void *data, chunk_callback *out) {
  if (failure == 16) { *out = NULL; return NULL; }
  proxy *context = calloc(1, sizeof *context);
  context->callback = callback; context->data = data; *out = forward;
  ++proxies; return context;
}
#endif
void stream_proxy_free_string(char *text) {
  if (text) { memset(text, 0xCC, strlen(text)); free(text); --copies; }
}
void stream_proxy_delete(void *data) {
  assert(!active || drained); free(data); --proxies;
}
int litert_lm_conversation_config_create(void **out) { return create(13, out); }
void litert_lm_conversation_config_delete(void *config) { drop(config); }
int litert_lm_conversation_config_set_session_config(void *config, void *session) {
  assert(config && session); return failure == 14 ? 13 : 0;
}
int litert_lm_conversation_create(void *engine, void *config, void **out) {
  assert(engine && config);
  int status = create(15, out);
  if (!status) { ++created; cancelled = false; active = false; }
  return status;
}
void litert_lm_conversation_delete(void *conversation) {
  assert(!active || drained); ++deleted; active = false; drop(conversation);
}
int litert_lm_conversation_send_message_stream(void *conversation, const char *message,
    const char *extra, const void *args, chunk_callback callback, void *data) {
  assert(conversation && message && !extra && !args && callback);
  assert(!active && !cancelled);
  ++sends;
  if (failure == 17) return 13;
  receiver = callback; receiver_data = data; drained = false; active = true;
  return 0;
}
int litert_lm_conversation_cancel_process(void *conversation) {
  assert(conversation); ++cancels; cancelled = true;
  return failure == 18 ? 13 : 0;
}
int litert_lm_conversation_wait_until_done(void *conversation) {
  assert(conversation); ++waits;
  if (failure == 19) return 13;
  active = false; drained = true; return 0;
}
// Invoke from a foreign thread; overwrite borrowed storage immediately after
// callback return so an asynchronous Dart borrowed-pointer consumer is wrong.
static void *emit(void *argument) {
  int kind = *(int *)argument;
  char text[] = "borrowed UTF8 世界";
  char error[160] = "callback failure /secret/models/m.litertlm https://user:secret@example.test/model?token=secret";
  if (kind == 3) strcpy(error, "CANCELLED: stream stopped");
  if (kind == 6) text[0] = (char)0xff;
  borrowed_chunk chunk = {
    .text = kind == 0 || kind == 4 || kind == 6 ? text : NULL,
    .error = kind == 1 || kind == 3 || kind == 4 ? error : NULL,
    .final = kind >= 2,
  };
  receiver(receiver_data, &chunk);
  memset(text, 'X', sizeof text - 1);
  memset(error, 'X', sizeof error - 1);
  return NULL;
}
void fixture_emit(int kind) {
  assert(active); pthread_t thread;
  assert(!pthread_create(&thread, NULL, emit, &kind));
  assert(!pthread_join(thread, NULL));
}
