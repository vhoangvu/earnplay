#include "CLlamaShim.h"

#include <llama/llama.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct ep_llama {
    struct llama_model *model;
    struct llama_context *ctx;
    const struct llama_vocab *vocab;
};

static pthread_once_t ep_backend_once = PTHREAD_ONCE_INIT;

static void ep_init_backend(void) {
    llama_backend_init();
}

static char *ep_strdup(const char *text) {
    if (text == NULL) {
        return NULL;
    }
    size_t len = strlen(text);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, text, len + 1);
    return copy;
}

static void ep_set_error(char **out_error, const char *message) {
    if (out_error != NULL) {
        *out_error = ep_strdup(message);
    }
}

ep_llama_t *ep_llama_create(const char *model_path, char **out_error) {
    if (out_error != NULL) {
        *out_error = NULL;
    }
    if (model_path == NULL || model_path[0] == '\0') {
        ep_set_error(out_error, "model path is empty");
        return NULL;
    }
    pthread_once(&ep_backend_once, ep_init_backend);

    struct llama_model_params model_params = llama_model_default_params();
    static ggml_backend_dev_t cpu_only_devices[] = { NULL };
    model_params.devices = cpu_only_devices;
    model_params.n_gpu_layers = 0; /* CPU only: identical on sim + device */

    struct llama_model *model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        ep_set_error(out_error, "llama_model_load_from_file failed");
        return NULL;
    }

    struct llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 2048;
    /* Prefill submits the whole prompt as one batch (below), so the
       decode batch must hold any prompt that fits the context. */
    ctx_params.n_batch = ctx_params.n_ctx;
    ctx_params.n_ubatch = 512;
    ctx_params.n_threads = 4;
    ctx_params.n_threads_batch = 4;

    struct llama_context *ctx = llama_init_from_model(model, ctx_params);
    if (ctx == NULL) {
        llama_model_free(model);
        ep_set_error(out_error, "llama_init_from_model failed");
        return NULL;
    }

    ep_llama_t *handle = (ep_llama_t *)calloc(1, sizeof(ep_llama_t));
    if (handle == NULL) {
        llama_free(ctx);
        llama_model_free(model);
        ep_set_error(out_error, "out of memory");
        return NULL;
    }
    handle->model = model;
    handle->ctx = ctx;
    handle->vocab = llama_model_get_vocab(model);
    return handle;
}

void ep_llama_destroy(ep_llama_t *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->ctx != NULL) {
        llama_free(handle->ctx);
    }
    if (handle->model != NULL) {
        llama_model_free(handle->model);
    }
    free(handle);
}

int32_t ep_llama_describe(ep_llama_t *handle, char *buffer, size_t buffer_size) {
    if (handle == NULL || handle->model == NULL || buffer == NULL || buffer_size == 0) {
        return -1;
    }
    return llama_model_desc(handle->model, buffer, buffer_size);
}

uint64_t ep_llama_n_params(ep_llama_t *handle) {
    if (handle == NULL || handle->model == NULL) {
        return 0;
    }
    return llama_model_n_params(handle->model);
}

