# Cluster Secure Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cluster workers accept only masters holding the secret from their QR code, and all master↔worker traffic is encrypted and tamper-proof, so workers are safe on public Wi-Fi.

**Architecture:** llama.cpp's RPC server moves to `127.0.0.1:50053` on the worker. A worker relay (Kotlin on Android, Swift on iOS) on `0.0.0.0:50052` runs a mutual HMAC handshake (protocol "PLMC v1"), then pipes AES-256-GCM frames to the loopback RPC port. On the Android master, a per-worker relay on `127.0.0.1:<ephemeral>` does the client side, and llama.cpp is pointed at those local endpoints. Secrets are kept on the native side in Keystore-wrapped files (Android) or the Keychain (iOS). Dart only sees them briefly, to draw the QR code and to pass a scanned key on to the native side.

**Tech Stack:** Kotlin (`javax.crypto`, `java.net`, AndroidKeyStore), Swift (CryptoKit, Network.framework, Security/Keychain), Dart/Flutter (GetX), JUnit 5 via `kotlin-test`.

**Spec:** `docs/superpowers/specs/2026-11-06-cluster-secure-pairing-design.md`

## Global Constraints

- Do not modify llama.cpp or ggml sources (`android/src/main/cpp/llama.cpp/`, `ios/llama_cpp_src/`). Only `jni_wrapper.cpp` and `LlamaClusterWorker.mm` (our own files) may change.
- No new pub, Gradle or CocoaPods dependencies. Use platform crypto only.
- Public worker port stays `50052`. Internal RPC port is `50053`, bound to `127.0.0.1` only.
- Secret: 32 bytes from `SecureRandom` / `SecRandomCopyBytes`. QR encoding is base64url with no padding.
- QR URI: existing `privatelm://worker?...` plus `key=<base64url>` and `v=1`. `id` is required.
- The secret never goes to logs, Crashlytics, Bonjour/NSD TXT records, Hive, or the worker status JSON file.
- Handshake timeout 5 s. Max plaintext per frame 1 MiB (1,048,576 bytes).
- No unauthenticated fallback of any kind. Legacy pairings are shown as unpaired.
- Android minSdk 28. iOS is worker-only, unchanged.
- User-facing copy (exact):
  - QR warning: `Anyone who scans this code can use this phone as a worker. Don't share it.`
  - Unpaired worker: `Scan again to reconnect`
  - Rejected: `This worker was reset. Scan its code again.`
  - Old worker QR: `This worker needs a newer PrivateLM. Update it, then scan again.`
  - Newer worker QR: `Update PrivateLM on this phone to add this worker.`
  - Reset dialog: title `Reset pairing?`, body `Masters paired with this phone will need to scan its new code.`, action `Reset`
- Work on branch `feat/cluster-secure-pairing`, never on `main`.

## Review Focus

1. **A client that connects and sends nothing (slowloris):** it must be dropped after 5 s, and a real master connecting at the same time must still get through. Pinned in Task 3 (`idleConnectionTimesOutAndDoesNotBlockOthers`).
2. **Reset pairing while a master is mid-generation:** live sessions close immediately, and the master's next probe reports `rejected`, not `unreachable`. Pinned in Task 3 (`dropAllClosesLiveSessions`) and Task 2 (`wrongServerKeyIsRejectedNotUnreachable`).
3. **A frame length header of `0x7FFFFFFF` or a negative value:** rejected before any allocation. Pinned in Task 2 (`oversizedFrameLengthRejected`).
4. **A worker that moves IP, where another device on the new network announces the same worker ID:** the stored address must not change. Pinned in Task 8 (`relocateIgnoresIdMatchThatFailsAuth`).
5. **A partial read or write at frame boundaries:** RPC messages split across TCP segments, or bigger than 1 MiB (model tensors), must arrive byte-exact. Pinned in Task 3 (`largeTransferIsByteExact`, 64 MiB of random data through both relays).

---

### Task 1: Protocol vectors and Kotlin protocol core

**Files:**
- Create: `local_plugins/llama_flutter_android/scripts/gen_plmc_vectors.swift`
- Create: `local_plugins/llama_flutter_android/test_vectors/plmc_v1.json`
- Create: `local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcProtocol.kt`
- Test: `local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcProtocolTest.kt`

