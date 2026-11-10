#include <windows.h>
#include <psapi.h>
#include <io.h>
#include "llama.h"
#include "ggml-rpc.h"
#include "gguf.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;
static std::mutex output_mutex, log_mutex;
static std::atomic<bool> stopping{false}, busy{false};
static json buffers = json::array();
static std::string peer;
static FILE * protocol_output = stdout;

static void emit(const json & value) {
    std::lock_guard<std::mutex> lock(output_mutex);
    const std::string line = value.dump(-1, ' ', false, json::error_handler_t::replace) + "\n";
    std::fwrite(line.data(), 1, line.size(), protocol_output);
    std::fflush(protocol_output);
}

static void native_log(ggml_log_level level, const char * text, void *) {
    if (level < GGML_LOG_LEVEL_INFO) return;
    std::cerr << text << std::flush;
    std::lock_guard<std::mutex> lock(log_mutex);
    std::string line(text);
    const std::string marker = " model buffer size = ";
    const auto at = line.find(marker);
    if (at != std::string::npos) {
        const auto colon = line.find(": ");
        const auto first = line.find_first_not_of(' ', colon == std::string::npos ? 0 : colon + 2);
        if (first < at) {
            std::string name = line.substr(first, at - first);
            name.erase(name.find_last_not_of(' ') + 1);
            buffers.push_back({{"name", name}, {"mb", std::strtod(line.c_str() + at + marker.size(), nullptr)}});
        }
    }
    const std::string connected = "RPC client connected: ";
    if (line.rfind(connected, 0) == 0) {
        peer = line.substr(connected.size());
        peer.erase(peer.find_last_not_of("\r\n ") + 1);
    } else if (line.rfind("RPC client disconnected", 0) == 0) {
        peer.clear();
    }
}

static uint64_t free_ram() {
    MEMORYSTATUSEX info{};
    info.dwLength = sizeof(info);
    if (!GlobalMemoryStatusEx(&info)) throw std::runtime_error("Cannot query available Windows memory");
    return info.ullAvailPhys;
}

static double benchmark(int threads) {
    const size_t count = (64u << 20) / sizeof(uint64_t);
    std::vector<uint64_t> data(count, 1), sums(threads);
    auto run = [&](int t) {
        uint64_t sum = 0;
        const size_t from = count * t / threads, to = count * (t + 1) / threads;
        for (int pass = 0; pass < 4; ++pass) {
            for (size_t i = from; i < to; ++i) sum += data[i];
        }
        sums[t] = sum;
    };
    const auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (int t = 0; t < threads; ++t) pool.emplace_back(run, t);
    for (auto & thread : pool) thread.join();
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (!std::accumulate(sums.begin(), sums.end(), uint64_t{0})) throw std::runtime_error("Memory benchmark failed");
    return (double(count) * sizeof(uint64_t) * 4) / seconds / 1e9;
}

static ggml_backend_dev_t gpu_device() {
    auto gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    return gpu ? gpu : ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU);
}

static json device_info(bool measure) {
    auto gpu = gpu_device();
    size_t available = 0, total = 0;
    if (gpu) ggml_backend_dev_memory(gpu, &available, &total);
    json result = {{"freeRamBytes", free_ram()}, {"gpuName", gpu ? ggml_backend_dev_description(gpu) : "CPU"},
                   {"gpuSupported", gpu != nullptr}, {"gpuFreeBytes", available}, {"gpuTotalBytes", total}};
    if (measure) result["bandwidth"] = benchmark(std::max(1u, std::min(8u, std::thread::hardware_concurrency() / 2)));
    return result;
}

struct Metadata {
    int layers = 0;
    uint64_t kv_bytes = 0;
};

static Metadata metadata(const std::string & path, int context) {
    gguf_init_params params{true, nullptr};
    std::unique_ptr<gguf_context, decltype(&gguf_free)> file(gguf_init_from_file(path.c_str(), params), gguf_free);
    if (!file) throw std::runtime_error("Invalid GGUF model");
    auto get_int = [&](const std::string & key, uint64_t fallback) -> uint64_t {
        const auto id = gguf_find_key(file.get(), key.c_str());
        if (id < 0) return fallback;
        if (gguf_get_kv_type(file.get(), id) == GGUF_TYPE_UINT32) return gguf_get_val_u32(file.get(), id);
        if (gguf_get_kv_type(file.get(), id) == GGUF_TYPE_INT32) return std::max(0, gguf_get_val_i32(file.get(), id));
        return fallback;
    };
    const auto arch_id = gguf_find_key(file.get(), "general.architecture");
    if (arch_id < 0) throw std::runtime_error("GGUF has no model architecture");
    const std::string arch = gguf_get_val_str(file.get(), arch_id);
    const auto layers = get_int(arch + ".block_count", 0);
    const auto heads = get_int(arch + ".attention.head_count", 1);
    const auto kv_heads = get_int(arch + ".attention.head_count_kv", heads);
    const auto dimension = get_int(arch + ".embedding_length", 0) / std::max(uint64_t{1}, heads);
    const auto key = get_int(arch + ".attention.key_length", dimension);
    const auto value = get_int(arch + ".attention.value_length", dimension);
    return {int(layers), (key + value) * kv_heads * 2 * layers * uint64_t(context)};
}

class Engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    int used = 0;
    int loaded_gpu_layers = 0;

    void clear() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
        context = nullptr;
        model = nullptr;
        used = 0;
    }

    std::vector<llama_token> tokenize(const std::string & prompt) {
        const auto vocab = llama_model_get_vocab(model);
        int size = llama_tokenize(vocab, prompt.c_str(), int(prompt.size()), nullptr, 0, true, true);
        if (size >= 0) throw std::runtime_error("Unable to tokenize prompt");
        std::vector<llama_token> tokens(-size);
        size = llama_tokenize(vocab, prompt.c_str(), int(prompt.size()), tokens.data(), int(tokens.size()), true, true);
        if (size < 0) throw std::runtime_error("Unable to tokenize prompt");
        tokens.resize(size);
        return tokens;
    }

    std::string chat_prompt(const json & messages, const std::string & requested) {
        std::vector<std::string> roles, texts;
        for (const auto & message : messages) {
            roles.push_back(message.at("role").get<std::string>());
            texts.push_back(message.at("content").get<std::string>());
        }
        std::vector<llama_chat_message> chat;
        for (size_t i = 0; i < roles.size(); ++i) chat.push_back({roles[i].c_str(), texts[i].c_str()});
        const char * templ = requested.empty() ? llama_model_chat_template(model, nullptr) : requested.c_str();
        if (!templ) templ = "chatml";
        int size = llama_chat_apply_template(templ, chat.data(), chat.size(), true, nullptr, 0);
        if (size < 0) throw std::runtime_error("Unsupported model chat template. Select a supported text GGUF model.");
        std::string prompt(size, '\0');
        llama_chat_apply_template(templ, chat.data(), chat.size(), true, prompt.data(), int(prompt.size()));
        return prompt;
    }

