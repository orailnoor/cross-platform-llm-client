#include <jni.h>
#include <string>
#include <vector>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <thread>
#include <cstring>
#include <fstream>
#include <mutex>
#include <android/log.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <dlfcn.h>
#include <setjmp.h>
#include <signal.h>
#include "llama.cpp/include/llama.h"
#include "llama.cpp/ggml/include/ggml-backend.h"
#include "llama.cpp/ggml/include/gguf.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#define LOG_TAG "LlamaJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static const llama_vocab* g_vocab = nullptr;
static llama_sampler* g_sampler = nullptr;
static std::atomic<bool> g_stop_flag{false};
static int g_n_past = 0;  // Track the number of tokens already in KV cache
// Exactly the tokens held in the KV cache (sequence 0), in order. Lets each
// turn reuse the cached prefix it shares with the previous prompt + reply
// instead of re-feeding (and duplicating) the whole conversation.
static std::vector<llama_token> g_cached_tokens;
// Vision projector (mmproj) for multimodal GGUF models; null when text-only.
static mtmd_context* g_mtmd = nullptr;
// False after a turn that contained an image: those image embeddings aren't
// representable in g_cached_tokens, so the next turn must not reuse the cache.
static bool g_cache_reusable = true;
static std::mutex g_load_log_mutex;
static std::string g_load_error;
static bool g_capture_load_error = false;
// "<buffer name>\t<MiB>" per weight buffer of the last model load, from
// llama.cpp's "model buffer size" lines. Cluster workers' buffers are named
// "RPC<n>[host:port]"; everything else is on this phone.
static std::string g_load_buffers;
// Cluster worker: address of the master currently connected, empty if none.
static std::string g_worker_peer;

// ---------------------------------------------------------------------------
// Runtime backend loading (GGML_BACKEND_DL)
//
// Backends ship as separate modules in the app's native library dir:
//  - libggml-cpu-android_*.so, one per Arm generation. The fastest variant
//    this CPU supports is loaded (each reports a score; 0 = unsupported).
//  - libggml-vulkan.so, loaded only when the app explicitly allows the GPU.
//    Merely registering it initialises Vulkan, which some drivers can't
//    handle, so phones that aren't allowed GPU never load it at all.
// ---------------------------------------------------------------------------
static void androidLlamaLog(ggml_log_level level, const char* text, void*);

static std::mutex g_backend_mutex;
static std::string g_lib_dir;
static bool g_cpu_backend_loaded = false;
static bool g_gpu_backend_loaded = false;
static bool g_rpc_backend_loaded = false;

#ifdef LLAMA_JNI_BACKEND_DL
// Best first. The armv9 (SVE2/SME) variants are deliberately excluded: on a
// Pixel 8 (Tensor G3) the SVE2 repack path produced out-of-range values and
// aborted on the first decode, so they aren't shipped or loaded.
static const char* const kCpuVariants[] = {
    "android_armv8.6_1", "android_armv8.2_2", "android_armv8.2_1",
    "android_armv8.0_1",
};

// Some kernels don't report CPU features the cores have. The Poco F1's
// LineageOS 4.9 kernel leaves dot-product (asimddp) and FP16 (asimdhp) out of
// HWCAP, so ggml picks the plain armv8.0 build, several times slower at
// quantized matmuls. Instead of trusting HWCAP, run one instruction of each
// kind and catch SIGILL if the core can't.
static sigjmp_buf g_probe_jmp;
static void probeSigill(int) { siglongjmp(g_probe_jmp, 1); }

static bool cpuRuns(void (*probe)()) {
    struct sigaction ill = {}, old = {};
    ill.sa_handler = probeSigill;
    sigemptyset(&ill.sa_mask);
    sigaction(SIGILL, &ill, &old);
    bool ok = false;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        probe();
        ok = true;
    }
    sigaction(SIGILL, &old, nullptr);
    return ok;
}

#if defined(__aarch64__)
// Raw encodings, so the assembler needs no +dotprod/+fp16 flags.
static void probeDotprod() { asm volatile(".inst 0x4e829420" ::: "v0"); }  // sdot v0.4s, v1.16b, v2.16b
static void probeFp16() { asm volatile(".inst 0x4e421420" ::: "v0"); }     // fadd v0.8h, v1.8h, v2.8h
#else
static void probeDotprod() {}
static void probeFp16() {}
#endif

/// Loads a CPU variant without ggml's HWCAP-based score check (which
/// load_backend enforces). Only for features probed above.
static bool loadCpuVariantUnchecked(const std::string& path) {
    void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) return false;
    using init_fn = ggml_backend_reg_t (*)();
    auto init = reinterpret_cast<init_fn>(dlsym(handle, "ggml_backend_init"));
    ggml_backend_reg_t reg = init ? init() : nullptr;
    if (!reg) {
        dlclose(handle);
        return false;
    }
    ggml_backend_register(reg);  // the library stays loaded for the app's life
    return true;
}

static void loadCpuBackendLocked() {
    if (g_cpu_backend_loaded) return;
    std::string best_path;
    std::string best_name;
    int best_score = 0;
    for (const char* variant : kCpuVariants) {
        const std::string path = g_lib_dir + "/libggml-cpu-" + variant + ".so";
        void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) continue;
        using score_fn = int (*)();
        auto score = reinterpret_cast<score_fn>(dlsym(handle, "ggml_backend_score"));
        const int value = score ? score() : 0;
        dlclose(handle);
        if (value > best_score) {
            best_score = value;
            best_path = path;
            best_name = variant;
        }
    }
    if (best_name == "android_armv8.0_1" && cpuRuns(probeDotprod)) {
        const char* variant = cpuRuns(probeFp16) ? "android_armv8.2_2" : "android_armv8.2_1";
        const std::string path = g_lib_dir + "/libggml-cpu-" + variant + ".so";
        if (loadCpuVariantUnchecked(path)) {
            g_cpu_backend_loaded = true;
            LOGI("CPU backend: %s (kernel hides these features; probed them instead)", variant);
            return;
        }
    }
    if (!best_path.empty() && ggml_backend_load(best_path.c_str())) {
        g_cpu_backend_loaded = true;
        LOGI("CPU backend: %s (score %d)", best_name.c_str(), best_score);
    } else {
        LOGE("No CPU backend could be loaded from %s", g_lib_dir.c_str());
    }
}