**Interfaces:**
- Produces (Kotlin, `object PlmcProtocol`):
  - `val MAGIC: ByteArray` (`"PLMC"` ASCII)
  - `const val VERSION: Byte = 1`
  - `const val NONCE_LEN = 32`
  - `const val TAG_LEN = 32`
  - `const val MAX_PLAINTEXT = 1 shl 20`
  - `const val HANDSHAKE_TIMEOUT_MS = 5000`
  - `fun serverTag(key: ByteArray, nc: ByteArray, ns: ByteArray): ByteArray`: HMAC-SHA256 over `"PLMC1 server"‖nc‖ns`
  - `fun clientTag(key: ByteArray, nc: ByteArray, ns: ByteArray): ByteArray`: same, over `"PLMC1 client"`
  - `fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray` (RFC 5869)
  - `fun deriveKeys(key: ByteArray, nc: ByteArray, ns: ByteArray): SessionKeys`, where `data class SessionKeys(val c2s: ByteArray, val s2c: ByteArray)`. Uses salt `nc‖ns` and infos `"PLMC1 c2s"` / `"PLMC1 s2c"`, 32 bytes each.
  - `fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean` (`MessageDigest.isEqual`)
  - `class FrameSealer(key: ByteArray)` with `fun seal(plain: ByteArray, off: Int, len: Int): ByteArray`, returning ciphertext‖16-byte tag
  - `class FrameOpener(key: ByteArray)` with `fun open(sealed: ByteArray): ByteArray`, which throws `javax.crypto.AEADBadTagException` on tamper
  - Nonce: 12 bytes. The first 4 are zero, then the frame counter as a big-endian `Long`, starting at 0 and +1 per frame. No AAD. When the counter reaches `Long.MAX_VALUE`, throw `IllegalStateException`.
- Vector JSON keys (all values lowercase hex): `key`, `nc`, `ns`, `server_tag`, `client_tag`, `c2s`, `s2c`, `frame0_plaintext`, `frame0_sealed`, `frame1_plaintext`, `frame1_sealed`. Both frames are sealed with `c2s`, at counters 0 and 1.

- [ ] **Step 1: Write the vector generator** in `scripts/gen_plmc_vectors.swift`. Use CryptoKit primitives directly (`HMAC<SHA256>`, `HKDF<SHA256>.deriveKey`, `AES.GCM.seal` with an explicit nonce). It must not depend on any file in `Classes/`, so it stays an independent oracle. Fixed inputs:
  - `key` = bytes `0x00…0x1f`
  - `nc` = `0x20…0x3f`
  - `ns` = `0x40…0x5f`
  - `frame0_plaintext` = UTF-8 `"hello worker"`
  - `frame1_plaintext` = 300 bytes of `0xab`

  Print the JSON to stdout.

- [ ] **Step 2: Generate the vectors.**
  Run: `cd local_plugins/llama_flutter_android && swift scripts/gen_plmc_vectors.swift > test_vectors/plmc_v1.json && cat test_vectors/plmc_v1.json`
  Expected: valid JSON with all 11 keys. `server_tag`, `client_tag`, `c2s` and `s2c` are each 64 hex characters. `frame0_sealed` is (12 + 16) × 2 = 56 hex characters.

- [ ] **Step 3: Write the failing tests** in `PlmcProtocolTest.kt`. Load the JSON from `../test_vectors/plmc_v1.json`, relative to the plugin's `android/` directory, using `File(System.getProperty("user.dir"))`. Parse it with `org.json` or a tiny regex; no new dependency.
  - `serverAndClientTagsMatchVectors`: `serverTag(key,nc,ns)` == `server_tag`, and `clientTag(key,nc,ns)` == `client_tag`
  - `sessionKeysMatchVectors`: `deriveKeys(...)` gives `c2s` and `s2c`
  - `hkdfMatchesRfc5869Case1`: RFC 5869 test case 1. IKM is 22 × `0x0b`, salt is `000102…0c`, info is `f0…f9`, L is 42, and OKM is `3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865`.
  - `framesMatchVectorsInOrder`: a fresh `FrameSealer(c2s)` seals frame0, then frame1, matching `frame0_sealed` and `frame1_sealed`. `FrameOpener(c2s)` opens both back to their plaintexts.
  - `tamperedFrameFailsToOpen`: flipping 1 bit of `frame0_sealed` makes `open` throw `AEADBadTagException`.
  - `openerRejectsOutOfOrderFrames`: opening `frame1_sealed` first throws `AEADBadTagException`.

- [ ] **Step 4: Run the tests and confirm they fail.**
  Run: `cd android && ./gradlew :llama_flutter_android:testDebugUnitTest --tests 'com.write4me.llama_flutter_android.PlmcProtocolTest'`
  Expected: compilation failure, `Unresolved reference: PlmcProtocol`.

- [ ] **Step 5: Implement `PlmcProtocol.kt`** with the interfaces above. Use `Mac.getInstance("HmacSHA256")` and `Cipher.getInstance("AES/GCM/NoPadding")` with `GCMParameterSpec(128, nonce)`. Write `hkdf` by hand, with extract then expand, on top of the same Mac.

- [ ] **Step 6: Run the tests and confirm they pass.** Same command. Expected: 6 tests PASS.