char *ep_llama_generate(ep_llama_t *handle, const char *prompt_utf8,
                        int32_t max_tokens, uint32_t seed,
                        int32_t *out_tokens, char **out_error) {
    if (out_error != NULL) {
        *out_error = NULL;
    }
    if (out_tokens != NULL) {
        *out_tokens = 0;
    }
    if (handle == NULL || handle->ctx == NULL || handle->vocab == NULL) {
        ep_set_error(out_error, "runtime handle is not loaded");
        return NULL;
    }
    if (prompt_utf8 == NULL || prompt_utf8[0] == '\0') {
        ep_set_error(out_error, "prompt is empty");
        return NULL;
    }
    if (max_tokens <= 0) {
        max_tokens = 64;
    }

    /* Tokenize (two-pass: first call reports the required count). */
    int32_t text_len = (int32_t)strlen(prompt_utf8);
    int32_t n_needed = llama_tokenize(handle->vocab, prompt_utf8, text_len,
                                      NULL, 0, true, false);
    if (n_needed >= 0) {
        ep_set_error(out_error, "tokenize size probe failed");
        return NULL;
    }
    int32_t n_prompt = -n_needed;
    if (n_prompt <= 0) {
        ep_set_error(out_error, "prompt produced no tokens");
        return NULL;
    }
    llama_token *prompt_tokens =
        (llama_token *)malloc((size_t)n_prompt * sizeof(llama_token));
    if (prompt_tokens == NULL) {
        ep_set_error(out_error, "out of memory");
        return NULL;
    }
    int32_t n_got = llama_tokenize(handle->vocab, prompt_utf8, text_len,
                                   prompt_tokens, n_prompt, true, false);
    if (n_got <= 0) {
        free(prompt_tokens);
        ep_set_error(out_error, "llama_tokenize failed");
        return NULL;
    }
    n_prompt = n_got;
    if (n_prompt >= 2048) {
        free(prompt_tokens);
        ep_set_error(out_error, "prompt exceeds context size");
        return NULL;
    }
    if (max_tokens > 2048 - n_prompt) {
        max_tokens = 2048 - n_prompt;
    }

    /* Fresh sequence for every call. */
    llama_memory_clear(llama_get_memory(handle->ctx), true);

    /* Prefill: decode the whole prompt, logits only on the last token. */
    struct llama_batch batch = llama_batch_init(n_prompt, 0, 1);
    if (batch.token == NULL) {
        free(prompt_tokens);
        ep_set_error(out_error, "llama_batch_init failed");
        return NULL;
    }
    for (int32_t i = 0; i < n_prompt; i++) {
        batch.token[i] = prompt_tokens[i];
        batch.pos[i] = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = (i == n_prompt - 1) ? 1 : 0;
    }
    batch.n_tokens = n_prompt;
    free(prompt_tokens);
    if (llama_decode(handle->ctx, batch) != 0) {
        llama_batch_free(batch);
        ep_set_error(out_error, "llama_decode failed on prompt");
        return NULL;
    }
    llama_batch_free(batch);

    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    struct llama_sampler *sampler = llama_sampler_chain_init(sparams);
    if (sampler == NULL) {
        ep_set_error(out_error, "llama_sampler_chain_init failed");
        return NULL;
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));

    size_t capacity = 4096;
    size_t length = 0;
    char *output = (char *)malloc(capacity);
    if (output == NULL) {
        llama_sampler_free(sampler);
        ep_set_error(out_error, "out of memory");
        return NULL;
    }
    output[0] = '\0';

    int32_t generated = 0;
    int failed = 0;
    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token token = llama_sampler_sample(sampler, handle->ctx, -1);
        if (llama_vocab_is_eog(handle->vocab, token)) {
            break;
        }
        char piece[512];
        int32_t n_piece = llama_token_to_piece(handle->vocab, token, piece,
                                               (int32_t)sizeof(piece), 0, false);
        if (n_piece < 0) {
            failed = 1;
            break;
        }
        if (n_piece > 0) {
            if (length + (size_t)n_piece + 1 > capacity) {
                size_t bigger = capacity * 2 + (size_t)n_piece;
                char *grown = (char *)realloc(output, bigger);
                if (grown == NULL) {
                    failed = 1;
                    break;
                }
                output = grown;
                capacity = bigger;
            }
            memcpy(output + length, piece, (size_t)n_piece);
            length += (size_t)n_piece;
            output[length] = '\0';
        }
        generated += 1;
        struct llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(handle->ctx, next) != 0) {
            failed = 1;
            break;
        }
    }

    llama_sampler_free(sampler);
    if (failed) {
        free(output);
        ep_set_error(out_error, "generation failed");
        return NULL;
    }
    if (out_tokens != NULL) {
        *out_tokens = generated;
    }
    return output;
}

void ep_llama_free_string(char *string) {
    free(string);
}

const char *ep_llama_version(void) {
    return llama_version();
}