static bool loadGpuBackendLocked() {
    if (g_gpu_backend_loaded) return true;
    const std::string path = g_lib_dir + "/libggml-vulkan.so";
    if (ggml_backend_load(path.c_str())) {
        g_gpu_backend_loaded = true;
        LOGI("Vulkan backend loaded");
    } else {
        LOGE("Vulkan backend unavailable (%s)", path.c_str());
    }
    return g_gpu_backend_loaded;
}

/// The RPC backend registry (phone cluster), loading it on first use.
static ggml_backend_reg_t loadRpcBackendLocked() {
    if (!g_rpc_backend_loaded) {
        const std::string path = g_lib_dir + "/libggml-rpc.so";
        if (!ggml_backend_load(path.c_str())) {
            LOGE("RPC backend unavailable (%s)", path.c_str());
            return nullptr;
        }
        g_rpc_backend_loaded = true;
        LOGI("RPC backend loaded");
    }
    return ggml_backend_reg_by_name("RPC");
}
#else
static void loadCpuBackendLocked() { g_cpu_backend_loaded = true; }
static bool loadGpuBackendLocked() { return false; }
static ggml_backend_reg_t loadRpcBackendLocked() { return nullptr; }
#endif

static void ensureCpuBackend() {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    loadCpuBackendLocked();
}

/// Cluster workers show up as GPU devices named "RPC<n>"; they must never be
/// mistaken for this phone's own GPU.
static bool isRpcDevice(ggml_backend_dev_t dev) {
    const char* name = ggml_backend_dev_name(dev);
    return name && std::strncmp(name, "RPC", 3) == 0;
}

/// First local GPU device registered by a loaded backend, or nullptr.
static ggml_backend_dev_t firstGpuDevice() {
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const auto type = ggml_backend_dev_type(dev);
        if ((type == GGML_BACKEND_DEVICE_TYPE_GPU ||
             type == GGML_BACKEND_DEVICE_TYPE_IGPU) && !isRpcDevice(dev)) {
            return dev;
        }
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// Phone cluster (RPC backend)
//
// A worker phone serves its CPU over ggml's RPC protocol. The coordinator adds
// each worker as a remote device and offloads the model's last layers to them;
// workers only ever see tensors, never the prompt text. The cluster set here
// applies to the next nativeLoadModel call.
// ---------------------------------------------------------------------------
static std::vector<std::string> g_cluster_endpoints;
static std::vector<float> g_cluster_weights;  // one per endpoint
static float g_cluster_local_weight = 0.0f;
static std::vector<std::string> g_registered_endpoints;

static std::string jstringToStd(JNIEnv* env, jstring value) {
    if (!value) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return {};
    std::string out(chars);
    env->ReleaseStringUTFChars(value, chars);
    return out;
}

/// The model's transformer block count from its GGUF header, or -1.
static int readBlockCount(const char* model_path) {
    gguf_init_params params = {/* .no_alloc = */ true, /* .ctx = */ nullptr};
    gguf_context* gguf = gguf_init_from_file(model_path, params);
    if (!gguf) return -1;
    int count = -1;
    const int64_t arch_id = gguf_find_key(gguf, "general.architecture");
    if (arch_id >= 0) {
        const std::string key = std::string(gguf_get_val_str(gguf, arch_id)) + ".block_count";
        const int64_t id = gguf_find_key(gguf, key.c_str());
        if (id >= 0) {
            switch (gguf_get_kv_type(gguf, id)) {
                case GGUF_TYPE_UINT32: count = (int)gguf_get_val_u32(gguf, id); break;
                case GGUF_TYPE_INT32:  count = gguf_get_val_i32(gguf, id); break;
                default: break;
            }
        }
    }
    gguf_free(gguf);
    return count;
}

struct ClusterPlan {
    std::vector<ggml_backend_dev_t> devices;  // null-terminated
    std::vector<float> split;                 // llama_max_devices() entries
    int n_gpu_layers = 0;
    llama_model_tensor_buft_override overrides[2] = {};
};

/// Connects to every configured worker and decides which layers go where:
/// this phone keeps the first layers (by its weight), workers get the rest
/// split by theirs. Returns an error message, or empty on success.
static std::string planCluster(const char* model_path, ClusterPlan& plan) {
    std::vector<std::string> endpoints;
    std::vector<float> weights;
    float local_weight;
    ggml_backend_reg_t rpc;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        endpoints = g_cluster_endpoints;
        weights = g_cluster_weights;
        local_weight = g_cluster_local_weight;
        rpc = loadRpcBackendLocked();
    }
    if (!rpc) return "This build has no cluster (RPC) support";
    using add_server_fn = ggml_backend_reg_t (*)(const char*);
    auto add_server = reinterpret_cast<add_server_fn>(
        ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_add_server"));
    if (!add_server) return "RPC backend is missing ggml_backend_rpc_add_server";

    const int n_layer = readBlockCount(model_path);
    if (n_layer <= 0) return "Could not read the model's layer count";

    float remote_weight = 0.0f;
    std::vector<float> device_weights;
    for (size_t i = 0; i < endpoints.size(); i++) {
        // Aborts the process if the worker can't be reached, so the app
        // probes each worker over TCP before calling setCluster.
        ggml_backend_reg_t reg = add_server(endpoints[i].c_str());
        if (!reg) return "Worker " + endpoints[i] + " reported no devices";
        if (std::find(g_registered_endpoints.begin(), g_registered_endpoints.end(),
                      endpoints[i]) == g_registered_endpoints.end()) {
            ggml_backend_register(reg);
            g_registered_endpoints.push_back(endpoints[i]);
        }
        const size_t n_dev = ggml_backend_reg_dev_count(reg);
        for (size_t d = 0; d < n_dev; d++) {
            plan.devices.push_back(ggml_backend_reg_dev_get(reg, d));
            device_weights.push_back(std::max(weights[i], 0.01f) / n_dev);
        }
        remote_weight += std::max(weights[i], 0.01f);
    }
    if (plan.devices.empty()) return "No cluster workers";
    plan.devices.push_back(nullptr);

    plan.split.assign(llama_max_devices(), 0.0f);
    for (size_t d = 0; d < device_weights.size() && d < plan.split.size(); d++) {
        plan.split[d] = device_weights[d];
    }

    // llama.cpp offloads the *last* n_gpu_layers blocks (+1 for the output
    // layer), so keeping `local` blocks here means offloading the rest.
    const float total = std::max(local_weight, 0.0f) + remote_weight;
    int local = (int)std::lround(n_layer * std::max(local_weight, 0.0f) / total);
    local = std::clamp(local, 0, n_layer);
    plan.n_gpu_layers = n_layer + 1 - local;

    // The output layer goes with the last offloaded layer, i.e. a worker.
    // It's the biggest single matmul per token (vocab x hidden) and its
    // result, a score per vocab entry (~600 KB), would cross Wi-Fi on every
    // token. Keep its weights here instead (tied models reuse token_embd).
    ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (cpu) {
        plan.overrides[0] = {"^(output|token_embd)\\.weight$", ggml_backend_dev_buffer_type(cpu)};
        plan.overrides[1] = {nullptr, nullptr};
    }
    LOGI("Cluster: %d of %d layers local, rest on %zu worker device(s), output layer local",
         local, n_layer, device_weights.size());
    return {};
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeSetCluster(
        JNIEnv* env, jobject /* this */, jobjectArray endpoints, jfloatArray weights,
        jfloat local_weight) {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    g_cluster_endpoints.clear();
    g_cluster_weights.clear();
    g_cluster_local_weight = local_weight;
    const jsize n = endpoints ? env->GetArrayLength(endpoints) : 0;
    const jsize n_weights = weights ? env->GetArrayLength(weights) : 0;
    std::vector<jfloat> w(n_weights);
    if (n_weights > 0) env->GetFloatArrayRegion(weights, 0, n_weights, w.data());
    for (jsize i = 0; i < n; i++) {
        auto item = static_cast<jstring>(env->GetObjectArrayElement(endpoints, i));
        g_cluster_endpoints.push_back(jstringToStd(env, item));
        g_cluster_weights.push_back(i < n_weights ? w[i] : 1.0f);
        env->DeleteLocalRef(item);
    }
    LOGI("Cluster set: %zu worker(s)", g_cluster_endpoints.size());
}

/// Where the last model load put its weights: "<buffer name>\t<MiB>" lines.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeLastLoadBuffers(
        JNIEnv* env, jobject /* this */) {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return env->NewStringUTF(g_load_buffers.c_str());
}

/// Cluster worker: the connected master's address, or null.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeWorkerPeer(
        JNIEnv* env, jobject /* this */) {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return g_worker_peer.empty() ? nullptr : env->NewStringUTF(g_worker_peer.c_str());
}

