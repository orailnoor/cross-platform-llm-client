#import "LlamaIosWrapper.h"
#include "llama.h"
#include <atomic>
#include <vector>
#include <string>
#include <cstring>
#include <algorithm>

#define LOGI(...) NSLog(@"[LlamaIOS] " __VA_ARGS__)
#define LOGE(...) NSLog(@"[LlamaIOS ERROR] " __VA_ARGS__)

// Global inference state (mirrors jni_wrapper.cpp)
static llama_model*        g_model    = nullptr;
static llama_context*      g_ctx      = nullptr;
static const llama_vocab*  g_vocab    = nullptr;
static llama_sampler*      g_sampler  = nullptr;
static std::atomic<bool>   g_stop_flag{false};
static int                 g_n_past   = 0;
static int                 g_system_prompt_length = 0;

// UTF-8 helpers (identical logic to jni_wrapper.cpp)
static bool isValidUTF8(const char* str, size_t len) {
    if (!str) return false;
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    while (i < len) {
        unsigned char c = bytes[i];
        if ((c & 0x80) == 0) { i++; continue; }
        int nb = 0;
        if      ((c & 0xE0) == 0xC0) nb = 2;
        else if ((c & 0xF0) == 0xE0) nb = 3;
        else if ((c & 0xF8) == 0xF0) nb = 4;
        else return false;
        if (i + nb > len) return false;
        for (int j = 1; j < nb; j++)
            if ((bytes[i+j] & 0xC0) != 0x80) return false;
        if (nb == 2 && (c & 0x1E) == 0) return false;
        if (nb == 3) {
            if (c == 0xED && (bytes[i+1] & 0x20) == 0x20) return false;
            if (c == 0xE0 && (bytes[i+1] & 0x20) == 0) return false;
        }
        if (nb == 4) {
            if (c > 0xF4) return false;
            if (c == 0xF0 && (bytes[i+1] & 0x30) == 0) return false;
            if (c == 0xF4 && bytes[i+1] > 0x8F) return false;
        }
        i += nb;
    }
    return true;
}

static std::string sanitizeUTF8(const char* str, size_t len) {
    if (!str || len == 0) return "";
    if (isValidUTF8(str, len)) return std::string(str, len);
    std::string result;
    result.reserve(len);
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    while (i < len) {
        unsigned char c = bytes[i];
        if ((c & 0x80) == 0) { result += c; i++; continue; }
        int nb = 0;
        if      ((c & 0xE0) == 0xC0) nb = 2;
        else if ((c & 0xF0) == 0xE0) nb = 3;
        else if ((c & 0xF8) == 0xF0) nb = 4;
        else { result += "\xEF\xBF\xBD"; i++; continue; }
        if (i + nb > len) { result += "\xEF\xBF\xBD"; break; }
        std::string seq(reinterpret_cast<const char*>(bytes + i), nb);
        if (isValidUTF8(seq.c_str(), nb)) result += seq;
        else result += "\xEF\xBF\xBD";
        i += nb;
    }
    return result;
}

@implementation LlamaIosWrapper

- (void)loadModelAtPath:(NSString*)path
               nThreads:(int)nThreads
            contextSize:(int)contextSize
             nGpuLayers:(int)nGpuLayers
       progressCallback:(LlamaProgressCallback)progressCallback {

    const char* model_path = [path UTF8String];
    LOGI("Loading model: %s", model_path);

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = nGpuLayers;

    g_model = llama_model_load_from_file(model_path, model_params);
    if (!g_model) {
        LOGE("Failed to load model");
        [NSException raise:@"LlamaLoadError" format:@"Failed to load model at path: %@", path];
    }

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx           = contextSize;
    ctx_params.n_threads       = nThreads;
    ctx_params.n_threads_batch = nThreads;
    ctx_params.n_batch         = 512;

    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (!g_ctx) {
        llama_model_free(g_model);
        g_model = nullptr;
        [NSException raise:@"LlamaContextError" format:@"Failed to create context"];
    }

    g_vocab = llama_model_get_vocab(g_model);
    if (!g_vocab) {
        llama_free(g_ctx);
        llama_model_free(g_model);
        g_ctx = nullptr;
        g_model = nullptr;
        [NSException raise:@"LlamaVocabError" format:@"Failed to get vocab"];
    }

    g_n_past = 0;
    LOGI("Model loaded successfully");
    if (progressCallback) progressCallback(1.0);
}

