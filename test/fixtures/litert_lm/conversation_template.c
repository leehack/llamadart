// Minimal C ABI fixture for the real Dart conversation-template FFI path.
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
static char template_text[32768];
static char system_text[32768];
const char* fixture_system_message(void) { return system_text; }
void litert_lm_conversation_config_set_system_message(void* p, const char* s) { strncpy(system_text, s, sizeof(system_text) - 1); }
void litert_lm_set_min_log_level(int level) {}
void* litert_lm_engine_settings_create(const char* m, const char* b, const char* v, const char* a) { return (void*)1; }
void litert_lm_engine_settings_set_max_num_tokens(void* p, int n) {}
void litert_lm_engine_settings_enable_benchmark(void* p) {}
void litert_lm_engine_settings_set_enable_speculative_decoding(void* p, bool b) {}
void litert_lm_engine_settings_delete(void* p) {}
void* litert_lm_engine_create(void* p) { return (void*)2; }
void litert_lm_engine_delete(void* p) {}
void* litert_lm_session_config_create(void) { return (void*)3; }
void litert_lm_session_config_delete(void* p) {}
void* litert_lm_conversation_config_create(void) { template_text[0] = 0; return (void*)4; }
void litert_lm_conversation_config_set_session_config(void* p, void* s) {}
void litert_lm_conversation_config_set_enable_constrained_decoding(void* p, bool b) {}
#ifndef OMIT_TEMPLATE_SETTER
void litert_lm_conversation_config_set_prompt_template(void* p, const char* t) {
  strncpy(template_text, t, sizeof(template_text) - 1);
}
#endif
void litert_lm_conversation_config_delete(void* p) {}
void* litert_lm_conversation_create(void* e, void* c) { return (void*)5; }
void litert_lm_conversation_delete(void* p) {}
const char* litert_lm_conversation_render_message_to_string(void* p, const char* m) { return template_text; }