/// Memory read speed in GB/s with `threads` threads. Token generation is
/// limited by how fast weights stream from RAM, so this ranks phones for the
/// cluster better than core counts or clock speeds do. Takes ~0.2 s.
extern "C" JNIEXPORT jdouble JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeMemBandwidth(
        JNIEnv* /* env */, jobject /* this */, jint threads) {
    const int n = std::max(1, (int)threads);
    const size_t per_thread = (64u << 20) / sizeof(uint64_t) / n;  // 64 MB total
    std::vector<uint64_t> data(per_thread * n, 1);
    std::vector<uint64_t> sums(n, 0);
    const int passes = 4;
    auto run = [&](int t) {
        const uint64_t* p = data.data() + per_thread * t;
        uint64_t a = 0, b = 0, c = 0, d = 0;
        for (int pass = 0; pass < passes; pass++) {
            for (size_t i = 0; i + 4 <= per_thread; i += 4) {
                a += p[i]; b += p[i + 1]; c += p[i + 2]; d += p[i + 3];
            }
        }
        sums[t] = a + b + c + d;
    };
    run(0);  // warm up: page in the buffer
    const auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (int t = 0; t < n; t++) pool.emplace_back(run, t);
    for (auto& th : pool) th.join();
    const double secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    const double bytes = (double)data.size() * sizeof(uint64_t) * passes;
    LOGI("Memory bandwidth: %.1f GB/s (%d threads, check %llu)", bytes / secs / 1e9, n,
         (unsigned long long)sums[0]);
    return secs > 0 ? bytes / secs / 1e9 : 0.0;
}

