import Flutter
import Foundation
import Metal
import UIKit

/// Phone cluster on iOS: this device can be a worker (its GPU serves a
/// master's model layers). Same channel and methods as the Android
/// ClusterChannel; master-only calls answer as "not on iOS".
final class ClusterChannel: NSObject, NetServiceDelegate {
    private let channel: FlutterMethodChannel
    private var service: NetService?
    private var ramMb = 0
    private var bandwidth = 0.0
    private var error: String?

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
            result(FlutterError(code: "IOS_STOP",
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
            UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
            result(nil)
        case "localFreeRamMb":
            result(LlamaClusterWorker.availableMemoryMb())
        case "benchmark":
            DispatchQueue.global(qos: .userInitiated).async {
                let gbps = LlamaClusterWorker.memoryBandwidth(withThreads: Int32(self.performanceCores()))
                DispatchQueue.main.async { result(gbps) }
            }
        case "lastLoadBuffers", "discover":
            result([])
        case "probe":
            result(false)
        case "setCluster":
            // Turning cluster mode off is fine; running a master isn't on iOS yet.
            if (args["endpoints"] as? [String] ?? []).isEmpty {
                result(nil)
            } else {
                result(FlutterError(code: "IOS_MASTER",
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
        // iOS suspends apps that leave the screen, which would cut the master
        // off mid-token: keep the screen on while this device is a worker.
        UIApplication.shared.isIdleTimerDisabled = true

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
                    UIApplication.shared.isIdleTimerDisabled = false
                } else {
                    self.advertise(port: port)
                }
            }
        }
    }

    /// Bonjour, so masters can find this device with "Find nearby".
    private func advertise(port: Int) {
        let service = NetService(domain: "local.", type: "_privatelm._tcp.",
                                 name: "PrivateLM \(UIDevice.current.name)", port: Int32(port))
        let txt: [String: Data] = [
            "ram": Data("\(ramMb)".utf8),
            "bw": Data(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bandwidth).utf8),
            "model": Data(UIDevice.current.model.utf8),
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

    private func performanceCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
