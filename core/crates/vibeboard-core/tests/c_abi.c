// Links against libvibeboard_core.a and exercises the C ABI the shells use.
// Build (macOS):
//   cargo build --release -p vibeboard-core
//   clang -Iinclude tests/c_abi.c \
//     ../target/release/libvibeboard_core.a \
//     -framework Security -framework CoreFoundation -framework IOKit \
//     -lpthread -lm -o /tmp/vb_c_abi && /tmp/vb_c_abi

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "vibeboard_core.h"

static int status_calls = 0;
static int pcm_calls = 0;
static char last_status[512];

static void on_status(void* userdata, const char* text) {
    (void)userdata;
    status_calls++;
    snprintf(last_status, sizeof(last_status), "%s", text ? text : "");
}

static void on_text(void* userdata, const char* text) {
    (void)userdata;
    printf("[text] %s\n", text ? text : "");
}

static void on_error(void* userdata, const char* text) {
    (void)userdata;
    printf("[error] %s\n", text ? text : "");
}

static void on_stats(void* userdata, const char* json) {
    (void)userdata;
    printf("[stats] %s\n", json ? json : "");
}

static void on_action(void* userdata, const char* action) {
    (void)userdata;
    printf("[action] %s\n", action ? action : "");
}

static void on_pcm(void* userdata, const uint8_t* data, size_t length) {
    (void)userdata;
    (void)data;
    pcm_calls++;
    if (length == 0) printf("[pcm] empty frame\n");
}

static void on_void(void* userdata) { (void)userdata; }

static void on_progress(void* userdata, uint64_t received, uint64_t total, int32_t has_total) {
    (void)userdata;
    if (has_total) printf("[progress] %llu/%llu\n", (unsigned long long)received, (unsigned long long)total);
}

int main(void) {
    char* version = vb_version();
    printf("core version: %s\n", version);
    vb_string_free(version);

    char* catalog = vb_model_catalog();
    printf("catalog: %.120s...\n", catalog);
    vb_string_free(catalog);

    char* backend = vb_local_backend_info();
    if (backend) {
        printf("backend: %.160s\n", backend);
        vb_string_free(backend);
    }

    vb_callbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.on_status = on_status;
    callbacks.on_partial_text = on_text;
    callbacks.on_final_text = on_text;
    callbacks.on_error = on_error;
    callbacks.on_local_stats = on_stats;
    callbacks.on_action = on_action;
    callbacks.on_session_started = on_void;
    callbacks.on_cancelled = on_void;
    callbacks.on_pcm = on_pcm;
    callbacks.on_pcm_end = on_void;

    char* error = NULL;
    const char* config = "{\"provider\":\"external\",\"button_actions\":{\"k1\":\"copyResult\"}}";
    vb_core* core = vb_core_new(config, callbacks, &error);
    if (!core) {
        printf("create failed: %s\n", error ? error : "(no message)");
        if (error) vb_string_free(error);
        return 1;
    }

    int32_t started = vb_core_start(core);
    printf("start -> %d\n", started);
    sleep(1);
    vb_core_cancel(core);
    vb_core_stop(core);

    char* last = vb_core_last_text(core);
    printf("last text: %s\n", last ? last : "(none)");
    if (last) vb_string_free(last);

    vb_core_free(core);
    printf("status callbacks: %d, pcm callbacks: %d, last status: %s\n",
           status_calls, pcm_calls, last_status);

    // Invalid config must fail cleanly and hand back an error string.
    error = NULL;
    vb_core* broken = vb_core_new("{broken", callbacks, &error);
    printf("broken handle: %p, error: %s\n", (void*)broken, error ? error : "(none)");
    if (error) vb_string_free(error);
    if (broken) vb_core_free(broken);

    (void)on_progress;
    printf("OK\n");
    return 0;
}