// Keeps this device's Wi-Fi radio awake while a master is connected. Phones
// and iPads doze the radio between packets (tens to 200+ ms to wake), and
// every token makes a few round trips to each worker. A device that is
// transmitting stays out of power save, so send the master one tiny UDP
// datagram (discard port 9) every 20 ms: ~50 bytes/s. Measured iPad latency
// from the master: 28 ms average with 111 ms spikes when idle.
static void runRadioKeepAwake(const std::atomic<bool>& running, std::string (*peer)()) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    const char byte = 0;
    while (running) {
        const std::string ip = peer();
        if (ip.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        sockaddr_in to = {};
        to.sin_family = AF_INET;
        to.sin_port = htons(9);
        if (inet_pton(AF_INET, ip.c_str(), &to.sin_addr) == 1) {
            sendto(fd, &byte, 1, 0, (const sockaddr*)&to, sizeof(to));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    close(fd);
}

static std::atomic<bool> g_worker_running{false};

static std::string currentWorkerPeer() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return g_worker_peer;
}

/// Runs this phone as a cluster worker. Blocks for as long as the server
/// runs (ggml has no way to stop it), so it lives in its own process; only
/// returns, with the reason, if the server couldn't start.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeServe(
        JNIEnv* env, jobject /* this */, jstring lib_dir, jstring endpoint,
        jstring cache_dir, jlong n_threads) {
    ggml_backend_reg_t rpc;
    ggml_backend_dev_t cpu;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        if (g_lib_dir.empty()) g_lib_dir = jstringToStd(env, lib_dir);
        llama_log_set(androidLlamaLog, nullptr);
        loadCpuBackendLocked();
        rpc = loadRpcBackendLocked();
        cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    }
    if (!rpc) return env->NewStringUTF("This build has no cluster (RPC) support");
    if (!cpu) return env->NewStringUTF("No CPU backend could be loaded");
    using start_fn = void (*)(const char*, const char*, size_t, size_t, ggml_backend_dev_t*);
    auto start = reinterpret_cast<start_fn>(
        ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_start_server"));
    if (!start) return env->NewStringUTF("RPC backend is missing its server");

    const std::string ep = jstringToStd(env, endpoint);
    const std::string cache = jstringToStd(env, cache_dir);
    LOGI("Cluster worker listening on %s (cache %s)", ep.c_str(), cache.c_str());
    g_worker_running = true;
    std::thread([] { runRadioKeepAwake(g_worker_running, currentWorkerPeer); }).detach();
    start(ep.c_str(), cache.empty() ? nullptr : cache.c_str(),
          (size_t)std::max<jlong>(1, n_threads), 1, &cpu);
    g_worker_running = false;
    return env->NewStringUTF("Worker stopped: the port may already be in use");
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeInitBackends(
        JNIEnv* env, jobject /* this */, jstring lib_dir, jboolean allow_gpu) {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    if (g_lib_dir.empty() && lib_dir) {
        const char* dir = env->GetStringUTFChars(lib_dir, nullptr);
        if (dir) {
            g_lib_dir = dir;
            env->ReleaseStringUTFChars(lib_dir, dir);
        }
    }
    llama_log_set(androidLlamaLog, nullptr);
    loadCpuBackendLocked();
    if (allow_gpu == JNI_TRUE) loadGpuBackendLocked();
    return g_gpu_backend_loaded && firstGpuDevice() != nullptr ? JNI_TRUE : JNI_FALSE;
}

// CONT lines continue the previous message; drop them when it was DEBUG.
static ggml_log_level g_last_log_level = GGML_LOG_LEVEL_INFO;

static void androidLlamaLog(ggml_log_level level, const char* text, void*) {
    if (!text) return;
    // Newer llama.cpp logs thousands of DEBUG lines per model load (graph
    // dumps); forwarding them to logcat slows loading for no benefit.
    const ggml_log_level effective =
        level == GGML_LOG_LEVEL_CONT ? g_last_log_level : level;
    if (level != GGML_LOG_LEVEL_CONT) g_last_log_level = level;
    if (effective == GGML_LOG_LEVEL_DEBUG) return;

    const int priority = effective == GGML_LOG_LEVEL_ERROR
        ? ANDROID_LOG_ERROR
        : effective == GGML_LOG_LEVEL_WARN
            ? ANDROID_LOG_WARN
            : ANDROID_LOG_INFO;
    __android_log_write(priority, LOG_TAG, text);

    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    if (const char* at = std::strstr(text, " model buffer size = ")) {
        // "load_tensors: <name> model buffer size = <MiB> MiB"
        const char* colon = std::strchr(text, ':');
        const char* start = colon && colon < at ? colon + 1 : text;
        while (start < at && *start == ' ') start++;
        const double mib = std::strtod(at + std::strlen(" model buffer size = "), nullptr);
        g_load_buffers.append(start, at - start).append("\t")
            .append(std::to_string(mib)).append("\n");
    }
    static const char kConnected[] = "RPC client connected: ";
    if (std::strncmp(text, kConnected, sizeof(kConnected) - 1) == 0) {
        g_worker_peer.assign(text + sizeof(kConnected) - 1);
        while (!g_worker_peer.empty() && std::isspace((unsigned char)g_worker_peer.back())) {
            g_worker_peer.pop_back();
        }
    } else if (std::strncmp(text, "RPC client disconnected", 23) == 0) {
        g_worker_peer.clear();
    }
    if (!g_capture_load_error) return;
    if (level == GGML_LOG_LEVEL_ERROR) {
        g_load_error.assign(text);
    } else if (level == GGML_LOG_LEVEL_CONT && !g_load_error.empty()) {
        g_load_error.append(text);
    }
    if (g_load_error.size() > 4096) {
        g_load_error.erase(0, g_load_error.size() - 4096);
    }
}

static std::string consumeLoadError() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    g_capture_load_error = false;
    while (!g_load_error.empty() &&
           (g_load_error.back() == '\n' || g_load_error.back() == '\r')) {
        g_load_error.pop_back();
    }
    return g_load_error;
}

static void throwLoadError(JNIEnv* env, const std::string& message) {
    LOGE("%s", message.c_str());
    jclass exception = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(exception, message.c_str());
}

// Helper function to validate UTF-8 strings
static bool isValidUTF8(const char* str, size_t len) {
    if (!str) return false;
    
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    
    while (i < len) {
        unsigned char c = bytes[i];
        
        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            i++;
            continue;
        }
        
        // Multi-byte sequence start (110xxxxx, 1110xxxx, or 11110xxx)
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2; // 110xxxxx
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3; // 1110xxxx
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4; // 11110xxx
        } else {
            // Invalid first byte
            return false;
        }
        
        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            return false;
        }
        
        // Check continuation bytes (10xxxxxx)
        for (int j = 1; j < num_bytes; j++) {
            if ((bytes[i + j] & 0xC0) != 0x80) {
                return false;
            }
        }
        
        // Check for overlong encodings and invalid code points
        if (num_bytes == 2) {
            // Overlong encoding of ASCII character
            if ((c & 0x1E) == 0) return false;
        } else if (num_bytes == 3) {
            // Invalid surrogate halves (U+D800-U+DFFF)
            if (c == 0xED && (bytes[i + 1] & 0x20) == 0x20) return false;
            // Overlong encoding
            if (c == 0xE0 && (bytes[i + 1] & 0x20) == 0) return false;
        } else if (num_bytes == 4) {
            // Out of Unicode range (> U+10FFFF)
            if (c > 0xF4) return false;
            // Overlong encoding
            if (c == 0xF0 && (bytes[i + 1] & 0x30) == 0) return false;
            // Invalid code points (> U+10FFFF)
            if (c == 0xF4 && bytes[i + 1] > 0x8F) return false;
        }
        
        i += num_bytes;
    }
    
    return true;
}

