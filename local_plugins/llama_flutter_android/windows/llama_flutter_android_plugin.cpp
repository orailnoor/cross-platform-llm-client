#include "llama_flutter_android_plugin.h"

// winsock2.h must come before windows.h.
#include <winsock2.h>
#include <ws2tcpip.h>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#include <psapi.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <ggml-backend.h>
#include <ggml-rpc.h>
#include <ggml.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace llama_flutter_android {
namespace {

std::atomic<bool> g_running{false};
std::mutex g_state_mutex;
std::string g_error;
std::string g_peer;
int g_ram_mb = 0;
double g_bandwidth = 0.0;

// The RPC server reports connections through ggml's logger (a PrivateLM
// patch), the same way the Android and iOS workers do.
void ClusterLog(ggml_log_level, const char* text, void*) {
  if (text == nullptr) return;
  static const char kConnected[] = "RPC client connected: ";
  if (std::strncmp(text, kConnected, sizeof(kConnected) - 1) == 0) {
    std::string peer(text + sizeof(kConnected) - 1);
    while (!peer.empty() &&
           std::isspace(static_cast<unsigned char>(peer.back()))) {
      peer.pop_back();
    }
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_peer = std::move(peer);
  } else if (std::strncmp(text, "RPC client disconnected", 23) == 0) {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_peer.clear();
  }
}

void SetError(const std::string& error) {
  std::lock_guard<std::mutex> lock(g_state_mutex);
  g_error = error;
}

std::string GetError() {
  std::lock_guard<std::mutex> lock(g_state_mutex);
  return g_error;
}

std::string GetPeer() {
  std::lock_guard<std::mutex> lock(g_state_mutex);
  return g_peer;
}

int64_t GetInt(const flutter::EncodableValue& value, int64_t fallback) {
  if (const auto* v = std::get_if<int32_t>(&value)) return *v;
  if (const auto* v = std::get_if<int64_t>(&value)) return *v;
  if (const auto* v = std::get_if<double>(&value)) return (int64_t)*v;
  return fallback;
}

std::string LocalAppDataDir() {
  const char* local_app_data = std::getenv("LOCALAPPDATA");
  if (local_app_data != nullptr && local_app_data[0] != '\0') {
    return std::string(local_app_data) + "\\PrivateLM";
  }
  char temp[MAX_PATH] = {};
  if (GetTempPathA(MAX_PATH, temp) > 0) {
    return std::string(temp) + "PrivateLM";
  }
  return ".";
}

std::string WorkerId() {
  const std::filesystem::path path =
      std::filesystem::path(LocalAppDataDir()) / "cluster_id.txt";
  std::error_code ec;
  std::ifstream in(path);
  std::string id;
  if (in && std::getline(in, id) && !id.empty()) return id;

  GUID guid = {};
  if (CoCreateGuid(&guid) != S_OK) return "windows-worker";
  char buffer[40] = {};
  std::snprintf(buffer, sizeof(buffer),
                "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                static_cast<unsigned long>(guid.Data1), guid.Data2, guid.Data3,
                guid.Data4[0], guid.Data4[1], guid.Data4[2], guid.Data4[3],
                guid.Data4[4], guid.Data4[5], guid.Data4[6], guid.Data4[7]);
  id = buffer;

  std::filesystem::create_directories(path.parent_path(), ec);
  std::ofstream out(path);
  if (out) out << id;
  return id;
}

int64_t FreeRamMb() {
  MEMORYSTATUSEX status = {};
  status.dwLength = sizeof(status);
  if (!GlobalMemoryStatusEx(&status)) return 0;
  return static_cast<int64_t>(status.ullAvailPhys / (1024 * 1024));
}

int64_t WorkingSetMb() {
  PROCESS_MEMORY_COUNTERS_EX counters = {};
  if (!GetProcessMemoryInfo(GetCurrentProcess(),
                            reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters),
                            sizeof(counters))) {
    return 0;
  }
  return static_cast<int64_t>(counters.WorkingSetSize / (1024 * 1024));
}

