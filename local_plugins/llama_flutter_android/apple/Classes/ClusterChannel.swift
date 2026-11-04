import Foundation
import Metal

#if os(macOS)
import AppKit
import FlutterMacOS
#else
import Flutter
import UIKit
#endif

/// Device cluster on Apple platforms: this device can be a worker (its GPU
/// serves a master's model layers). Same channel and methods as the Android
/// ClusterChannel; master-only calls answer as "not on this platform".
///
/// Shared by iOS and macOS. Desktop workers stop when the app closes, just
/// like iOS.
final class ClusterChannel: NSObject, NetServiceDelegate {
    private let channel: FlutterMethodChannel
    private var service: NetService?
    private var ramMb = 0
    private var bandwidth = 0.0
    private var error: String?

#if os(macOS)
    private var idleActivity: NSObjectProtocol?
#endif

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "llama_flutter_android/cluster", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        NSLog("[LlamaCluster] Memory for a worker: %ld MB (app limit %ld MB)",
              Self.usableMemoryMb(), LlamaClusterWorker.availableMemoryMb())
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "startWorker":
            let port = args["port"] as? Int ?? 50052
            startWorker(port: port)
            result(nil)
        case "stopWorker":
            // ggml's server can't be stopped inside a running app.
            result(FlutterError(code: "DESKTOP_STOP",
                                message: "Close PrivateLM to stop sharing this device.",
                                details: nil))
        case "workerStatus":
            let running = LlamaClusterWorker.isRunning()
            if !running, error == nil, let exitError = LlamaClusterWorker.lastError() {
                error = exitError
            }
            var status: [String: Any] = [
                "state": error != nil ? "error" : (running ? "running" : "stopped"),
                "heldMb": LlamaClusterWorker.footprintMb(),
                "ramMb": ramMb,
                "bandwidth": bandwidth,
                "id": Self.workerId,
            ]
            if let error = error { status["error"] = error }
            if running, let peer = LlamaClusterWorker.connectedPeer() { status["peer"] = peer }
            result(status)
        case "setKeepScreenOn":
            setKeepScreenOn(args["on"] as? Bool ?? false)
            result(nil)
        case "localFreeRamMb":
            result(LlamaClusterWorker.availableMemoryMb())
        case "benchmark":
            DispatchQueue.global(qos: .userInitiated).async {
                let gbps = LlamaClusterWorker.memoryBandwidth(withThreads: Int32(self.performanceCores()))
                DispatchQueue.main.async { result(gbps) }
            }
        case "lastLoadBuffers", "discover":
            // A desktop worker never runs a model, so there are no buffers.
            // Discovery is left to QR codes and manual IP entry for now.
            result([])
        case "probe":
            let endpoint = args["endpoint"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = Self.probe(endpoint)
                DispatchQueue.main.async { result(ok) }
            }
        case "setCluster":
            // Turning cluster mode off is fine; running a master isn't on
            // desktop yet (the Android app is the master).
            if (args["endpoints"] as? [String] ?? []).isEmpty {
                result(nil)
            } else {
                result(FlutterError(code: "DESKTOP_MASTER",
                                    message: "This device can be a worker, not a master.",
                                    details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startWorker(port: Int) {
        guard !LlamaClusterWorker.isRunning() else { return }
        error = nil
        // Keep the device awake while it serves a master: a sleeping Mac
        // (and especially an iOS app that leaves the screen) cuts the master
        // off mid-token.
        setKeepScreenOn(true)

        DispatchQueue.global(qos: .userInitiated).async {
            // Measure first, before the model takes memory.
            self.ramMb = Self.usableMemoryMb()
            self.bandwidth = LlamaClusterWorker.memoryBandwidth(withThreads: Int32(self.performanceCores()))
            let cache = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
                + "/cluster_cache"
            let failure = LlamaClusterWorker.start(onPort: Int32(port),
                                                   threads: Int32(self.performanceCores()),
                                                   cacheDir: cache)
            DispatchQueue.main.async {
                if let failure = failure {
                    self.error = failure
                    self.setKeepScreenOn(false)
                } else {
                    self.advertise(port: port)
                }
            }
        }
    }

    private func setKeepScreenOn(_ on: Bool) {
#if os(macOS)
        if on, idleActivity == nil {
            idleActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "PrivateLM is sharing this Mac with a cluster master")
        } else if !on, let activity = idleActivity {
            ProcessInfo.processInfo.endActivity(activity)
            idleActivity = nil
        }
#else
        UIApplication.shared.isIdleTimerDisabled = on
#endif
    }

    /// Bonjour, so masters can find this device with "Find nearby".
    private func advertise(port: Int) {
        let name: String
#if os(macOS)
        name = "PrivateLM \(Host.current().localizedName ?? "Mac")"
#else
        name = "PrivateLM \(UIDevice.current.name)"
#endif
        let service = NetService(domain: "local.", type: "_privatelm._tcp.",
                                 name: name, port: Int32(port))
        let txt: [String: Data] = [
            "ram": Data("\(ramMb)".utf8),
            "bw": Data(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bandwidth).utf8),
            "model": Data(Self.deviceModel.utf8),
            "v": Data("rpc7".utf8),
            "id": Data(Self.workerId.utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        self.service = service
    }

    /// What this device can hold as a worker. The increased-memory-limit
    /// entitlement lifts iOS's per-app limit to about all of RAM (8.2 GB on
    /// an 8 GB iPad), but the worker keeps its layers in GPU memory, so the
    /// GPU's recommended working set (5.7 GB on an M1) is the real ceiling.
    static func usableMemoryMb() -> Int {
        let appLimit = LlamaClusterWorker.availableMemoryMb()
        guard let gpu = MTLCreateSystemDefaultDevice() else { return appLimit }
        let gpuMb = Int(gpu.recommendedMaxWorkingSetSize / (1024 * 1024))
        return min(appLimit, gpuMb)
    }

    /// This device's lasting worker ID, so a master can find it again when
    /// its IP address changes (another Wi-Fi network, a hotspot, DHCP).
    static var workerId: String {
        let key = "privatelm.cluster.workerId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var deviceModel: String {
#if os(macOS)
        let info = ProcessInfo.processInfo
        return "\(Host.current().localizedName ?? "Mac") (\(info.operatingSystemVersionString))"
#else
        return UIDevice.current.model
#endif
    }

    /// Whether something answers on "host:port".
    static func probe(_ endpoint: String) -> Bool {
        guard let colon = endpoint.lastIndex(of: ":") else { return false }
        let host = String(endpoint[..<colon])
        let port = Int(endpoint[endpoint.index(after: colon)...]) ?? 0
        guard !host.isEmpty, port > 0, port <= 65535 else { return false }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return false
        }
        defer { freeaddrinfo(info) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            defer { candidate = address.pointee.ai_next }
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }

            // Non-blocking connect with a 2 s deadline; a blocking connect can
            // hang for over a minute when the worker is offline.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
            if rc == 0 { return true }
            if errno != EINPROGRESS { continue }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 2000) > 0, (pfd.revents & Int16(POLLOUT)) != 0 {
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0, soError == 0 {
                    return true
                }
            }
        }
        return false
    }

    private func performanceCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