- [ ] **Step 7: Commit**
```bash
git add local_plugins/llama_flutter_android/scripts/gen_plmc_vectors.swift local_plugins/llama_flutter_android/test_vectors local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcProtocol.kt local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcProtocolTest.kt
git commit -m "feat(cluster): PLMC v1 protocol core with shared test vectors"
```

---

### Task 2: Kotlin handshake and encrypted session

**Files:**
- Create: `local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcSession.kt`
- Test: `local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcSessionTest.kt`

**Interfaces:**
- Consumes: everything in `PlmcProtocol` (Task 1).
- Produces:
  - `class PlmcAuthException(message: String) : java.io.IOException(message)`. Thrown on the client when the server's tag is wrong, which means the worker was reset.
  - `class PlmcSession` with:
    - `fun write(buf: ByteArray, off: Int, len: Int)`: splits into frames of at most `MAX_PLAINTEXT` and writes `[4-byte BE length of sealed][sealed]`
    - `fun read(): ByteArray?`: one frame's plaintext, or `null` on clean EOF. Throws `IOException` when the length is ≤ 16 or > `MAX_PLAINTEXT + 16`; this check comes before allocating.
    - `fun close()` and `val remoteAddress: String`
  - `object PlmcHandshake` with:
    - `fun client(socket: Socket, key: ByteArray): PlmcSession`
    - `fun server(socket: Socket, keySupplier: () -> ByteArray?): PlmcSession`. A `null` key means "not ready": close the socket.
  - Both handshake functions set `socket.soTimeout = HANDSHAKE_TIMEOUT_MS` during the handshake and reset it to 0 afterwards. The server closes silently on bad magic, bad version or a bad client tag, by throwing `IOException` to its caller without writing anything.

- [ ] **Step 1: Write the failing tests** in `PlmcSessionTest.kt`. Use a real `ServerSocket(0, 50, InetAddress.getLoopbackAddress())`, with the server handshake on a background thread.
  - `roundTripBothDirections`: same key on both sides. The client writes `"ping"` and the server's `read()` returns `"ping"`. The server writes `"pong"` and the client reads `"pong"`.
  - `wrongClientKeyIsClosedByServer`: the server throws `IOException`, and the client's handshake fails with `PlmcAuthException` or an EOF `IOException`.
  - `wrongServerKeyIsRejectedNotUnreachable`: the client's key differs from the server's. `PlmcHandshake.client` throws exactly `PlmcAuthException`.
  - `badMagicClosedWithoutReply`: a raw socket sends `"GET / HTTP/1.1\r\n\r\n"`. The server throws, and the raw client reads `-1` (EOF) with zero bytes received.
  - `oversizedFrameLengthRejected`: after a valid handshake, a raw write of header `0x7FFFFFFF` makes the server's `read()` throw `IOException`. Repeat with `0xFFFFFFFF` (negative as `Int`) and with `0x00000010` (16 bytes, smaller than a tag).
  - `tamperedFrameClosesSession`: intercept with a byte-flipping proxy socket pair, or seal a frame manually and flip 1 byte. `read()` throws.
  - `replayedHandshakeFails`: record the client's bytes from one successful session and replay them on a new connection. The server's handshake throws, because `Ns` is fresh.
  - `writeSplitsIntoMaxSizeFrames`: writing 2.5 MiB produces exactly 3 frames when read back. Concatenated, they equal the input.

- [ ] **Step 2: Run the tests and confirm they fail.**
  Run: `cd android && ./gradlew :llama_flutter_android:testDebugUnitTest --tests 'com.write4me.llama_flutter_android.PlmcSessionTest'`
  Expected: compilation failure, `Unresolved reference: PlmcHandshake`.

- [ ] **Step 3: Implement `PlmcSession.kt`.** Use buffered `DataInputStream`/`DataOutputStream` over the socket streams, and `readFully` for the handshake fields and frame bodies. The client seals with `c2s` and opens with `s2c`; the server does the reverse. `write` must be thread-safe against itself (`@Synchronized`), because the relay writes from one pump thread per direction.

- [ ] **Step 4: Run the tests and confirm they pass.** Same command. Expected: 8 tests PASS.

- [ ] **Step 5: Commit**
```bash
git add local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcSession.kt local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcSessionTest.kt
git commit -m "feat(cluster): authenticated, encrypted PLMC session over TCP"
```

---

### Task 3: Kotlin worker and master relays

**Files:**
- Create: `local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcRelays.kt`
- Test: `local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcRelaysTest.kt`

