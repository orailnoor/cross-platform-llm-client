#import "LlamaClusterWorker.h"
#include "ggml-backend.h"
#include "ggml-rpc.h"
#include <os/proc.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <mach/mach.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define LOGI(...) NSLog(@"[LlamaCluster] " __VA_ARGS__)

static std::atomic<bool> g_running{false};
static std::mutex g_error_mutex;
static std::string g_error;  // why the server stopped, if it did
static std::mutex g_peer_mutex;
static std::string g_peer;

// The RPC server reports connections through ggml's logger ("RPC client
// connected: <ip>" / "RPC client disconnected", a PrivateLM patch).
static void clusterLog(ggml_log_level level, const char* text, void*) {
    if (!text) return;
    static const char kConnected[] = "RPC client connected: ";
    if (std::strncmp(text, kConnected, sizeof(kConnected) - 1) == 0) {
        std::string peer(text + sizeof(kConnected) - 1);
        while (!peer.empty() && isspace((unsigned char)peer.back())) peer.pop_back();
        std::lock_guard<std::mutex> lock(g_peer_mutex);
        g_peer = peer;
    } else if (std::strncmp(text, "RPC client disconnected", 23) == 0) {
        std::lock_guard<std::mutex> lock(g_peer_mutex);
        g_peer.clear();
    }
    if (level >= GGML_LOG_LEVEL_INFO && level != GGML_LOG_LEVEL_CONT) {
        NSLog(@"[ggml] %s", text);
    }
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
    // Interactive-voice class: iOS's Wi-Fi driver keeps voice traffic out of
    // its deep power save (plain packets didn't: the iPad still dozed).
    int service = NET_SERVICE_TYPE_VO;
    setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, sizeof(service));
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

static std::string currentPeer() {
    std::lock_guard<std::mutex> lock(g_peer_mutex);
    return g_peer;
}

@implementation LlamaClusterWorker

+ (nullable NSString*)startOnPort:(int)port threads:(int)threads cacheDir:(NSString*)cacheDir {
    if (g_running) return nil;
    ggml_log_set(clusterLog, nullptr);

    // The GPU (Metal) does the work: on Apple silicon it reads memory far
    // faster than the CPU cores do. CPU only if there's no Metal device.
    ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    if (!dev) dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU);
    if (!dev) dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (!dev) return @"No compute device found";

    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    std::string endpoint = "0.0.0.0:" + std::to_string(port);
    std::string cache = cacheDir.UTF8String;
    const size_t n_threads = (size_t)std::max(1, threads);
    LOGI(@"Worker on %s using %s, cache %s", endpoint.c_str(), ggml_backend_dev_name(dev), cache.c_str());

    g_running = true;
    std::thread([] { runRadioKeepAwake(g_running, currentPeer); }).detach();
    std::thread([endpoint, cache, n_threads, dev]() mutable {
        ggml_backend_dev_t devices[] = {dev};
        ggml_backend_rpc_start_server(endpoint.c_str(), cache.c_str(), n_threads, 1, devices);
        // Only returns if the server couldn't start (e.g. port in use).
        LOGI(@"Worker server exited");
        {
            std::lock_guard<std::mutex> lock(g_error_mutex);
            g_error = "Worker stopped: couldn't listen on " + endpoint + " (port in use?)";
        }
        g_running = false;
    }).detach();
    return nil;
}

+ (BOOL)isRunning {
    return g_running;
}

+ (nullable NSString*)lastError {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    return g_error.empty() ? nil : [NSString stringWithUTF8String:g_error.c_str()];
}

+ (nullable NSString*)connectedPeer {
    std::lock_guard<std::mutex> lock(g_peer_mutex);
    return g_peer.empty() ? nil : [NSString stringWithUTF8String:g_peer.c_str()];
}

+ (long)availableMemoryMb {
    return (long)(os_proc_available_memory() / (1024 * 1024));
}

+ (long)footprintMb {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (long)(info.phys_footprint / (1024 * 1024));
}

+ (double)memoryBandwidthWithThreads:(int)threads {
    const int n = std::max(1, threads);
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
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double gbps = secs > 0 ? (double)data.size() * sizeof(uint64_t) * passes / secs / 1e9 : 0;
    LOGI(@"Memory bandwidth: %.1f GB/s (%d threads, check %llu)", gbps, n, (unsigned long long)sums[0]);
    return gbps;
}

@end