public:
    ~Engine() { clear(); }

    json command(const json & request) {
        const std::string op = request.at("op");
        const int id = request.at("id");
        if (op == "info") return device_info(request.value("benchmark", false));
        if (op == "buffers") {
            std::lock_guard<std::mutex> lock(log_mutex);
            return buffers;
        }
        if (op == "context") return {{"tokensUsed", used}, {"contextSize", context ? llama_n_ctx(context) : 0}};
        if (op == "reset") {
            if (context) llama_memory_clear(llama_get_memory(context), true);
            used = 0;
            return nullptr;
        }
        if (op == "unload") { clear(); return nullptr; }
        if (op == "load") {
            clear();
            const std::string path = request.at("path");
            const int n_ctx = request.value("contextSize", 2048);
            const int threads = request.value("threads", 4);
            if (n_ctx < 128 || n_ctx > 131072 || threads < 1 || threads > 256) throw std::runtime_error("Invalid model configuration");
            const auto meta = metadata(path, n_ctx);
            if (meta.layers <= 0) throw std::runtime_error("GGUF has no transformer layers");
            {
                std::lock_guard<std::mutex> lock(log_mutex);
                buffers = json::array();
            }
            auto params = llama_model_default_params();
            auto gpu = gpu_device();
            int gpu_layers = 0;
            if (gpu && request.value("gpuLayers", 0) > 0) {
                size_t available, total;
                ggml_backend_dev_memory(gpu, &available, &total);
                const double room = double(available) * 0.85 - double(meta.kv_bytes) - (512u << 20);
                const double per_layer = double(std::filesystem::file_size(std::filesystem::u8path(path))) / meta.layers;
                gpu_layers = std::clamp(int(std::max(0.0, room) / per_layer), 0, meta.layers + 1);
                gpu_layers = std::min(gpu_layers, request.value("gpuLayers", 0));
            }
            loaded_gpu_layers = gpu_layers;
            params.n_gpu_layers = gpu_layers;
            std::vector<ggml_backend_dev_t> devices;
            std::vector<float> split(llama_max_devices(), 0.0f);
            llama_model_tensor_buft_override overrides[2]{};
            const auto endpoints = request.value("endpoints", std::vector<std::string>{});
            const auto weights = request.value("weights", std::vector<float>{});
            if (!endpoints.empty()) {
                if (weights.size() != endpoints.size()) throw std::runtime_error("Invalid cluster weights");
                const float remote_weight = std::accumulate(weights.begin(), weights.end(), 0.0f);
                const float local_weight = std::max(0.0f, request.value("localWeight", 1.0f));
                if (remote_weight <= 0) throw std::runtime_error("Cluster needs positive worker weights");
                const int local_layers = std::clamp(int(std::lround(meta.layers * local_weight / (local_weight + remote_weight))), 0, meta.layers - 1);
                loaded_gpu_layers = std::min(gpu_layers, local_layers);
                if (loaded_gpu_layers > 0) {
                    devices.push_back(gpu);
                    split[0] = float(loaded_gpu_layers);
                }
                for (size_t i = 0; i < endpoints.size(); ++i) {
                    auto reg = ggml_backend_rpc_add_server(endpoints[i].c_str());
                    if (!reg) throw std::runtime_error("Worker has no RPC devices: " + endpoints[i]);
                    ggml_backend_register(reg);
                    const auto count = ggml_backend_reg_dev_count(reg);
                    for (size_t d = 0; d < count; ++d) {
                        if (devices.size() >= split.size()) throw std::runtime_error("Too many cluster devices");
                        split[devices.size()] = (meta.layers - local_layers) * std::max(weights[i], 0.01f) / remote_weight / count;
                        devices.push_back(ggml_backend_reg_dev_get(reg, d));
                    }
                }
                params.n_gpu_layers = meta.layers + 1 - (local_layers - loaded_gpu_layers);
                params.split_mode = LLAMA_SPLIT_MODE_LAYER;
                params.tensor_split = split.data();
                auto cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
                if (cpu) overrides[0] = {"^(output|token_embd)\\.weight$", ggml_backend_dev_buffer_type(cpu)};
                params.tensor_buft_overrides = overrides;
            } else if (gpu_layers > 0) {
                devices.push_back(gpu);
            }
            devices.push_back(nullptr);
            params.devices = devices.data();
            struct Progress { int id; float last = -1; } progress{id};
            params.progress_callback_user_data = &progress;
            params.progress_callback = [](float value, void * data) {
                auto & p = *static_cast<Progress *>(data);
                if (value >= p.last + 0.01f || value >= 1.0f) {
                    p.last = value;
                    emit({{"id", p.id}, {"event", "progress"}, {"value", value}});
                }
                return !stopping;
            };
            model = llama_model_load_from_file(path.c_str(), params);
            if (!model) throw std::runtime_error("Model loading failed. Check the GGUF file and available RAM/VRAM; try CPU Safe mode.");
            auto cp = llama_context_default_params();
            cp.n_ctx = n_ctx;
            cp.n_batch = std::min(n_ctx, 512);
            cp.n_threads = cp.n_threads_batch = threads;
            cp.op_offload = endpoints.empty() && gpu_layers > 0;
            cp.abort_callback = [](void *) { return stopping.load(); };
            context = llama_init_from_model(model, cp);
            if (!context) { clear(); throw std::runtime_error("Cannot allocate model context. Reduce context size or use CPU Safe mode."); }
            return {{"gpuLayers", loaded_gpu_layers}, {"gpuName", loaded_gpu_layers > 0 ? ggml_backend_dev_description(gpu) : "CPU"}};
        }
        if (op != "generate") throw std::runtime_error("Unknown native operation: " + op);
        if (!model || !context) throw std::runtime_error("No model loaded");
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
        struct AwakeGuard { ~AwakeGuard() { SetThreadExecutionState(ES_CONTINUOUS); } } awake;
        const int limit = request.value("maxTokens", 512);
        if (limit < 1 || limit > 131072) throw std::runtime_error("Invalid generation token limit");
        const int capacity = llama_n_ctx(context);
        const int reserved = std::min(limit, capacity / 4);
        std::vector<llama_token> tokens;
        if (request.contains("messages")) {
            json messages = request.at("messages");
            if (messages.empty()) throw std::runtime_error("Conversation is empty");
            while (true) {
                tokens = tokenize(chat_prompt(messages, request.value("template", std::string{})));
                if (int(tokens.size()) + reserved <= capacity) break;
                const size_t first = messages[0].value("role", "") == "system" ? 1 : 0;
                if (messages.size() <= first + 1) throw std::runtime_error("Message exceeds the model context. Shorten it or increase context size.");
                messages.erase(messages.begin() + first);
                if (messages.size() > first + 1 && messages[first].value("role", "") == "assistant") messages.erase(messages.begin() + first);
            }
        } else {
            tokens = tokenize(request.at("prompt"));
            if (int(tokens.size()) >= capacity) throw std::runtime_error("Prompt exceeds model context");
        }
        llama_memory_clear(llama_get_memory(context), true);
        used = 0;
        auto params = llama_sampler_chain_default_params();
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(params), llama_sampler_free);
        auto add = [&](llama_sampler * item) { llama_sampler_chain_add(sampler.get(), item); };
        add(llama_sampler_init_penalties(llama_vocab_n_tokens(llama_model_get_vocab(model)),
                                        request.value("repeatLastN", 64), request.value("repeatPenalty", 1.1f),
                                        request.value("frequencyPenalty", 0.0f), request.value("presencePenalty", 0.0f)));
        const float temperature = request.value("temperature", 0.7f);
        const auto seed = request.value("seed", uint32_t(LLAMA_DEFAULT_SEED));
        const int mirostat = request.value("mirostat", 0);
        const auto vocab = llama_model_get_vocab(model);
        if (temperature <= 0) {
            add(llama_sampler_init_greedy());
        } else if (mirostat == 1) {
            add(llama_sampler_init_temp(temperature));
            add(llama_sampler_init_mirostat(llama_vocab_n_tokens(vocab), seed, request.value("mirostatTau", 5.0f), request.value("mirostatEta", 0.1f), 100));
        } else if (mirostat == 2) {
            add(llama_sampler_init_temp(temperature));
            add(llama_sampler_init_mirostat_v2(seed, request.value("mirostatTau", 5.0f), request.value("mirostatEta", 0.1f)));
        } else {
            add(llama_sampler_init_top_k(request.value("topK", 40)));
            add(llama_sampler_init_top_p(request.value("topP", 0.9f), 1));
            add(llama_sampler_init_min_p(request.value("minP", 0.05f), 1));
            add(llama_sampler_init_typical(request.value("typicalP", 1.0f), 1));
            add(llama_sampler_init_temp(temperature));
            add(llama_sampler_init_dist(seed));
        }
        for (auto token : tokens) llama_sampler_accept(sampler.get(), token);
        for (int at = 0; at < int(tokens.size()) && !stopping;) {
            const int count = std::min(512, int(tokens.size()) - at);
            auto batch = llama_batch_get_one(tokens.data() + at, count);
            if (llama_decode(context, batch) != 0 && !stopping) throw std::runtime_error("Prompt evaluation failed");
            at += count;
            used = at;
        }
        std::string pending;
        for (int i = 0; i < limit && used < capacity && !stopping; ++i) {
            auto token = llama_sampler_sample(sampler.get(), context, -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            char small[256];
            int size = llama_token_to_piece(vocab, token, small, sizeof(small), 0, false);
            std::string piece;
            if (size < 0) {
                piece.resize(-size);
                size = llama_token_to_piece(vocab, token, piece.data(), int(piece.size()), 0, false);
                if (size < 0) throw std::runtime_error("Token decoding failed");
                piece.resize(size);
            } else {
                piece.assign(small, size);
            }
            pending += piece;
            // A UTF-8 character may span several tokens. Emit only complete characters.
            size_t end = 0;
            while (end < pending.size()) {
                const auto c = static_cast<unsigned char>(pending[end]);
                const size_t width = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
                if (end + width > pending.size()) break;
                end += width;
            }
            if (end) {
                emit({{"id", id}, {"event", "token"}, {"value", pending.substr(0, end)}});
                pending.erase(0, end);
            }
            auto batch = llama_batch_get_one(&token, 1);
            if (llama_decode(context, batch) != 0 && !stopping) throw std::runtime_error("Generation failed");
            ++used;
        }
        if (!pending.empty() && !stopping) emit({{"id", id}, {"event", "token"}, {"value", pending}});
        return {{"tokensUsed", used}, {"contextSize", capacity}};
    }
};