// Helper function to sanitize UTF-8 strings
static std::string sanitizeUTF8(const char* str, size_t len) {
    if (!str || len == 0) return "";
    
    // First try to validate as-is
    if (isValidUTF8(str, len)) {
        return std::string(str, len);
    }
    
    // If invalid, create a sanitized version
    std::string result;
    result.reserve(len);
    
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    
    while (i < len) {
        unsigned char c = bytes[i];
        
        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            result += c;
            i++;
            continue;
        }
        
        // Multi-byte sequence start
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2;
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3;
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4;
        } else {
            // Invalid first byte, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
            i++;
            continue;
        }
        
        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            result += "\xEF\xBF\xBD"; // 
            break;
        }
        
        // Extract the sequence
        std::string seq(reinterpret_cast<const char*>(bytes + i), num_bytes);
        
        // Validate the sequence
        if (isValidUTF8(seq.c_str(), num_bytes)) {
            result += seq;
        } else {
            // Invalid sequence, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
        }
        
        i += num_bytes;
    }
    
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeDetectGpu(
        JNIEnv* env, jobject /* this */, jlongArray outStats) {

    // Zero out output array as safe default (-1 = unknown)
    jlong defaults[2] = {-1L, -1L};
    env->SetLongArrayRegion(outStats, 0, 2, defaults);

    // Only reports a GPU if the app already allowed and loaded the Vulkan
    // backend (nativeInitBackends); this never initialises Vulkan itself.
    ggml_backend_dev_t dev = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        if (!g_gpu_backend_loaded) {
            LOGI("nativeDetectGpu: GPU backend not loaded");
            return nullptr;
        }
        dev = firstGpuDevice();
    }
    if (!dev) {
        LOGI("nativeDetectGpu: no Vulkan GPU device");
        return nullptr;
    }
    size_t free_mem = 0, total_mem = 0;
    ggml_backend_dev_memory(dev, &free_mem, &total_mem);
    jlong stats[2] = {-1L, static_cast<jlong>(total_mem)};
    env->SetLongArrayRegion(outStats, 0, 2, stats);
    const char* desc = ggml_backend_dev_description(dev);
    LOGI("nativeDetectGpu: %s (%zu MB)", desc, total_mem / (1024 * 1024));
    return env->NewStringUTF(desc ? desc : "GPU");
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadModel(
    JNIEnv* env, jobject thiz,
    jstring path, jlong n_threads, jlong ctx_size, jlong n_gpu_layers,
    jobject progress_callback) {
    
    if (!path) {
        throwLoadError(env, "GGUF model path is missing");
        return;
    }

    const char* model_path = env->GetStringUTFChars(path, nullptr);
    if (!model_path) {
        throwLoadError(env, "Could not read the GGUF model path");
        return;
    }
    LOGI("Loading model: %s", model_path);

    std::ifstream model_file(model_path, std::ios::binary | std::ios::ate);
    if (!model_file) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "GGUF model file is missing or unreadable");
        return;
    }
    const std::streamsize model_size = model_file.tellg();
    if (model_size < 4) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "GGUF model file is empty or incomplete");
        return;
    }
    model_file.seekg(0, std::ios::beg);
    char magic[4] = {};
    model_file.read(magic, sizeof(magic));
    if (!model_file || std::memcmp(magic, "GGUF", sizeof(magic)) != 0) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "Invalid GGUF model header");
        return;
    }
    model_file.close();

    ensureCpuBackend();

    // Model parameters
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = n_gpu_layers;
    // With no GPU layers requested, give llama.cpp an empty device list so
    // it can't touch a GPU at all (even if the Vulkan backend is loaded).
    static ggml_backend_dev_t no_gpu_devices[] = {nullptr};
    // Otherwise name the local GPU explicitly: once cluster workers are
    // registered, llama.cpp's default device list would include them too.
    ggml_backend_dev_t local_gpu_devices[] = {firstGpuDevice(), nullptr};
    if (n_gpu_layers == 0) {
        model_params.devices = no_gpu_devices;
    } else {
        model_params.devices = local_gpu_devices;
    }

    // Cluster mode: this phone runs on its CPU and the workers hold the rest.
    ClusterPlan cluster;
    bool has_cluster;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        has_cluster = !g_cluster_endpoints.empty();
    }
    if (has_cluster) {
        const std::string error = planCluster(model_path, cluster);
        if (!error.empty()) {
            env->ReleaseStringUTFChars(path, model_path);
            throwLoadError(env, "Cluster: " + error);
            return;
        }
        model_params.devices = cluster.devices.data();
        model_params.tensor_split = cluster.split.data();
        model_params.n_gpu_layers = cluster.n_gpu_layers;
        if (cluster.overrides[0].pattern) {
            model_params.tensor_buft_overrides = cluster.overrides;
        }
    }

    llama_log_set(androidLlamaLog, nullptr);
    {
        std::lock_guard<std::mutex> lock(g_load_log_mutex);
        g_load_error.clear();
        g_load_buffers.clear();
        g_capture_load_error = true;
    }

    // Load model
    g_model = llama_model_load_from_file(model_path, model_params);
    env->ReleaseStringUTFChars(path, model_path);
    
    if (!g_model) {
        const std::string detail = consumeLoadError();
        const std::string message = detail.empty()
            ? "Failed to load GGUF model; check model compatibility and available RAM"
            : "Failed to load GGUF model: " + detail;
        throwLoadError(env, message);
        return;
    }
    consumeLoadError();

    // Context parameters with memory optimizations for low-end devices
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = ctx_size;
    ctx_params.n_threads = n_threads;
    ctx_params.n_threads_batch = n_threads;
    
    // Memory optimization: reduce memory usage by limiting batch processing
    ctx_params.n_batch = 512;  // Process smaller batches to reduce memory spikes
    // Don't push CPU-resident tensor ops to the GPU in CPU-only mode, nor
    // over Wi-Fi to a worker in cluster mode.
    ctx_params.op_offload = n_gpu_layers != 0 && !has_cluster;

    // Create context (using new API)
    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (!g_ctx) {
        llama_model_free(g_model);
        g_model = nullptr;
        jclass exception = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(exception, "Failed to create context");
        return;
    }

    // Get vocab for tokenization
    g_vocab = llama_model_get_vocab(g_model);
    LOGI("Vocab initialized: %p", (void*)g_vocab);
    
    if (!g_vocab) {
        llama_free(g_ctx);
        llama_model_free(g_model);
        g_ctx = nullptr;
        g_model = nullptr;
        jclass exception = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(exception, "Failed to get vocab from model");
        return;
    }
    
    // Reset KV cache position counter for new model
    g_n_past = 0;
    g_cached_tokens.clear();

    // Report progress completion
    if (progress_callback) {
        jclass callbackClass = env->GetObjectClass(progress_callback);
        jmethodID invokeMethod = env->GetMethodID(callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");
        
        // Create Double object for 1.0
        jclass doubleClass = env->FindClass("java/lang/Double");
        jmethodID doubleConstructor = env->GetMethodID(doubleClass, "<init>", "(D)V");
        jobject doubleObj = env->NewObject(doubleClass, doubleConstructor, 1.0);
        
        env->CallObjectMethod(progress_callback, invokeMethod, doubleObj);
        env->DeleteLocalRef(doubleObj);
        env->DeleteLocalRef(callbackClass);
    }

    LOGI("Model loaded successfully");
}

