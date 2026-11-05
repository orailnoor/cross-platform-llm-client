// Generates test_vectors/plmc_v1.json: known answers for the phone-cluster
// pairing protocol (PLMC v1), shared by the Kotlin and Swift tests.
//
// Uses CryptoKit primitives directly, never the app's own protocol code,
// so the vectors are an independent check on both implementations.
//
//   swift scripts/gen_plmc_vectors.swift > test_vectors/plmc_v1.json
import CryptoKit
import Foundation

func bytes(_ range: ClosedRange<UInt8>) -> Data { Data(range) }
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { hex(Data($0)) } }

func tag(_ label: String, key: SymmetricKey, nc: Data, ns: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + nc + ns, using: key))
}

func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
    var be = counter.bigEndian
    return try! AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
}

func sealFrame(_ plain: Data, key: SymmetricKey, counter: UInt64) -> Data {
    let box = try! AES.GCM.seal(plain, using: key, nonce: nonce(counter))
    return box.ciphertext + box.tag
}

let key = bytes(0x00...0x1f)
let nc = bytes(0x20...0x3f)
let ns = bytes(0x40...0x5f)
let k = SymmetricKey(data: key)

func derive(_ info: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: nc + ns,
                           info: Data(info.utf8), outputByteCount: 32)
}
let c2s = derive("PLMC1 c2s")
let s2c = derive("PLMC1 s2c")

let frame0 = Data("hello worker".utf8)
let frame1 = Data(repeating: 0xab, count: 300)

let vectors: [(String, String)] = [
    ("key", hex(key)),
    ("nc", hex(nc)),
    ("ns", hex(ns)),
    ("server_tag", hex(tag("PLMC1 server", key: k, nc: nc, ns: ns))),
    ("client_tag", hex(tag("PLMC1 client", key: k, nc: nc, ns: ns))),
    ("c2s", hex(c2s)),
    ("s2c", hex(s2c)),
    ("frame0_plaintext", hex(frame0)),
    ("frame0_sealed", hex(sealFrame(frame0, key: c2s, counter: 0))),
    ("frame1_plaintext", hex(frame1)),
    ("frame1_sealed", hex(sealFrame(frame1, key: c2s, counter: 1))),
]
print("{")
for (i, (name, value)) in vectors.enumerated() {
    print("  \"\(name)\": \"\(value)\"\(i < vectors.count - 1 ? "," : "")")
}
print("}")
