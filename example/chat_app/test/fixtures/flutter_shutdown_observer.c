// Local-only Flutter host-shutdown observer. No callback enters Dart.
#define _DEFAULT_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "llama.h"

typedef struct llama_model *(*load_fn)(const char *, struct llama_model_params);
typedef void (*free_fn)(void *);
typedef int (*count_fn)(void);
static atomic_int active_load;
static atomic_int progress_seen;
static count_fn tracked_count;
static count_fn image_tracked_count;
static load_fn real_load;

int flutter_shutdown_quit_requested(void) {
    int active = atomic_load(&active_load);
    fprintf(stderr, "FLUTTER_SHUTDOWN_QUIT_REQUEST active_load=%d\n", active);
    return active;
}

static void host_exit(void) {
    fprintf(stderr, "FLUTTER_SHUTDOWN_HOST_EXIT active_load=%d tracked=%d\n",
            atomic_load(&active_load), tracked_count());
    if (image_tracked_count) fprintf(stderr, "FLUTTER_SHUTDOWN_IMAGE_HOST_EXIT tracked=%d\n", image_tracked_count());
    // The host's normal C exit must flush this buffered output.
    fputs("FLUTTER_SHUTDOWN_C_OUTPUT_FLUSHED\n", stdout);
}

int flutter_shutdown_observer_init(const char *self_path, count_fn count) {
    // Keep this native host observer alive through Dart/Flutter cleanup.
    if (!count || !dlopen(self_path, RTLD_NOW | RTLD_NODELETE)) return -1;
    tracked_count = count;
    return atexit(host_exit);
}

static bool load_progress(float progress, void *unused) {
    (void) unused;
    if (progress < 1.0f && !atomic_exchange(&progress_seen, 1)) {
        fputs("FLUTTER_SHUTDOWN_NATIVE_LOAD_PROGRESS\n", stdout);
        fflush(stdout);
        // A deterministic interval for the host to request engine shutdown
        // while the real loader is in its native progress callback.
        usleep(2000000);
    }
    return true;
}

int flutter_shutdown_load(load_fn load, free_fn release, const char *path,
                          struct llama_model_params params) {
    params.progress_callback = load_progress;
    params.progress_callback_user_data = NULL;
    atomic_store(&active_load, 1);
    struct llama_model *model = load(path, params);
    // Native cleanup stays in the same call: an isolate shutdown cannot
    // skip Dart instructions that would otherwise free the returned model.
    if (model) release(model);
    atomic_store(&active_load, 0);
    fprintf(stderr, "FLUTTER_SHUTDOWN_NATIVE_LOAD_RETURNED success=%d\n", model != NULL);
    return model != NULL;
}

// Test-only loader substitution: forward into the exact candidate runtime.
// Ownership remains with the production service and worker, unlike raw loading.
void flutter_shutdown_startup_init(load_fn load) { real_load = load; }
struct llama_model *flutter_shutdown_startup_load(const char *path,
                                                 struct llama_model_params params) {
    params.progress_callback = load_progress;
    params.progress_callback_user_data = NULL;
    atomic_store(&active_load, 1);
    struct llama_model *model = real_load(path, params);
    atomic_store(&active_load, 0);
    fprintf(stderr, "FLUTTER_SHUTDOWN_NATIVE_LOAD_RETURNED success=%d\n", model != NULL);
    return model;
}

void flutter_shutdown_image_init(count_fn count) { image_tracked_count = count; }