**Interfaces:**
- Consumes: `PlmcHandshake` and `PlmcSession` (Task 2).
- Produces:
  - `class WorkerRelay(publicPort: Int, upstreamPort: Int, keySupplier: () -> ByteArray?, bindAddress: InetAddress = InetAddress.getByName("0.0.0.0"))` with:
    - `fun start()`
    - `fun stop()`
    - `fun dropAll()`: closes every live session
    - `val peer: String?`: IP of the most recent authenticated master that's still connected, or null

    Each accepted socket gets its own thread, so one stuck handshake can't block others. Open `Socket("127.0.0.1", upstreamPort)` only after the handshake succeeds.
  - `class MasterRelay(workerHost: String, workerPort: Int, key: ByteArray)` with `fun start(): Int` and `fun stop()`. `start()` binds `127.0.0.1:0` and returns the local port. Each local accept dials the worker with a 2 s connect timeout, runs `PlmcHandshake.client`, then pumps.
  - `object MasterRelays` with:
    - `fun use(targets: List<RelayTarget>): List<String>`: stops the previous relays and returns `"127.0.0.1:<port>"` per target, in order
    - `fun clear()`
    - `fun displayName(localEndpoint: String): String`: maps back to `"host:port"` of the worker, or returns the input unchanged

    Here `data class RelayTarget(val host: String, val port: Int, val key: ByteArray)`.
  - Pumping: plaintext side reads into a 64 KiB buffer and calls `session.write`. Encrypted side calls `session.read()` and writes to the plain socket. When either side ends, both sockets close.

- [ ] **Step 1: Write the failing tests** in `PlmcRelaysTest.kt`. Use an echo `ServerSocket` on loopback as the fake RPC upstream, a `WorkerRelay` on a free port bound to loopback (pass `InetAddress.getLoopbackAddress()`), and a `MasterRelay` pointed at it.
  - `echoThroughBothRelays`: connect a plain socket to the master relay's local port. Write `"abc"`, then read `"abc"`.
  - `largeTransferIsByteExact`: 64 MiB of `Random(42)` bytes, written in uneven chunks (e.g. 7 KiB, 1.3 MiB, 3 bytes, repeating). The echo returns an identical SHA-256. Print the throughput in MB/s; don't assert on it.
  - `wrongKeyNeverReachesUpstream`: give the master relay a different key, then connect and write. The echo server's accept count stays 0, and the client socket reaches EOF.
  - `idleConnectionTimesOutAndDoesNotBlockOthers`: open a raw socket to the worker relay and send nothing. Meanwhile, `echoThroughBothRelays` still succeeds within 1 s. The idle socket reads EOF within 6 s.
  - `dropAllClosesLiveSessions`: during an open echo session, `dropAll()` makes the client's next read return EOF within 1 s.
  - `keySupplierIsReadPerConnection`: change the supplier's key after the first session. A new master relay with the old key fails, and one with the new key works.

- [ ] **Step 2: Run the tests and confirm they fail.**
  Run: `cd android && ./gradlew :llama_flutter_android:testDebugUnitTest --tests 'com.write4me.llama_flutter_android.PlmcRelaysTest'`
  Expected: compilation failure, `Unresolved reference: WorkerRelay`.

- [ ] **Step 3: Implement `PlmcRelays.kt`** with the interfaces above. Use daemon threads. Keep a `ConcurrentHashMap.newKeySet<Socket>()` of live sockets for `dropAll` and `stop`. Never log keys; log only the peer IP and failure class.

- [ ] **Step 4: Run all Plmc tests and confirm they pass.**
  Run: `cd android && ./gradlew :llama_flutter_android:testDebugUnitTest --tests 'com.write4me.llama_flutter_android.Plmc*'`
  Expected: 20 tests PASS. The throughput line is printed.

- [ ] **Step 5: Commit**
```bash
git add local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PlmcRelays.kt local_plugins/llama_flutter_android/android/src/test/kotlin/com/write4me/llama_flutter_android/PlmcRelaysTest.kt
git commit -m "feat(cluster): worker and master relays over PLMC sessions"
```

---

### Task 4: Android pairing store and wiring

**Files:**
- Create: `local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/PairingStore.kt`
- Modify: `ClusterWorkerService.kt`. Change the `nativeServe` call at lines 108-113 to `"127.0.0.1:50053"`. Start or stop a `WorkerRelay` around it. Add `ACTION_RESET_PAIRING` to the companion object at lines 39-48. The status loop at line 122 takes the peer from `WorkerRelay.peer`.
- Modify: `ClusterChannel.kt`. Update `onMethodCall` (lines 70-188), `probe` (lines 224-234), and `lastLoadBuffers` (line 136) to map names through `MasterRelays.displayName`. Call `MasterRelays.clear()` in `dispose`.