static void freeMtmd() {
    if (g_mtmd) {
        mtmd_free(g_mtmd);
        g_mtmd = nullptr;
    }
}

/// Loads the vision projector for the current model. Returns null on
/// success, or an error message (the text model stays loaded either way).
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadMmproj(
        JNIEnv* env, jobject /* this */, jstring path, jlong n_threads) {
    freeMtmd();
    if (!g_model) return env->NewStringUTF("Load the text model first");
    if (!path) return env->NewStringUTF("Vision file path is missing");
    const char* mmproj_path = env->GetStringUTFChars(path, nullptr);
    if (!mmproj_path) return env->NewStringUTF("Could not read the vision file path");

    mtmd_context_params params = mtmd_context_params_default();
    // Image encoding stays on the CPU: mobile Vulkan drivers have been
    // unreliable, and the projector is small enough to run there.
    params.use_gpu = false;
    params.n_threads = (int)std::max<jlong>(1, n_threads);
    params.print_timings = false;
    params.warmup = false;  // skip a dummy encode at load time

    {
        std::lock_guard<std::mutex> lock(g_load_log_mutex);
        g_load_error.clear();
        g_capture_load_error = true;
    }
    mtmd_helper_log_set(androidLlamaLog, nullptr);
    g_mtmd = mtmd_init_from_file(mmproj_path, g_model, params);
    env->ReleaseStringUTFChars(path, mmproj_path);
    const std::string detail = consumeLoadError();

    if (!g_mtmd) {
        const std::string message = detail.empty()
            ? "The vision file doesn't match this model or couldn't be loaded"
            : "Vision file failed to load: " + detail;
        LOGE("%s", message.c_str());
        return env->NewStringUTF(message.c_str());
    }
    if (!mtmd_support_vision(g_mtmd)) {
        freeMtmd();
        return env->NewStringUTF("This projector file doesn't support images");
    }
    LOGI("Vision projector loaded");
    return nullptr;
}

