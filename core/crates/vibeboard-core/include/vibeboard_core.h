/*
 * vibeboard_core.h — C ABI for the shared VibeBoard core.
 *
 * Threading: every callback runs on a core worker thread. Copy what you need and marshal to
 * your UI thread. Strings are borrowed UTF-8, valid only during the call.
 *
 * Ownership: char* returned by this library must be released with vb_string_free().
 *
 * Build: cargo build --release -p vibeboard-core
 *   macOS:   target/release/libvibeboard_core.a
 *   Windows: target/release/vibeboard_core.dll
 */

#ifndef VIBEBOARD_CORE_H
#define VIBEBOARD_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeBoardHandle vb_core;

typedef struct vb_callbacks {
    void* userdata;

    /* Tray/status line text. */
    void (*on_status)(void* userdata, const char* text);
    /* Revised partial transcript (may be called repeatedly). */
    void (*on_partial_text)(void* userdata, const char* text);
    /* Final transcript; empty string means "no speech recognised". */
    void (*on_final_text)(void* userdata, const char* text);
    /* Human-readable failure; the session usually recovers on its own. */
    void (*on_error)(void* userdata, const char* text);
    /* Non-recognition button action: copyResult / showResult / paste / undo / enter / escape. */
    void (*on_action)(void* userdata, const char* action);
    /* Local engine diagnostics as JSON:
       {backend, systemInfo, model, modelSizeMb, audioSeconds, durationSeconds,
        realtimeFactor, segments, threads, peakRssMb} */
    void (*on_local_stats)(void* userdata, const char* json);

    void (*on_session_started)(void* userdata);
    void (*on_cancelled)(void* userdata);

    /* External recogniser path (Apple Speech / System.Speech): 16 kHz mono PCM16. */
    void (*on_pcm)(void* userdata, const uint8_t* data, size_t length);
    void (*on_pcm_end)(void* userdata);

    /* Optional secret storage. load_secret returns a char* allocated by the shell (or from
       vb_string_alloc); the core frees it with vb_string_free(). */
    char* (*load_secret)(void* userdata, const char* device_id);
    void (*save_secret)(void* userdata, const char* device_id, const char* secret);
} vb_callbacks;

/* config_json fields (all optional except as noted):
 *   provider: "stepfun" | "whisper" | "external"
 *   model: StepFun model id                    whisper_model: tiny|base|small|medium|large-v3-turbo|path
 *   recognition_key, rewrite_key: API keys      rewrite_enabled: bool, rewrite_model: id
 *   button_actions: {"k1":"voice",...}
 *   base_url: auth server, registration_token: optional
 */
vb_core* vb_core_new(const char* config_json, vb_callbacks callbacks, char** error);
void vb_core_free(vb_core* handle);

/* Starts the discovery loop; 0 on success. */
int32_t vb_core_start(vb_core* handle);
void vb_core_stop(vb_core* handle);
void vb_core_cancel(vb_core* handle);

int32_t vb_core_update_config(vb_core* handle, const char* config_json, char** error);

/* Feeds a transcript from the shell's own recogniser (Apple Speech / System.Speech).
   is_final != 0 completes the session. */
void vb_core_external_text(vb_core* handle, const char* text, int32_t is_final);

/* Latest final transcript, or NULL. Free with vb_string_free(). */
char* vb_core_last_text(vb_core* handle);

/* Local recognition build info as JSON, or NULL when built without Whisper. */
char* vb_local_backend_info(void);

/* Model catalogue as JSON array: [{name,fileName,sizeMb,quality,installed,path}]. */
char* vb_model_catalog(void);

/* Downloads a model; progress callback receives (received, total, hasTotal). */
int32_t vb_download_model(const char* name,
                          void (*progress)(void* userdata, uint64_t received, uint64_t total, int32_t has_total),
                          void* userdata,
                          char** error);
int32_t vb_model_available(const char* name);
int32_t vb_model_remove(const char* name, char** error);

char* vb_version(void);

/* Routes core logs to the shell (level, target, message). userdata must outlive the core. */
void vb_set_log_callback(void (*callback)(void* userdata, const char* line), void* userdata);

/* Allocates a string the core can free (for load_secret implementations). */
char* vb_string_alloc(const char* utf8);
void vb_string_free(char* value);

#ifdef __cplusplus
}
#endif

#endif /* VIBEBOARD_CORE_H */
