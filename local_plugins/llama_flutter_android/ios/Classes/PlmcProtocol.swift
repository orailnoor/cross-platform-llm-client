import CryptoKit
import Foundation

/// PLMC v1: how a master and a worker prove they share the worker's pairing
/// secret (from its QR code), then encrypt everything between them. The
/// Android side (PlmcProtocol.kt) is the reference; test_vectors/plmc_v1.json
/// pins the bytes both must produce.
enum Plmc {
    static let magic = Data("PLMC".utf8)
    static let version: UInt8 = 1
    static let nonceLen = 32
    static let tagLen = 32
    static let gcmTagLen = 16
    static let maxPlaintext = 1 << 20
    static let handshakeTimeout: TimeInterval = 5

    static func serverTag(key: Data, nc: Data, ns: Data) -> Data {
        hmac(key, Data("PLMC1 server".utf8) + nc + ns)
    }

    static func clientTag(key: Data, nc: Data, ns: Data) -> Data {
        hmac(key, Data("PLMC1 client".utf8) + nc + ns)
    }

    static func deriveKeys(key: Data, nc: Data, ns: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: nc + ns,
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        return (derive("PLMC1 c2s"), derive("PLMC1 s2c"))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// 4 zero bytes, then the frame counter big-endian.
    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var be = counter.bigEndian
        return try AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
    }

    struct Exhausted: Error {}
}

/// Seals one direction's frames in order. Not thread-safe.
final class PlmcFrameSealer {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// Ciphertext followed by the 16-byte tag.
    func seal(_ plain: Data) throws -> Data {
        guard counter < UInt64(Int64.max) else { throw Plmc.Exhausted() }
        let box = try AES.GCM.seal(plain, using: key, nonce: Plmc.nonce(counter))
        counter += 1
        return box.ciphertext + box.tag
    }
}

/// Opens one direction's frames in order. Throws if a frame was changed or
/// is out of order. Not thread-safe.
final class PlmcFrameOpener {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    func open(_ sealed: Data) throws -> Data {
        guard counter < UInt64(Int64.max) else { throw Plmc.Exhausted() }
        let nonce = try Plmc.nonce(counter)
        counter += 1
        let split = sealed.count - Plmc.gcmTagLen
        guard split >= 0 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: nonce,
                                        ciphertext: sealed.prefix(split),
                                        tag: sealed.suffix(Plmc.gcmTagLen))
        return try AES.GCM.open(box, using: key)
    }
}