static jobject g_token_callback = nullptr;

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGenerate(
    JNIEnv* env, jobject thiz,
    jstring prompt, jstring image_path, jlong max_tokens,
    jdouble temperature, jdouble top_p, jlong top_k, jdouble min_p, jdouble typical_p,
    jdouble repeat_penalty, jdouble frequency_penalty, jdouble presence_penalty, jlong repeat_last_n,
    jlong mirostat, jdouble mirostat_tau, jdouble mirostat_eta,
    jlong seed, jboolean penalize_newline,
    jobject token_callback) {
    
    if (g_token_callback != nullptr) {
        env->DeleteGlobalRef(g_token_callback);
        g_token_callback = nullptr;
    }
    g_token_callback = env->NewGlobalRef(token_callback);
    
    if (!g_model || !g_ctx || !g_vocab) {
        jclass exception = env->FindClass("java/lang/IllegalStateException");
        env->ThrowNew(exception, "Model not loaded");
        return;
    }

    const char* prompt_str = env->GetStringUTFChars(prompt, nullptr);
    g_stop_flag = false;

    std::string image_file;
    if (image_path) {
        const char* p = env->GetStringUTFChars(image_path, nullptr);
        if (p) {
            image_file = p;
            env->ReleaseStringUTFChars(image_path, p);
        }
    }
    const bool with_image = !image_file.empty();
    if (with_image && !g_mtmd) {
        env->ReleaseStringUTFChars(prompt, prompt_str);
        jclass exception = env->FindClass("java/lang/IllegalStateException");
        env->ThrowNew(exception, "This model has no vision file loaded, so it can't read images");
        return;
    }

    llama_batch batch = llama_batch_init(512, 0, 1);

    if (with_image) {
        // Image turn: tokenize text + image into chunks and evaluate them from
        // an empty cache (image embeddings can't be prefix-matched).
        std::string sanitized = sanitizeUTF8(prompt_str, strlen(prompt_str));
        env->ReleaseStringUTFChars(prompt, prompt_str);
        LOGI("Image prompt: %zu chars, marker %s", sanitized.size(),
             sanitized.find(mtmd_default_marker()) != std::string::npos ? "present" : "MISSING");

        mtmd_helper_bitmap_wrapper wrapped = mtmd_helper_bitmap_init_from_file(
            g_mtmd, image_file.c_str(), /*placeholder=*/false,
            mtmd_helper_init_opt_default());
        // Video is compiled out (MTMD_VIDEO=OFF), but free it if ever set.
        if (wrapped.video_ctx) mtmd_helper_video_free(wrapped.video_ctx);
        mtmd_bitmap* bitmap = wrapped.bitmap;
        if (!bitmap) {
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, "Couldn't read the image file");
            return;
        }
        // Zero-init: newer mtmd added fields (e.g. text_len) that must not
        // be left uninitialised.
        mtmd_input_text text{};
        text.text = sanitized.c_str();
        text.text_len = sanitized.size();
        text.add_special = true;
        text.parse_special = true;
        mtmd_input_chunks* chunks = mtmd_input_chunks_init();
        const mtmd_bitmap* bitmaps[] = {bitmap};
        const int32_t tok_res = mtmd_tokenize(g_mtmd, chunks, &text, bitmaps, 1);
        mtmd_bitmap_free(bitmap);
        if (tok_res != 0) {
            mtmd_input_chunks_free(chunks);
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, tok_res == 1
                ? "The prompt is missing the image marker"
                : "Couldn't process the image");
            return;
        }

        const int n_ctx_img = llama_n_ctx(g_ctx);
        const llama_pos n_pos = mtmd_helper_get_n_pos(chunks);
        if (n_pos + 64 > n_ctx_img) {
            mtmd_input_chunks_free(chunks);
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception,
                "The image and conversation are too long for the context size. "
                "Start a new chat or raise the context size.");
            return;
        }

        llama_memory_seq_rm(llama_get_memory(g_ctx), 0, 0, -1);
        g_cached_tokens.clear();
        llama_pos new_n_past = 0;
        LOGI("Evaluating image prompt: %d positions", (int)n_pos);
        const int32_t eval_res = mtmd_helper_eval_chunks(
            g_mtmd, g_ctx, chunks, 0, 0, 512, true, &new_n_past);
        mtmd_input_chunks_free(chunks);
        if (eval_res != 0) {
            llama_memory_seq_rm(llama_get_memory(g_ctx), 0, 0, -1);
            g_n_past = 0;
            g_cache_reusable = true;
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, "Failed to encode the image");
            return;
        }
        g_n_past = (int)new_n_past;
        g_cache_reusable = false;
    } else {

    // Never log prompt text: it is the user's conversation.
    const int prompt_len = strlen(prompt_str);

    // Sanitize the UTF-8 string before tokenizing
    std::string sanitized_prompt = sanitizeUTF8(prompt_str, prompt_len);
    const char* sanitized_cstr = sanitized_prompt.c_str();
    const int sanitized_len = sanitized_prompt.length();
    
    // Tokenize prompt - when tokens is NULL, llama_tokenize returns NEGATIVE count
    const int n_prompt_tokens = -llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, nullptr, 0, true, true);
    LOGI("Token count: %d", n_prompt_tokens);
    
    if (n_prompt_tokens <= 0) {
        env->ReleaseStringUTFChars(prompt, prompt_str);
        jclass exception = env->FindClass("java/lang/RuntimeException");
        char error_msg[256];
        snprintf(error_msg, sizeof(error_msg), "Failed to tokenize prompt (got %d tokens)", n_prompt_tokens);
        env->ThrowNew(exception, error_msg);
        llama_batch_free(batch);
        return;
    }
    std::vector<llama_token> tokens(n_prompt_tokens);
    const int actual_tokens = llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, tokens.data(), tokens.size(), true, true);
    if (actual_tokens < 0) {
        env->ReleaseStringUTFChars(prompt, prompt_str);
        jclass exception = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(exception, "Failed to tokenize prompt");
        llama_batch_free(batch);
        return;
    }
    tokens.resize(actual_tokens);
    env->ReleaseStringUTFChars(prompt, prompt_str);

    const int n_ctx = llama_n_ctx(g_ctx);

    // Leave room for the reply. If the conversation is longer than that, keep
    // its start (system prompt) and its most recent part, dropping the middle.
    const int reserve = (int)std::min<jlong>(std::max<jlong>(max_tokens, 64), n_ctx / 2);
    const int budget = n_ctx - reserve;
    if ((int)tokens.size() > budget) {
        const int head = std::min(256, budget / 4);
        std::vector<llama_token> trimmed(tokens.begin(), tokens.begin() + head);
        trimmed.insert(trimmed.end(), tokens.end() - (budget - head), tokens.end());
        LOGI("Prompt of %zu tokens trimmed to %d to fit context %d", tokens.size(), budget, n_ctx);
        tokens.swap(trimmed);
    }

    // Reuse the cached prefix shared with what's already in the KV cache;
    // drop everything after it. At least one token must be decoded so the
    // last position has logits to sample from.
    size_t n_keep = 0;
    if (!g_cache_reusable) {
        // Previous turn held an image: start this one from an empty cache.
        g_cached_tokens.clear();
        g_cache_reusable = true;
    }
    while (n_keep < g_cached_tokens.size() && n_keep < tokens.size() &&
           g_cached_tokens[n_keep] == tokens[n_keep]) {
        n_keep++;
    }
    if (n_keep >= tokens.size()) n_keep = tokens.size() - 1;
    llama_memory_seq_rm(llama_get_memory(g_ctx), 0, (llama_pos)n_keep, -1);
    g_cached_tokens.resize(n_keep);
    g_n_past = (int)n_keep;
    LOGI("Prompt: %zu tokens, %zu reused from cache, %zu to process",
         tokens.size(), n_keep, tokens.size() - n_keep);

    // Process prompt in batches to handle long inputs
    const int max_batch_size = 512;
    int tokens_processed = (int)n_keep;

    while (tokens_processed < (int)tokens.size()) {
        batch.n_tokens = 0;
        int batch_size = std::min((int)tokens.size() - tokens_processed, max_batch_size);

        for (int i = 0; i < batch_size; i++) {
            batch.token[batch.n_tokens] = tokens[tokens_processed + i];
            batch.pos[batch.n_tokens] = tokens_processed + i;
            batch.n_seq_id[batch.n_tokens] = 1;
            batch.seq_id[batch.n_tokens][0] = 0;
            batch.logits[batch.n_tokens] = (tokens_processed + i == (int)tokens.size() - 1);
            batch.n_tokens++;
        }

        int decode_result = llama_decode(g_ctx, batch);
        if (decode_result != 0) {
            LOGE("❌ DECODE FAILED! Result code: %d", decode_result);
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, "Failed to decode prompt");
            return;
        }
        tokens_processed += batch_size;
    }

    // The KV cache now holds exactly the prompt.
    g_n_past = (int)tokens.size();
    g_cached_tokens = tokens;
    }  // end text-only prompt path

    // Create sampler chain with all parameters
    if (g_sampler) {
        llama_sampler_free(g_sampler);
    }
    
    // Use seed or current time
    uint32_t sampler_seed = (seed >= 0) ? static_cast<uint32_t>(seed) : static_cast<uint32_t>(time(nullptr));
    
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    g_sampler = llama_sampler_chain_init(sparams);
    
    // Add penalties first (applied to logits before sampling)
    if (repeat_penalty != 1.0f || frequency_penalty != 0.0f || presence_penalty != 0.0f) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_penalties(
            llama_vocab_n_tokens(g_vocab),  // n_vocab
            repeat_last_n,              // penalty_last_n
            repeat_penalty,             // penalty_repeat
            frequency_penalty,          // penalty_freq
            presence_penalty            // penalty_present
        ));
    }
    
    // Temperature sampling
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(temperature));
    
    // Add advanced samplers if enabled
    if (mirostat == 1) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat(
            llama_vocab_n_tokens(g_vocab),  // Use the vocab to get n_vocab
            sampler_seed,
            mirostat_tau,
            mirostat_eta,
            100  // m parameter
        ));
    } else if (mirostat == 2) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat_v2(
            sampler_seed,
            mirostat_tau,
            mirostat_eta
        ));
    } else {
        // Standard sampling chain (only if mirostat is disabled)
        if (min_p > 0.0f && min_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p(min_p, 1));
        }
        
        if (typical_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_typical(typical_p, 1));
        }
        
        if (top_k > 0) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(top_k));
        }
        
        if (top_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(top_p, 1));
        }
    }
    
    // Final distribution sampler
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(sampler_seed));

    // Get callback method
    jclass callbackClass = env->GetObjectClass(token_callback);
    jmethodID invokeMethod = env->GetMethodID(callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");

    // Generation loop
    LOGI("Starting generation loop: max_tokens=%lld", max_tokens);
    for (int i = 0; i < max_tokens && !g_stop_flag; i++) {
        llama_token new_token_id = llama_sampler_sample(g_sampler, g_ctx, -1);

        // Check for end of generation (EOS/EOD tokens)
        if (llama_vocab_is_eog(g_vocab, new_token_id)) {
            LOGI("EOS token detected, ending generation.");
            break;
        }

        // Decode token to string
        char buffer[256];
        int32_t length = llama_token_to_piece(g_vocab, new_token_id, buffer, sizeof(buffer), 0, true);
        std::string piece;
        
        if (length > 0) {
            piece = sanitizeUTF8(buffer, length);
        } else {
            piece = "";
        }
        
        // Call Kotlin callback
        jstring token_str = env->NewStringUTF(piece.c_str());
        env->CallObjectMethod(g_token_callback, invokeMethod, token_str);
        env->DeleteLocalRef(token_str);

        // Prepare next batch
        batch.n_tokens = 0;
        batch.token[batch.n_tokens] = new_token_id;
        batch.pos[batch.n_tokens] = g_n_past;  // Use the tracked position
        batch.n_seq_id[batch.n_tokens] = 1;
        batch.seq_id[batch.n_tokens][0] = 0;
        batch.logits[batch.n_tokens] = true;
        batch.n_tokens++;

        if (llama_decode(g_ctx, batch) != 0) {
            LOGE("Failed to decode after sampling token %d", i + 1);
            break;
        }
        
        // Update position counter after each generated token
        g_n_past++;
        if (g_cache_reusable) g_cached_tokens.push_back(new_token_id);
    }
    LOGI("Generation loop finished.");

    if (g_token_callback != nullptr) {
        env->DeleteGlobalRef(g_token_callback);
        g_token_callback = nullptr;
    }

    // After generation completion, ensure the KV cache is properly managed
    // In some llama.cpp versions, KV cache management may be needed between generations
    // For chat applications, we want to maintain conversation context
    
    llama_batch_free(batch);
    env->DeleteLocalRef(callbackClass);
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeStop(
    JNIEnv* env, jobject thiz) {
    g_stop_flag = true;
    // When stopping generation, we just set the flag - KV cache management handled by llama.cpp
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeFreeModel(
    JNIEnv* env, jobject thiz) {
    
    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    freeMtmd();
    g_cache_reusable = true;
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
    }
    g_vocab = nullptr;
    g_n_past = 0;  // Reset position counter
    g_cached_tokens.clear();
    
    LOGI("Model freed");
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetTokensUsed(
    JNIEnv* env, jobject thiz) {
    return g_n_past;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetContextSize(
    JNIEnv* env, jobject thiz) {
    return g_ctx ? llama_n_ctx(g_ctx) : 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeClearContext(
    JNIEnv* env, jobject thiz) {
    if (!g_ctx) {
        LOGE("Cannot clear context: context is null");
        return;
    }
    
    llama_memory_t mem = llama_get_memory(g_ctx);
    if (mem) {
        llama_memory_seq_rm(mem, 0, 0, -1);
        g_n_past = 0;
        g_cached_tokens.clear();
        g_cache_reusable = true;
        LOGI("Context cleared, g_n_past reset to 0");
    } else {
        LOGE("Failed to get memory object from context");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeSetSystemPromptLength(
    JNIEnv* env, jobject thiz, jint length) {
    // Currently not used but available for future smart context management
    LOGI("System prompt length set to: %d tokens (currently unused)", length);
}