**Interfaces:**
- Consumes: `WorkerRelay`, `MasterRelays`, `RelayTarget`, `PlmcHandshake.client` and `PlmcAuthException` (Tasks 2-3).
- Produces:
  - `class PairingStore(context: Context)` with:
    - `fun workerSecret(): ByteArray`: creates and stores one if absent or if it can't be decrypted
    - `fun resetWorkerSecret(): ByteArray`
    - `fun setMasterKey(workerId: String, key: ByteArray)`
    - `fun masterKey(workerId: String): ByteArray?`
    - `fun removeMasterKey(workerId: String)`

    Storage details:
    - AndroidKeyStore AES-256-GCM key, alias `privatelm_pairing`
    - files `filesDir/pairing/worker.bin` and `filesDir/pairing/m_<sha256(workerId) hex>.bin`, each holding `iv(12)‖ciphertext`
    - written to a temp file, then renamed

    The `:cluster` service process and the main process both use it, so read from disk on every call and don't cache.
  - Method channel `llama_flutter_android/cluster`:
    - `"workerPairingKey"`: returns base64url without padding of `workerSecret()`
    - `"resetPairing"`: `resetWorkerSecret()`, then, if the worker is running, `startService` with `ACTION_RESET_PAIRING`. The service calls `relay.dropAll()`.
    - `"pairWorker" {id: String, key: String}`: decode base64url and require exactly 32 bytes (else `result.error("BAD_KEY", …)`), then `setMasterKey`
    - `"forgetWorker" {id}`: `removeMasterKey`
    - `"probe" {endpoint, id}`: returns `"ok"`, `"unreachable"`, `"rejected"` or `"unpaired"`. It dials with a 2000 ms timeout and runs `PlmcHandshake.client` with `masterKey(id)`, closing right after. A missing key gives `unpaired`, `PlmcAuthException` gives `rejected`, and any other exception gives `unreachable`.
    - `"setCluster" {endpoints, ids, weights, localWeight}`: probes every worker as above. On the first failure it returns `result.error` with code `UNPAIRED`, `REJECTED` or `UNREACHABLE`, and the message names the worker endpoint. Otherwise it calls `nativeSetCluster(MasterRelays.use(targets).toTypedArray(), …)`. An empty list calls `MasterRelays.clear()`.

- [ ] **Step 1: Implement `PairingStore.kt`** with the interface above.

- [ ] **Step 2: Wire up `ClusterWorkerService`.**
  - `nativeServe` endpoint becomes `"127.0.0.1:50053"`.
  - Start `WorkerRelay(port, 50053, { PairingStore(this).workerSecret() })` before the native serve thread.
  - Handle `ACTION_RESET_PAIRING` in `onStartCommand`, calling `relay.dropAll()` without restarting.
  - `relay.stop()` in `shutdown()`.
  - Keep the secret out of `writeStatus` and the NSD TXT record.

- [ ] **Step 3: Wire up `ClusterChannel`** with the method-channel contract above. Delete the old plain-TCP `probe`.

- [ ] **Step 4: Build and confirm it compiles.**
  Run: `flutter build apk --debug` (repo root)
  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 5: Re-run the Plmc unit tests.**
  Run: `cd android && ./gradlew :llama_flutter_android:testDebugUnitTest`
  Expected: all PASS, including the existing `ChatTemplateTest`.

- [ ] **Step 6: Commit**
```bash
git add local_plugins/llama_flutter_android/android/src/main/kotlin/com/write4me/llama_flutter_android/
git commit -m "feat(cluster): Android workers serve only through the PLMC relay"
```

---

### Task 5: Swift protocol core

**Files:**
- Create: `local_plugins/llama_flutter_android/ios/Classes/PlmcProtocol.swift`
- Test: `local_plugins/llama_flutter_android/ios/PlmcTests/main.swift`. This sits outside `Classes/`, so the podspec doesn't ship it.

**Interfaces:**
- Consumes: `test_vectors/plmc_v1.json` (Task 1).
- Produces (Swift, Foundation and CryptoKit only, so it compiles with plain `swiftc`):
  - `enum Plmc` with the same constants as Kotlin: `magic`, `version`, `nonceLen`, `tagLen`, `maxPlaintext`, `handshakeTimeout: TimeInterval = 5`
  - `static func serverTag(key: Data, nc: Data, ns: Data) -> Data` and `clientTag(...)`
  - `static func deriveKeys(key: Data, nc: Data, ns: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey)`
  - `static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool`
  - `final class PlmcFrameSealer` with `init(key: SymmetricKey)` and `func seal(_ plain: Data) throws -> Data`
  - `final class PlmcFrameOpener` with `init(key:)` and `func open(_ sealed: Data) throws -> Data`

  The nonce layout is identical to Kotlin: 4 zero bytes, then a big-endian `UInt64` counter.

- [ ] **Step 1: Write the failing test** `PlmcTests/main.swift`. It reads the vectors path from `CommandLine.arguments[1]` and asserts each Task 1 vector:
  - tags, keys, and frame0/frame1 seal in order
  - opening frame0 and frame1
  - a tampered frame0 throws
  - out-of-order open throws

  It prints `PASS <name>` per check, and on the first failure it prints `FAIL <name>` and calls `exit(1)`.

