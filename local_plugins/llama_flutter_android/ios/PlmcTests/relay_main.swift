// Interop harness: the Swift worker relay on macOS, in front of an echo
// server standing in for llama.cpp's RPC server. The Kotlin master test
// (PlmcRelaysTest.interopWithSwiftWorker) connects to it.
//
//   mkdir -p "$TMPDIR/plmc_relay" && cp ios/PlmcTests/relay_main.swift "$TMPDIR/plmc_relay/main.swift"
//   swiftc -o "$TMPDIR/plmc_relay/run" ios/Classes/PlmcProtocol.swift ios/Classes/PlmcWorkerRelay.swift "$TMPDIR/plmc_relay/main.swift"
//   "$TMPDIR/plmc_relay/run" 50062 50063   # public port, echo port
import Foundation
import Network

let publicPort = UInt16(CommandLine.arguments[1])!
let echoPort = UInt16(CommandLine.arguments[2])!
let key = Data(0...31)

let echo = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: echoPort)!)
echo.newConnectionHandler = { conn in
    func loop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data = data, !data.isEmpty {
                conn.send(content: data, completion: .contentProcessed { _ in loop() })
            } else if done || error != nil {
                conn.cancel()
            } else {
                loop()
            }
        }
    }
    conn.start(queue: .global())
    loop()
}
echo.start(queue: .global())

let relay = PlmcWorkerRelay(publicPort: publicPort, upstreamPort: echoPort, keySupplier: { key },
                            onPeerChange: { print("peer: \($0 ?? "none")") })
try! relay.start()
print("relay on \(publicPort), echo on \(echoPort)")
dispatchMain()