- (void)generateWithPrompt:(NSString*)prompt
                 maxTokens:(int)maxTokens
               temperature:(double)temperature
                      topP:(double)topP
                      topK:(int)topK
                      minP:(double)minP
                  typicalP:(double)typicalP
             repeatPenalty:(double)repeatPenalty
         frequencyPenalty:(double)frequencyPenalty
          presencePenalty:(double)presencePenalty
              repeatLastN:(int)repeatLastN
                 mirostat:(int)mirostat
              mirostatTau:(double)mirostatTau
              mirostatEta:(double)mirostatEta
                     seed:(long long)seed
         penalizeNewline:(BOOL)penalizeNewline
            tokenCallback:(LlamaTokenCallback)tokenCallback {

    if (!g_model || !g_ctx || !g_vocab) {
        [NSException raise:@"LlamaStateError" format:@"Model not loaded"];
    }

    g_stop_flag = false;

    const char* prompt_str = [prompt UTF8String];
    const int prompt_len = (int)strlen(prompt_str);
    std::string sanitized = sanitizeUTF8(prompt_str, prompt_len);

    // Count tokens
    const int n_prompt_tokens = -llama_tokenize(g_vocab, sanitized.c_str(), (int)sanitized.size(), nullptr, 0, true, true);
    if (n_prompt_tokens <= 0) {
        [NSException raise:@"LlamaTokenizeError" format:@"Failed to tokenize prompt (%d tokens)", n_prompt_tokens];
    }

    std::vector<llama_token> tokens(n_prompt_tokens);
    const int actual = llama_tokenize(g_vocab, sanitized.c_str(), (int)sanitized.size(), tokens.data(), (int)tokens.size(), true, true);
    if (actual < 0) {
        [NSException raise:@"LlamaTokenizeError" format:@"Tokenize failed"];
    }
    tokens.resize(actual);

    const int n_ctx = llama_n_ctx(g_ctx);

    // Sliding window KV cache (mirrors Android: discard oldest 25%)
    if (g_n_past + (int)tokens.size() > n_ctx) {
        const int n_discard = n_ctx / 4;
        LOGI("Context full, shifting KV cache by %d tokens", n_discard);
        llama_memory_seq_rm(llama_get_memory(g_ctx), 0, 0, n_discard);
        llama_memory_seq_add(llama_get_memory(g_ctx), 0, n_discard, -1, -n_discard);
        g_n_past = std::max(0, g_n_past - n_discard);
    }

    // Decode prompt in batches
    {
        llama_batch batch = llama_batch_init(512, 0, 1);
        int i = 0;
        while (i < (int)tokens.size()) {
            batch.n_tokens = 0;
            while (batch.n_tokens < 512 && i < (int)tokens.size()) {
                batch.token[batch.n_tokens]     = tokens[i];
                batch.pos[batch.n_tokens]       = g_n_past + i;
                batch.n_seq_id[batch.n_tokens]  = 1;
                batch.seq_id[batch.n_tokens][0] = 0;
                batch.logits[batch.n_tokens]    = (i == (int)tokens.size() - 1) ? 1 : 0;
                batch.n_tokens++;
                i++;
            }
            if (llama_decode(g_ctx, batch) != 0) {
                llama_batch_free(batch);
                [NSException raise:@"LlamaDecodeError" format:@"llama_decode failed during prompt evaluation"];
            }
        }
        g_n_past += (int)tokens.size();
        llama_batch_free(batch);
    }

    // Build sampler chain — mirrors jni_wrapper.cpp exactly
    if (g_sampler) { llama_sampler_free(g_sampler); g_sampler = nullptr; }
    llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
    g_sampler = llama_sampler_chain_init(chain_params);

    uint32_t seed_val = (seed < 0) ? (uint32_t)time(nullptr) : (uint32_t)seed;

    // Penalties first (applied to logits before sampling)
    if (repeatPenalty != 1.0 || frequencyPenalty != 0.0 || presencePenalty != 0.0) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_penalties(
            repeatLastN,
            (float)repeatPenalty,
            (float)frequencyPenalty,
            (float)presencePenalty
        ));
    }

    // Temperature
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp((float)temperature));

    if (mirostat == 1) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat(
            llama_vocab_n_tokens(g_vocab),
            seed_val,
            (float)mirostatTau,
            (float)mirostatEta,
            100
        ));
    } else if (mirostat == 2) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat_v2(
            seed_val,
            (float)mirostatTau,
            (float)mirostatEta
        ));
    } else {
        if (minP > 0.0 && minP < 1.0)
            llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p((float)minP, 1));
        if (typicalP < 1.0)
            llama_sampler_chain_add(g_sampler, llama_sampler_init_typical((float)typicalP, 1));
        if (topK > 0)
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(topK));
        if (topP < 1.0)
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p((float)topP, 1));
    }

    // Final distribution sampler
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(seed_val));

    // Generation loop
    const llama_token eos_token = llama_vocab_eos(g_vocab);
    std::string partial_token;

    for (int i = 0; i < maxTokens && !g_stop_flag; i++) {
        llama_token token_id = llama_sampler_sample(g_sampler, g_ctx, -1);

        if (token_id == eos_token || llama_vocab_is_eog(g_vocab, token_id)) break;

        // Decode token to text
        char buf[256] = {0};
        int n = llama_token_to_piece(g_vocab, token_id, buf, sizeof(buf) - 1, 0, true);
        if (n < 0) n = 0;
        buf[n] = '\0';

        partial_token += std::string(buf, n);

        // Emit complete UTF-8 sequences only
        if (isValidUTF8(partial_token.c_str(), partial_token.size())) {
            NSString* tokenStr = [NSString stringWithUTF8String:partial_token.c_str()];
            if (tokenStr && tokenCallback && !g_stop_flag) tokenCallback(tokenStr);
            partial_token.clear();
        }

        // Advance KV cache
        llama_batch next_batch = llama_batch_init(1, 0, 1);
        next_batch.token[0]     = token_id;
        next_batch.pos[0]       = g_n_past;
        next_batch.n_seq_id[0]  = 1;
        next_batch.seq_id[0][0] = 0;
        next_batch.logits[0]    = 1;
        next_batch.n_tokens     = 1;
        if (llama_decode(g_ctx, next_batch) != 0) {
            llama_batch_free(next_batch);
            break;
        }
        llama_batch_free(next_batch);
        g_n_past++;
    }

    // Emit remaining partial token
    if (!partial_token.empty() && !g_stop_flag) {
        std::string safe = sanitizeUTF8(partial_token.c_str(), partial_token.size());
        NSString* tokenStr = [NSString stringWithUTF8String:safe.c_str()];
        if (tokenStr && tokenCallback) tokenCallback(tokenStr);
    }
}

- (void)stop {
    g_stop_flag = true;
}

- (void)freeModel {
    if (g_sampler) { llama_sampler_free(g_sampler); g_sampler = nullptr; }
    if (g_ctx)     { llama_free(g_ctx);              g_ctx     = nullptr; }
    if (g_model)   { llama_model_free(g_model);      g_model   = nullptr; }
    g_vocab  = nullptr;
    g_n_past = 0;
}

- (BOOL)isModelLoaded {
    return g_model != nullptr && g_ctx != nullptr;
}

- (int)tokensUsed {
    return g_n_past;
}

- (int)contextSize {
    if (!g_ctx) return 0;
    return (int)llama_n_ctx(g_ctx);
}

- (void)clearContext {
    if (g_ctx) {
        llama_memory_seq_rm(llama_get_memory(g_ctx), 0, g_system_prompt_length, -1);
        g_n_past = g_system_prompt_length;
        LOGI("Context cleared, keeping %d system prompt tokens", g_system_prompt_length);
    }
}

- (void)setSystemPromptLength:(int)length {
    g_system_prompt_length = length;
}

@end