- [ ] **Step 2: Run the test and confirm it fails.**
  Run: `cd local_plugins/llama_flutter_android && swiftc -o "$TMPDIR/plmc_test" ios/Classes/PlmcProtocol.swift ios/PlmcTests/main.swift && "$TMPDIR/plmc_test" test_vectors/plmc_v1.json`
  Expected: compile error, `cannot find 'Plmc' in scope`.

- [ ] **Step 3: Implement `PlmcProtocol.swift`.**

- [ ] **Step 4: Run the test and confirm it passes.** Same command. Expected: every line is `PASS`, and the exit code is 0.

- [ ] **Step 5: Commit**
```bash
git add local_plugins/llama_flutter_android/ios/Classes/PlmcProtocol.swift local_plugins/llama_flutter_android/ios/PlmcTests
git commit -m "feat(cluster): Swift PLMC v1 core matching the shared vectors"
```

---

### Task 6: iOS worker relay, Keychain and wiring

**Files:**
- Create: `local_plugins/llama_flutter_android/ios/Classes/PlmcWorkerRelay.swift`
- Create: `local_plugins/llama_flutter_android/ios/Classes/PairingKeychain.swift`
- Modify: `ios/Classes/LlamaClusterWorker.mm:96`, where the endpoint becomes `"127.0.0.1:" + rpcPort`. Update the matching `startOnPort:` signature in `LlamaClusterWorker.h` to add `rpcPort:(int)rpcPort`. `connectedPeer` is no longer used by Swift.
- Modify: `ios/Classes/ClusterChannel.swift`. `startWorker(port:)` (lines 81-106) starts the relay. Add the `"workerPairingKey"` and `"resetPairing"` cases. `workerStatus` reports the peer from the relay.

**Interfaces:**
- Consumes: `Plmc`, `PlmcFrameSealer` and `PlmcFrameOpener` (Task 5).
- Produces:
  - `enum PairingKeychain` with `static func workerSecret() -> Data` (create if absent) and `static func resetWorkerSecret() -> Data`. Store it as a generic password with service `com.privatelm.cluster.pairing`, account `worker`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  - `final class PlmcWorkerRelay` with:
    - `init(publicPort: UInt16, upstreamPort: UInt16, keySupplier: @escaping () -> Data)`
    - `func start() throws`
    - `func dropAll()`
    - `var peer: String? { get }`

    Use `NWListener` on the public port, and an `NWConnection` to `127.0.0.1:upstreamPort` opened only after the handshake. The wire format is identical to Kotlin's `PlmcHandshake.server` and `PlmcSession`, including the 5 s handshake timeout and the frame length bounds. Each connection runs on its own serial queue.
  - Method channel: `"workerPairingKey"` returns base64url without padding. `"resetPairing"` calls `resetWorkerSecret()` then `relay.dropAll()`. `pairWorker`, `forgetWorker` and `probe` stay unsupported on iOS: `probe` keeps returning `false`, which Dart maps to unreachable.

- [ ] **Step 1: Implement `PairingKeychain.swift`.**
- [ ] **Step 2: Implement `PlmcWorkerRelay.swift`.**
- [ ] **Step 3: Change `LlamaClusterWorker` to bind the RPC server to `127.0.0.1:50053`,** and update `ClusterChannel.startWorker` to start the relay on `port` (50052) with upstream 50053 before advertising.
- [ ] **Step 4: Build and confirm it compiles.**
  Run: `flutter build ios --debug --no-codesign` (repo root)
  Expected: `✓ Built build/ios/iphoneos/Runner.app`.
- [ ] **Step 5: Interop smoke test.** This is the same wire format checked from Kotlin, so it doesn't need a device. Add `PlmcRelaysTest.interopWithSwiftWorker`, annotated `@EnabledIfEnvironmentVariable(named = "PLMC_SWIFT_WORKER", matches = ".+")`. It connects a `MasterRelay` to the host:port in that variable and round-trips `"abc"`. Build a tiny macOS harness, `ios/PlmcTests/relay_main.swift` compiled with `PlmcProtocol.swift` and `PlmcWorkerRelay.swift`, that runs a relay on 50052 in front of an echo server on 50053, using the key bytes `0x00…0x1f`.
  Run: build and start the harness, then `PLMC_SWIFT_WORKER=127.0.0.1:50052 ./gradlew :llama_flutter_android:testDebugUnitTest --tests '*interopWithSwiftWorker'`
  Expected: PASS.
- [ ] **Step 6: Commit**
```bash
git add local_plugins/llama_flutter_android/ios local_plugins/llama_flutter_android/android/src/test
git commit -m "feat(cluster): iOS workers serve only through the PLMC relay"
```

---

### Task 7: Dart plugin API and QR format

