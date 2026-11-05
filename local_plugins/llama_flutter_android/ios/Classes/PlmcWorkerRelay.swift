import CryptoKit
import Foundation
import Network
import Security

/// Worker side of PLMC v1 on iOS: the only door to this device's llama.cpp
/// RPC server, which listens on loopback (`upstreamPort`). Lets in masters
/// that hold the key `keySupplier` returns (read per connection, so a reset
/// applies at once) and encrypts everything. Same wire format as the Android
/// PlmcHandshake.server / PlmcSession.
///
/// Other apps can't reach another app's loopback port on iOS, but the design
/// doesn't rely on that (see docs/superpowers/specs/2026-11-06-cluster-secure-pairing-design.md).
final class PlmcWorkerRelay {
    private let publicPort: UInt16
    private let upstreamPort: UInt16
    private let keySupplier: () -> Data
    private let onPeerChange: (String?) -> Void
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "plmc.worker.relay")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RelayConnection] = [:]

    init(publicPort: UInt16, upstreamPort: UInt16, keySupplier: @escaping () -> Data,
         onPeerChange: @escaping (String?) -> Void = { _ in },
         log: @escaping (String) -> Void = { NSLog("[LlamaCluster] %@", $0) }) {
        self.publicPort = publicPort
        self.upstreamPort = upstreamPort
        self.keySupplier = keySupplier
        self.onPeerChange = onPeerChange
        self.log = log
    }

    /// IP of a master connected right now, or nil.
    var peer: String? { queue.sync { currentPeer() } }

    private func currentPeer() -> String? {
        connections.values.first(where: { $0.authenticated })?.remoteHost
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: publicPort)!)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.log("Worker relay stopped: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Closes every connection (after a pairing reset). Keeps listening.
    func dropAll() {
        queue.async {
            let all = Array(self.connections.values)
            self.connections.removeAll()
            all.forEach { $0.close() }
            self.onPeerChange(nil)
        }
    }

    private func accept(_ client: NWConnection) {
        let conn = RelayConnection(client: client, upstreamPort: upstreamPort, key: keySupplier(),
                                   queue: queue, log: log)
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.onAuthenticated = { [weak self] in
            guard let self = self else { return }
            self.log("Master \(conn.remoteHost) connected")
            self.onPeerChange(self.currentPeer())
        }
        conn.onClosed = { [weak self] in
            guard let self = self, self.connections.removeValue(forKey: id) != nil else { return }
            if conn.authenticated { self.onPeerChange(self.currentPeer()) }
        }
        conn.start()
    }
}

/// One master connection: handshake, then frames both ways. Runs on the
/// relay's serial queue.
private final class RelayConnection {
    private let client: NWConnection
    private let upstreamPort: UInt16
    private let key: Data
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var upstream: NWConnection?
    private var sealer: PlmcFrameSealer?
    private var opener: PlmcFrameOpener?
    private var closed = false
    private(set) var authenticated = false
    var onAuthenticated: () -> Void = {}
    var onClosed: () -> Void = {}

    let remoteHost: String

    init(client: NWConnection, upstreamPort: UInt16, key: Data, queue: DispatchQueue,
         log: @escaping (String) -> Void) {
        self.client = client
        self.upstreamPort = upstreamPort
        self.key = key
        self.queue = queue
        self.log = log
        if case .hostPort(let host, _) = client.endpoint {
            // "192.168.1.5%en0" → "192.168.1.5"
            remoteHost = "\(host)".components(separatedBy: "%")[0]
        } else {
            remoteHost = "?"
        }
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        // A client that doesn't finish the handshake in time is dropped, so
        // silent connections can't pile up.
        queue.asyncAfter(deadline: .now() + Plmc.handshakeTimeout) { [weak self] in
            guard let self = self, !self.authenticated else { return }
            self.refuse("handshake timed out")
        }
        receive(Plmc.magic.count + 1 + Plmc.nonceLen) { [weak self] hello in
            self?.handleHello(hello)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        onClosed()
    }

    private func refuse(_ reason: String) {
        log("Refused connection from \(remoteHost) (\(reason))")
        close()
    }

    /// Exactly `count` bytes, or close.
    private func receive(_ count: Int, from conn: NWConnection? = nil, _ done: @escaping (Data) -> Void) {
        (conn ?? client).receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self = self, !self.closed else { return }
            guard error == nil, let data = data, data.count == count else {
                self.close()
                return
            }
            done(data)
        }
    }

    private func send(_ data: Data, to conn: NWConnection? = nil, _ done: @escaping () -> Void = {}) {
        (conn ?? client).send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            if error != nil { self.close() } else { done() }
        })
    }

    private func handleHello(_ hello: Data) {
        let magic = hello.prefix(Plmc.magic.count)
        let version = hello[hello.startIndex + Plmc.magic.count]
        guard magic == Plmc.magic, version == Plmc.version, key.count == 32 else {
            refuse("not a PLMC v1 client")
            return
        }
        let nc = hello.suffix(Plmc.nonceLen)
        var ns = Data(count: Plmc.nonceLen)
        let ok = ns.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Plmc.nonceLen, $0.baseAddress!) }
        guard ok == errSecSuccess else {
            close()
            return
        }
        send(ns + Plmc.serverTag(key: key, nc: nc, ns: ns))
        receive(Plmc.tagLen) { [weak self] tag in
            guard let self = self else { return }
            guard Plmc.constantTimeEquals(tag, Plmc.clientTag(key: self.key, nc: nc, ns: ns)) else {
                self.refuse("wrong pairing key")
                return
            }
            let keys = Plmc.deriveKeys(key: self.key, nc: nc, ns: ns)
            self.sealer = PlmcFrameSealer(key: keys.s2c)
            self.opener = PlmcFrameOpener(key: keys.c2s)
            self.authenticated = true
            self.onAuthenticated()
            self.connectUpstream()
        }
    }

    private func connectUpstream() {
        let up = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        upstream = up
        up.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.pumpFromMaster()
                self.pumpFromUpstream()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    /// Master → RPC server: frame length, frame, decrypt, forward.
    private func pumpFromMaster() {
        receive(4) { [weak self] header in
            guard let self = self, let up = self.upstream, let opener = self.opener else { return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            // Checked before allocating: a hostile length can't make us reserve memory.
            guard length > Plmc.gcmTagLen, length <= Plmc.maxPlaintext + Plmc.gcmTagLen else {
                self.refuse("bad frame length")
                return
            }
            self.receive(length) { sealed in
                guard let plain = try? opener.open(sealed) else {
                    self.refuse("frame failed to open")
                    return
                }
                self.send(plain, to: up) { self.pumpFromMaster() }
            }
        }
    }

    /// RPC server → master: read, encrypt, frame, send.
    private func pumpFromUpstream() {
        guard let up = upstream else { return }
        up.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self = self, !self.closed, let sealer = self.sealer else { return }
            if let data = data, !data.isEmpty {
                guard let sealed = try? sealer.seal(data) else {
                    self.close()
                    return
                }
                var length = UInt32(sealed.count).bigEndian
                self.send(Data(bytes: &length, count: 4) + sealed) { self.pumpFromUpstream() }
            } else if done || error != nil {
                self.close()
            } else {
                self.pumpFromUpstream()
            }
        }
    }
}
