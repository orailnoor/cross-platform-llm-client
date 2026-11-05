// Checks ios/Classes/PlmcProtocol.swift against test_vectors/plmc_v1.json,
// the same known answers the Kotlin tests use. Runs on macOS:
//
//   swiftc -o "$TMPDIR/plmc_test" ios/Classes/PlmcProtocol.swift ios/PlmcTests/main.swift
//   "$TMPDIR/plmc_test" test_vectors/plmc_v1.json
import CryptoKit
import Foundation

let json = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]

func v(_ name: String) -> Data {
    let hex = json[name]!
    var data = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let next = hex.index(i, offsetBy: 2)
        data.append(UInt8(hex[i..<next], radix: 16)!)
        i = next
    }
    return data
}

func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

func check(_ name: String, _ ok: () throws -> Bool) {
    let passed = (try? ok()) ?? false
    print("\(passed ? "PASS" : "FAIL") \(name)")
    if !passed { exit(1) }
}

check("serverAndClientTagsMatchVectors") {
    Plmc.serverTag(key: v("key"), nc: v("nc"), ns: v("ns")) == v("server_tag")
        && Plmc.clientTag(key: v("key"), nc: v("nc"), ns: v("ns")) == v("client_tag")
}

check("sessionKeysMatchVectors") {
    let keys = Plmc.deriveKeys(key: v("key"), nc: v("nc"), ns: v("ns"))
    return raw(keys.c2s) == v("c2s") && raw(keys.s2c) == v("s2c")
}

check("framesMatchVectorsInOrder") {
    let key = SymmetricKey(data: v("c2s"))
    let sealer = PlmcFrameSealer(key: key)
    guard try sealer.seal(v("frame0_plaintext")) == v("frame0_sealed"),
          try sealer.seal(v("frame1_plaintext")) == v("frame1_sealed") else { return false }
    let opener = PlmcFrameOpener(key: key)
    return try opener.open(v("frame0_sealed")) == v("frame0_plaintext")
        && opener.open(v("frame1_sealed")) == v("frame1_plaintext")
}

check("tamperedFrameFailsToOpen") {
    var sealed = v("frame0_sealed")
    sealed[0] ^= 1
    return (try? PlmcFrameOpener(key: SymmetricKey(data: v("c2s"))).open(sealed)) == nil
}

check("openerRejectsOutOfOrderFrames") {
    (try? PlmcFrameOpener(key: SymmetricKey(data: v("c2s"))).open(v("frame1_sealed"))) == nil
}

check("constantTimeEquals") {
    Plmc.constantTimeEquals(v("key"), v("key")) && !Plmc.constantTimeEquals(v("key"), v("nc"))
        && !Plmc.constantTimeEquals(v("key"), v("key").prefix(31))
}

check("constantsMatchSpec") {
    Plmc.magic == Data("PLMC".utf8) && Plmc.version == 1 && Plmc.maxPlaintext == 1 << 20
        && Plmc.handshakeTimeout == 5
}