**Files:**
- Modify: `local_plugins/llama_flutter_android/lib/src/llama_cluster.dart`:
  - `ClusterWorker` (lines 5-56): add `paired`
  - `probe` (lines 164-167)
  - `setCluster` (lines 169-185)
  - the doc comment at lines 97-102: replace "The RPC protocol has no authentication…" with a sentence saying workers accept only masters that scanned their code, and traffic is encrypted
- Create: `lib/services/cluster_qr.dart`
- Test: `test/cluster_qr_test.dart` and `test/cluster_worker_test.dart`

**Interfaces:**
- Produces (plugin):
  - `ClusterWorker.paired` (`bool`, default `false`). `fromMap` reads `map['paired'] as bool? ?? false`, `toMap` writes it, and `movedTo` keeps it.
  - `enum ProbeResult { ok, unreachable, rejected, unpaired }`
  - `LlamaCluster.probe(ClusterWorker w) → Future<ProbeResult>`: sends `{endpoint, id}`. An unknown string, `false` or `null` becomes `unreachable`.
  - `LlamaCluster.workerPairingKey() → Future<String>`
  - `LlamaCluster.resetPairing() → Future<void>`
  - `LlamaCluster.pairWorker(String id, String key) → Future<void>`
  - `LlamaCluster.forgetWorker(String id) → Future<void>`
  - `setCluster` also sends `'ids': [for (w in workers) w.id ?? '']`
- Produces (app, `cluster_qr.dart`):
  - `const clusterQrScheme = 'privatelm'` (move `_qrScheme` here from `cluster_service.dart`)
  - `const clusterQrVersion = 1`
  - `String buildWorkerQr({required String host, required int port, required String id, required String key, String? name, int? ramMb, double? bandwidth})`
  - `({ClusterWorker worker, String key}) parseWorkerQr(String data)`: returns the worker with `paired: true`. It throws `FormatException` whose `.message` is the exact user-facing copy from Global Constraints.

- [ ] **Step 1: Write the failing tests.**

  `test/cluster_qr_test.dart`:
  - `roundTrip`: `parseWorkerQr(buildWorkerQr(...))` gives back the same host, port, id, name, ramMb and bandwidth, the same key, and `paired == true`
  - `rejectsNonPrivateLmCode`: `'https://example.com'` throws with `"That isn't a PrivateLM worker code"`
  - `oldWorkerCodeAsksToUpdateWorker`: a URI with no `key` and no `v` throws `"This worker needs a newer PrivateLM. Update it, then scan again."`. The same applies when `key` is present but `id` is missing.
  - `newerWorkerCodeAsksToUpdateThisPhone`: `v=2` throws `"Update PrivateLM on this phone to add this worker."`
  - `rejectsKeyThatIsNotExactly32Bytes`: a 31-byte key and a non-base64url key both throw `"That isn't a PrivateLM worker code"`

  `test/cluster_worker_test.dart`:
  - `legacyMapIsUnpaired`: `ClusterWorker.fromMap({'name':'a','host':'1.2.3.4','port':50052})` gives `paired == false`
  - `pairedSurvivesToMapAndMovedTo`

- [ ] **Step 2: Run the tests and confirm they fail.**
  Run: `flutter test test/cluster_qr_test.dart test/cluster_worker_test.dart`
  Expected: compile errors, `buildWorkerQr` and `paired` not defined.

- [ ] **Step 3: Implement the plugin API changes and `cluster_qr.dart`.**

- [ ] **Step 4: Run the tests and confirm they pass.** Same command. Expected: all PASS.

- [ ] **Step 5: Commit**
```bash
git add local_plugins/llama_flutter_android/lib lib/services/cluster_qr.dart test/cluster_qr_test.dart test/cluster_worker_test.dart
git commit -m "feat(cluster): QR codes carry the pairing key; probe reports rejection"
```

---

### Task 8: Cluster service and UI

**Files:**
- Modify: `lib/services/cluster_service.dart`:
  - `workerQrData` (lines 161-173), `startWorker`
  - `addFromQr` (lines 239-255)
  - delete `addManual` (lines 258-269), `addFound` (line 271), `scanNearby` and `found`/`isScanning`
  - `relocateWorkers` (lines 276-300), `_add` (lines 302-312), `remove` (lines 314-317)
  - load planning, which must leave out unpaired workers
- Modify: `lib/views/cluster_view.dart`:
  - delete the "Enter worker IP" dialog (around line 303) and the nearby-workers list with its Add button (around line 267)
  - add the QR warning, the Reset pairing action, and the unpaired tile state
- Test: `test/cluster_service_relocate_test.dart`