// Memory read speed in GB/s: a rough proxy for how fast this PC will
// generate tokens as a worker. Mirrors the Android/iOS benchmark.
double MemoryBandwidthGb() {
  const int threads = std::max(1u, std::thread::hardware_concurrency());
  const size_t per_thread = (64u << 20) / sizeof(uint64_t) / threads;
  if (per_thread < 4) return 0.0;
  std::vector<uint64_t> data(per_thread * threads, 1);
  std::vector<uint64_t> sums(threads, 0);
  const int passes = 4;
  auto run = [&](int t) {
    const uint64_t* p = data.data() + per_thread * t;
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (int pass = 0; pass < passes; ++pass) {
      for (size_t i = 0; i + 4 <= per_thread; i += 4) {
        a += p[i];
        b += p[i + 1];
        c += p[i + 2];
        d += p[i + 3];
      }
    }
    sums[t] = a + b + c + d;
  };
  run(0);  // warm up: page in the buffer
  const auto start = std::chrono::steady_clock::now();
  std::vector<std::thread> pool;
  pool.reserve(threads);
  for (int t = 0; t < threads; ++t) pool.emplace_back(run, t);
  for (auto& thread : pool) thread.join();
  const double seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
          .count();
  const double gbps =
      seconds > 0
          ? static_cast<double>(data.size() * sizeof(uint64_t) * passes) /
                seconds / 1e9
          : 0.0;
  volatile uint64_t sink = sums[0];
  (void)sink;
  return gbps;
}

bool Probe(const std::string& endpoint) {
  const size_t colon = endpoint.rfind(':');
  if (colon == std::string::npos) return false;
  const std::string host = endpoint.substr(0, colon);
  const int port = std::atoi(endpoint.c_str() + colon + 1);
  if (host.empty() || port <= 0 || port > 65535) return false;

  WSADATA winsock = {};
  if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return false;

  addrinfo hints = {};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* info = nullptr;
  if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &info) !=
      0) {
    WSACleanup();
    return false;
  }

  bool reachable = false;
  for (addrinfo* address = info; address != nullptr && !reachable;
       address = address->ai_next) {
    SOCKET socket_handle =
        socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (socket_handle == INVALID_SOCKET) continue;

    u_long nonblocking = 1;
    ioctlsocket(socket_handle, FIONBIO, &nonblocking);

    const int result =
        connect(socket_handle, address->ai_addr,
                static_cast<int>(address->ai_addrlen));
    if (result == 0) {
      reachable = true;
    } else if (WSAGetLastError() == WSAEWOULDBLOCK) {
      fd_set write_set;
      FD_ZERO(&write_set);
      FD_SET(socket_handle, &write_set);
      timeval timeout = {};
      timeout.tv_sec = 2;
      if (select(0, nullptr, &write_set, nullptr, &timeout) > 0) {
        int so_error = 0;
        int length = sizeof(so_error);
        if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR,
                       reinterpret_cast<char*>(&so_error), &length) == 0 &&
            so_error == 0) {
          reachable = true;
        }
      }
    }
    closesocket(socket_handle);
  }

  freeaddrinfo(info);
  WSACleanup();
  return reachable;
}

void StartWorkerThread(int port, int threads) {
  // Capture the measurements now: the model layers will use this memory.
  g_ram_mb = static_cast<int>(FreeRamMb());
  g_bandwidth = MemoryBandwidthGb();

  ggml_log_set(ClusterLog, nullptr);

  ggml_backend_dev_t device =
      ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
  if (device == nullptr) {
    device = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU);
  }
  if (device == nullptr) {
    device = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
  }
  if (device == nullptr) {
    SetError("No compute device found");
    g_running = false;
    return;
  }

  const std::string cache_dir =
      (std::filesystem::path(LocalAppDataDir()) / "cluster_cache").string();
  std::error_code ec;
  std::filesystem::create_directories(cache_dir, ec);
  const std::string endpoint = "0.0.0.0:" + std::to_string(port);

  ggml_backend_dev_t devices[] = {device};
  ggml_backend_rpc_start_server(endpoint.c_str(), cache_dir.c_str(),
                                static_cast<size_t>(std::max(1, threads)), 1,
                                devices);

  // Only returns if the server couldn't start or stopped unexpectedly.
  SetError("Worker stopped: couldn't listen on " + endpoint +
           " (port in use, or blocked by the firewall)");
  g_running = false;
}

}  // namespace

void LlamaFlutterAndroidPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "llama_flutter_android/cluster",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<LlamaFlutterAndroidPlugin>();
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

LlamaFlutterAndroidPlugin::LlamaFlutterAndroidPlugin() = default;
LlamaFlutterAndroidPlugin::~LlamaFlutterAndroidPlugin() = default;

void LlamaFlutterAndroidPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "startWorker") {
    int port = 50052;
    int threads = static_cast<int>(
        std::max(1u, std::thread::hardware_concurrency()));
    if (arguments != nullptr) {
      const auto port_it = arguments->find(flutter::EncodableValue("port"));
      if (port_it != arguments->end()) {
        port = static_cast<int>(GetInt(port_it->second, port));
      }
      const auto threads_it =
          arguments->find(flutter::EncodableValue("threads"));
      if (threads_it != arguments->end()) {
        threads = static_cast<int>(GetInt(threads_it->second, threads));
      }
    }
    if (!g_running.exchange(true)) {
      {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        g_error.clear();
        g_peer.clear();
      }
      std::thread(StartWorkerThread, port, threads).detach();
    }
    result->Success();
    return;
  }

  if (method == "stopWorker") {
    // ggml's RPC server has no stop API; matching iOS, the worker lives until
    // the app closes.
    result->Error("DESKTOP_STOP",
                  "Close PrivateLM to stop sharing this device.");
    return;
  }

  if (method == "workerStatus") {
    const bool running = g_running.load();
    const std::string error = GetError();
    const std::string peer = running ? GetPeer() : std::string();
    flutter::EncodableMap status;
    status[flutter::EncodableValue("state")] = flutter::EncodableValue(
        !error.empty() ? "error" : (running ? "running" : "stopped"));
    status[flutter::EncodableValue("error")] =
        error.empty() ? flutter::EncodableValue()
                      : flutter::EncodableValue(error);
    status[flutter::EncodableValue("peer")] =
        peer.empty() ? flutter::EncodableValue() : flutter::EncodableValue(peer);
    status[flutter::EncodableValue("heldMb")] =
        flutter::EncodableValue(WorkingSetMb());
    status[flutter::EncodableValue("ramMb")] =
        flutter::EncodableValue(static_cast<int64_t>(g_ram_mb));
    status[flutter::EncodableValue("bandwidth")] =
        flutter::EncodableValue(g_bandwidth);
    status[flutter::EncodableValue("throttled")] =
        flutter::EncodableValue(false);
    status[flutter::EncodableValue("batteryUnrestricted")] =
        flutter::EncodableValue(true);
    status[flutter::EncodableValue("id")] =
        flutter::EncodableValue(WorkerId());
    result->Success(flutter::EncodableValue(status));
    return;
  }

  if (method == "setKeepScreenOn" || method == "requestBatteryUnrestricted") {
    result->Success();
    return;
  }

  if (method == "localFreeRamMb") {
    result->Success(flutter::EncodableValue(FreeRamMb()));
    return;
  }

  if (method == "benchmark") {
    result->Success(flutter::EncodableValue(MemoryBandwidthGb()));
    return;
  }

  if (method == "lastLoadBuffers" || method == "discover") {
    result->Success(flutter::EncodableValue(flutter::EncodableList()));
    return;
  }

  if (method == "probe") {
    std::string endpoint;
    if (arguments != nullptr) {
      const auto it = arguments->find(flutter::EncodableValue("endpoint"));
      if (it != arguments->end()) {
        if (const auto* value = std::get_if<std::string>(&it->second)) {
          endpoint = *value;
        }
      }
    }
    result->Success(flutter::EncodableValue(Probe(endpoint)));
    return;
  }

  if (method == "setCluster") {
    bool has_endpoints = false;
    if (arguments != nullptr) {
      const auto it = arguments->find(flutter::EncodableValue("endpoints"));
      if (it != arguments->end()) {
        if (const auto* list =
                std::get_if<flutter::EncodableList>(&it->second)) {
          has_endpoints = !list->empty();
        }
      }
    }
    if (has_endpoints) {
      result->Error("DESKTOP_MASTER",
                    "This device can be a worker, not a master.");
    } else {
      result->Success();
    }
    return;
  }

  result->NotImplemented();
}

}  // namespace llama_flutter_android