static json worker_status(double bandwidth, ggml_backend_dev_t dev) {
    PROCESS_MEMORY_COUNTERS memory{};
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory))) throw std::runtime_error("Cannot query worker memory");
    std::lock_guard<std::mutex> lock(log_mutex);
    const bool gpu = ggml_backend_dev_type(dev) != GGML_BACKEND_DEVICE_TYPE_CPU;
    uint64_t capacity = free_ram();
    if (gpu) {
        size_t available, total;
        ggml_backend_dev_memory(dev, &available, &total);
        capacity = uint64_t(std::max(0.0, double(available) * 0.85 - (512u << 20)));
    }
    return {{"state", "running"}, {"peer", peer.empty() ? json(nullptr) : json(peer)},
            {"heldMb", double(memory.WorkingSetSize) / (1024 * 1024)},
            {"ramMb", capacity / (1024 * 1024)}, {"memoryBackend", gpu ? "gpu" : "ram"},
            {"bandwidth", bandwidth}, {"batteryUnrestricted", true}};
}

int main(int argc, char ** argv) {
    SetErrorMode(SEM_NOGPFAULTERRORBOX | SEM_FAILCRITICALERRORS);
    try {
        // RPC and third-party backends print to stdout. Keep IPC on its own pipe.
        const int protocol_fd = _dup(_fileno(stdout));
        if (protocol_fd < 0) throw std::runtime_error("Cannot create native protocol stream");
        protocol_output = _fdopen(protocol_fd, "w");
        if (!protocol_output || _dup2(_fileno(stderr), _fileno(stdout)) != 0) {
            throw std::runtime_error("Cannot isolate native protocol stream");
        }
        int parent = 0, port = 0, threads = 4;
        bool worker_gpu = true;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (i + 1 >= argc) throw std::runtime_error("Missing native argument");
            if (arg == "--parent") parent = std::stoi(argv[++i]);
            else if (arg == "--worker") port = std::stoi(argv[++i]);
            else if (arg == "--threads") threads = std::stoi(argv[++i]);
            else if (arg == "--worker-memory") {
                const std::string mode = argv[++i];
                if (mode != "gpu" && mode != "ram") throw std::runtime_error("Worker memory must be gpu or ram");
                worker_gpu = mode == "gpu";
            }
            else throw std::runtime_error("Unknown native argument");
        }
        if (parent) {
            HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, parent);
            if (!process) throw std::runtime_error("Cannot monitor the PrivateLM parent process");
            std::thread([process] {
                WaitForSingleObject(process, INFINITE);
                CloseHandle(process);
                ExitProcess(0);
            }).detach();
        }
        llama_log_set(native_log, nullptr);
        ggml_log_set(native_log, nullptr);
        llama_backend_init();
        if (port) {
            if (port < 1 || port > 65535 || threads < 1 || threads > 256) throw std::runtime_error("Invalid worker configuration");
            const double speed = benchmark(threads);
            auto dev = worker_gpu ? gpu_device() : nullptr;
            if (!dev) dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
            if (!dev) throw std::runtime_error("No worker compute backend");
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
            std::thread([speed, dev] {
                std::string line;
                while (std::getline(std::cin, line)) {
                    int id = -1;
                    try {
                        const auto request = json::parse(line);
                        id = request.at("id");
                        const std::string op = request.at("op");
                        if (op == "quit") ExitProcess(0);
                        if (op != "status") throw std::runtime_error("Unknown worker operation");
                        emit({{"id", id}, {"event", "result"}, {"value", worker_status(speed, dev)}});
                    } catch (const std::exception & e) {
                        emit({{"id", id}, {"event", "error"}, {"message", e.what()}});
                    }
                }
                ExitProcess(0);
            }).detach();
            const std::string endpoint = "0.0.0.0:" + std::to_string(port);
            ggml_backend_rpc_start_server(endpoint.c_str(), nullptr, threads, 1, &dev);
            throw std::runtime_error("Worker stopped: could not listen on " + endpoint + ". Check whether the port is already in use.");
        }
        Engine engine;
        std::thread task;
        std::string line;
        while (std::getline(std::cin, line)) {
            int id = -1;
            try {
                auto request = json::parse(line);
                id = request.at("id");
                const std::string op = request.at("op");
                if (op == "quit") break;
                if (op == "stop") {
                    stopping = true;
                    emit({{"id", id}, {"event", "result"}, {"value", nullptr}});
                    continue;
                }
                if (busy) throw std::runtime_error("Native engine is busy");
                if (task.joinable()) task.join();
                stopping = false;
                busy = true;
                task = std::thread([&engine, request, id] {
                    try {
                        auto value = engine.command(request);
                        busy = false;
                        emit({{"id", id}, {"event", "result"}, {"value", value}});
                    } catch (const std::exception & e) {
                        busy = false;
                        emit({{"id", id}, {"event", "error"}, {"message", e.what()}});
                    }
                });
            } catch (const std::exception & e) {
                emit({{"id", id}, {"event", "error"}, {"message", e.what()}});
            }
        }
        stopping = true;
        if (task.joinable()) task.join();
        return 0;
    } catch (const std::exception & e) {
        std::cerr << e.what() << std::endl;
        emit({{"id", -1}, {"event", "error"}, {"message", e.what()}});
        return 1;
    }
}