**Interfaces:**
- Consumes: Task 7 plugin API and `cluster_qr.dart`.
- Produces:
  - `ClusterService.pairingKey` (`RxnString`), loaded with `LlamaCluster.workerPairingKey()` when the worker starts and after a reset
  - `ClusterService.resetPairing() → Future<void>`
  - `ClusterService.relocateWorkers` gains an injectable seam for tests: a constructor or field `Future<ProbeResult> Function(ClusterWorker) probe` and `Future<List<ClusterWorker>> Function() discover`, defaulting to `LlamaCluster.probe` and `LlamaCluster.discover`
  - `PlatformException` code `REJECTED` from `setCluster` maps to `This worker was reset. Scan its code again.`, and `UNPAIRED` maps to `Scan again to reconnect`

- [ ] **Step 1: Write the failing tests** in `test/cluster_service_relocate_test.dart`. Use the probe and discover seams with fakes, and an in-memory Hive in the same way as `test/hive_service_test.dart`.
  - `relocateUpdatesAddressWhenNewAddressAuthenticates`: stored worker `id=w1` at `10.0.0.5`. The probe gives `unreachable` at the old address and `ok` at the new one, and discover returns `w1` at `10.0.0.9`. Afterwards, `workers.single.host == '10.0.0.9'`.
  - `relocateIgnoresIdMatchThatFailsAuth`: same setup, but the probe at the new address gives `rejected`. The host stays `10.0.0.5`, and the worker appears in the returned unreachable list.
  - `relocateSkipsUnpairedWorkers`: a worker with `paired == false` is never probed (the fake probe records calls) and is returned as unreachable.

- [ ] **Step 2: Run the tests and confirm they fail.**
  Run: `flutter test test/cluster_service_relocate_test.dart`
  Expected: FAIL, because the seams don't exist yet.

- [ ] **Step 3: Implement the service changes.**
  - `addFromQr`: `parseWorkerQr` (show the `FormatException` message), then `pairWorker(id, key)`, then `probe`. If the result isn't `ok`, call `forgetWorker(id)` and return a message: `rejected` gets the Rejected copy, and anything else gets the existing "Can't reach …" message. If it is `ok`, save with `paired: true`.
  - `remove`: also calls `forgetWorker(id)` when `id != null`.
  - `workerQrData`: returns null until `pairingKey` is loaded, then `buildWorkerQr(...)`.

- [ ] **Step 4: Update the UI in `cluster_view.dart`.**
  - The QR warning goes directly under the QR code, in the existing secondary text style.
  - "Reset pairing" is a `TonalButton` on the worker screen. Its confirm dialog uses the exact copy, and confirming calls `cluster.resetPairing()`.
  - On the master, a worker tile with `!paired` shows the subtitle `Scan again to reconnect` and drops out of loads.
  - Scanning is the only add action left.

- [ ] **Step 5: Run the whole Dart suite and the analyzer.**
  Run: `flutter analyze && flutter test`
  Expected: `No issues found!`, and all tests PASS. That includes the 8 existing test files plus the 3 new ones.

- [ ] **Step 6: Commit**
```bash
git add lib/services/cluster_service.dart lib/views/cluster_view.dart test/cluster_service_relocate_test.dart
git commit -m "feat(cluster): QR-only pairing, reset pairing, re-scan for old pairings"
```

---

### Task 9: Device verification, performance, docs

**Files:**
- Modify: `README.md`. Under "What It Does", add one bullet for phone clusters: QR pairing, encrypted traffic, Reset pairing.
- Create (after Ismael approves the text): `DECISIONS.md` at the repo root, with an ADR for "Cluster traffic secured by PLMC relays instead of patching ggml-rpc".

- [ ] **Step 1: Baseline.** On `main` (before this branch), run one Android master and one Android worker with the same GGUF model, ≥ 2 GB. Record the model load time and tokens/s over 3 runs.
- [ ] **Step 2: Branch run.** Same devices, model and prompt. Expected: load time and tokens/s within about 10% of the baseline. If they're outside that, stop and report the numbers to Ismael before continuing.
- [ ] **Step 3: Security checks on the device.**
  - `nc <worker-ip> 50052 <<< "junk"` disconnects with no response bytes.
  - `nc -vz <worker-ip> 50053` from another machine is refused.
  - Reset pairing on the worker makes the master show `This worker was reset. Scan its code again.`
  - Re-scanning recovers.
  - Turning the worker's Wi-Fi off and on, or switching networks, lets the master re-find it by ID.
  - A pre-upgrade saved worker shows `Scan again to reconnect`.
- [ ] **Step 4: Android master with an iOS worker (iPad).** Pair, load, chat and reset, as in Step 3.
- [ ] **Step 5: Leak check.** `adb logcat | grep -i -E "key=|$(<base64 key prefix>)"` returns nothing during pairing and load. Confirm that `cluster_worker_status.json` and the NSD TXT record have no key.
- [ ] **Step 6: Update the README. Draft the DECISIONS.md entry and show it to Ismael.** Write it only after he confirms.
- [ ] **Step 7: Commit**
```bash
git add README.md DECISIONS.md
git commit -m "docs: phone cluster security; record relay decision"
```
