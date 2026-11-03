#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

static int live = 0, failure = 0;
static char copied[128];
void fixture_fail(int stage) { failure = stage; }
int fixture_live(void) { return live; }
const char *litert_lm_get_last_error_message(void) { return "candidate failure /secret/models/m.litertlm"; }
int litert_lm_get_api_version(int *a, int *b, int *c) { *a=1;*b=0;*c=0;return 0; }
static int create(int stage, void **out) {
  *out = NULL;
  if (failure == 12 && stage == 9) return 0;
  if (failure == stage) return 13;
  *out = malloc(1); ++live; return 0;
}
static void drop(void *p) { if (p) { --live; free(p); } }
int litert_lm_engine_settings_create(const char *m,const char *b,const char *v,const char *a,void **o) { (void)m;(void)b;(void)v;(void)a;return create(1,o); }
void litert_lm_engine_settings_delete(void *p) { drop(p); }
int litert_lm_engine_settings_set_num_threads(void *p,int n) { (void)p;(void)n;return failure==2 ? 13 : 0; }
int litert_lm_engine_settings_set_max_num_tokens(void *p,int n) { (void)p;(void)n;return 0; }
int litert_lm_engine_settings_set_cache_dir(void *p,const char *s) { (void)p;(void)s;return 0; }
int litert_lm_engine_create(void *s,void **o) { (void)s;return create(3,o); }
void litert_lm_engine_delete(void *p) { drop(p); }
int litert_lm_session_config_create(void **o) { return create(4,o); }
void litert_lm_session_config_delete(void *p) { drop(p); }
int litert_lm_session_config_set_max_output_tokens(void *p,int n) { (void)p;(void)n;return failure==5 ? 13 : 0; }
int litert_lm_session_config_set_sampler_params(void *p,void *s) { (void)p;(void)s;return 0; }
int litert_lm_sampler_params_create(int type,void **o) { if(type!=2) abort();return create(6,o); }
void litert_lm_sampler_params_delete(void *p) { drop(p); }
int litert_lm_engine_create_session(void *e,void *c,void **o) { (void)e;(void)c;return create(7,o); }
void litert_lm_session_delete(void *p) { drop(p); }
int litert_lm_input_data_create(int type,const void *data,size_t size,void **o) {
  if(type!=0 || size>=sizeof copied) abort();
  memcpy(copied,data,size);copied[size]=0;return create(8,o);
}
void litert_lm_input_data_delete(void *p) { drop(p); }
int litert_lm_session_generate_content(void *s,void *const *inputs,size_t n,void **o) {
  (void)s;if(n!=1 || !inputs[0]) abort();return create(9,o);
}
int litert_lm_responses_get_response_text_at(void *p,size_t n,const char **o) {
  (void)p;if(n!=0) abort();*o=failure==11 ? NULL : copied;return failure==10 ? 13 : 0;
}
void litert_lm_responses_delete(void *p) { drop(p); }

int litert_lm_session_config_set_apply_prompt_template(void *p,bool value) { (void)p; if(value) abort();return 0; }

int litert_lm_sampler_params_set_top_k(void *p,int k) { (void)p;if(k!=1) abort();return 0; }
int litert_lm_sampler_params_set_top_p(void *p,float v) { (void)p;if(v<0.94f || v>0.96f) abort();return 0; }
int litert_lm_sampler_params_set_temperature(void *p,float v) { (void)p;if(v!=0) abort();return 0; }
