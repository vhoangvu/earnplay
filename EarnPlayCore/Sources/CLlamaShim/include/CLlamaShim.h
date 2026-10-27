#ifndef CLLAMASHIM_H
#define CLLAMASHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ep_llama ep_llama_t;

/// Creates a runtime handle and loads the GGUF model at `model_path`.
/// Uses the CPU backend only (n_gpu_layers = 0) so simulator and device
/// behave the same. Returns NULL on failure and, when `out_error` is
/// non-NULL, stores a malloc'd message the caller frees with
/// ep_llama_free_string().
ep_llama_t *ep_llama_create(const char *model_path, char **out_error);

/// Frees a handle created by ep_llama_create(). NULL is accepted.
void ep_llama_destroy(ep_llama_t *handle);

/// Copies the llama.cpp model description into `buffer`.
/// Returns the number of bytes written (excluding the NUL terminator),
/// or a negative value on failure.
int32_t ep_llama_describe(ep_llama_t *handle, char *buffer, size_t buffer_size);

/// Total parameter count reported by the loaded model (0 on failure).
uint64_t ep_llama_n_params(ep_llama_t *handle);

/// Runs one completion for `prompt_utf8`, generating at most
/// `max_tokens` tokens with a fixed-seed sampler. Returns a malloc'd
/// UTF-8 string (possibly empty) the caller frees with
/// ep_llama_free_string(). On failure returns NULL and stores a
/// malloc'd message in `out_error` when non-NULL. When `out_tokens`
/// is non-NULL it receives the number of generated tokens.
char *ep_llama_generate(ep_llama_t *handle, const char *prompt_utf8,
                        int32_t max_tokens, uint32_t seed,
                        int32_t *out_tokens, char **out_error);

/// Frees strings returned by this shim. NULL is accepted.
void ep_llama_free_string(char *string);

/// llama.cpp version string (static storage, do not free).
const char *ep_llama_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CLLAMASHIM_H */
