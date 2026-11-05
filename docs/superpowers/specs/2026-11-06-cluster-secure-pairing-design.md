# Phone cluster: secure pairing and encrypted worker traffic

Date: 2026-11-06
Status: Draft, awaiting approval

## Why

The phone cluster is going to be shipped to other people, who will start
workers on networks they don't control: cafés, offices, hotels. Today a worker
runs llama.cpp's RPC server on `0.0.0.0:50052`
(`ClusterWorkerService.kt:110`, `LlamaClusterWorker.mm:96`), with no
authentication or encryption, and announces itself over Bonjour/NSD. llama.cpp's
own docs say this server must never be exposed to an untrusted network. It
trusts every connection, handles raw memory buffers, and has had memory-safety
bugs in the past.

Anyone on the same Wi-Fi can find a worker and drive it: use its compute, crash
it, or, through a memory bug, run code inside PrivateLM's process, where they
could read chats and API keys. A passive listener can also read the
master↔worker traffic, which carries activations that can reveal what's being
asked.

Success: a worker can sit on a hostile public network, and nobody without its
QR code can connect to it, read its traffic, or change that traffic.

## Goals

- Only a master holding the worker's secret can connect to a worker.
- All master↔worker traffic is encrypted and integrity-protected. Tampering,
  replay, or reordering closes the connection.
- The worker's raw RPC port is never reachable from the network.
- Pairing is "scan once, keep working", including after the worker changes
  network or IP.
- A worker can revoke all its pairings at once.
- llama.cpp source (`ggml-rpc.cpp` and the vendored trees) stays unmodified, so
  upgrades stay cheap.
- Model load and generation speed stay about the same (see Verification).

## Non-goals

- Protection against a malicious app already installed on the master or worker
  phone. Both loopback ports (the worker's raw RPC port and the master's local
  relay port) can be reached by other apps on the same device. This is accepted
  and noted in the code.
- Hiding that a PrivateLM worker exists on the network. Bonjour still
  announces it, but only with its ID, never the secret.
- Securing the OpenAI-compatible API server. It already has its own API-key
  auth and is out of scope here.
- iOS as master. iOS stays worker-only (`ClusterChannel.swift:67`).

## Anti-goals (a failure even if it "works")

- Any path that connects to a worker without the secret, including a "legacy"
  or "fallback" mode for old pairings.
- The secret appearing in logs, Crashlytics, the Bonjour TXT record, Hive
  settings, or Android/iCloud backups.
- Rolling our own primitives. Use only platform crypto (`javax.crypto`,
  CryptoKit) and standard constructions.

## Decisions made with Ismael

1. **Must be safe on public networks**, which means authentication *and*
   encryption, not just a password.
2. **QR scan is the only way to add a worker.** Remove typed IP entry
   (`addManual`, "Enter worker IP" in `cluster_view.dart`) and tapping a
   discovered worker (`addFound`, `cluster_view.dart:267`).
3. **The secret lasts across sessions:** pair once, and it keeps working.

## Design

### Shape

```
 MASTER (Android)                                   WORKER (Android / iOS)
 llama.cpp RPC client                               llama.cpp RPC server
   │ connects to 127.0.0.1:<local port>               ▲ listens on 127.0.0.1:<rpc port>
   ▼                                                  │
 Master relay (Kotlin) ── encrypted TCP ──►  Worker relay (Kotlin / Swift)
                                              listens on 0.0.0.0:50052
```

- **Worker:** the RPC server binds `127.0.0.1` on an internal port. A relay
  listens on the public port (50052, unchanged). It authenticates each incoming
  connection and only then opens a loopback connection to the RPC server and
  pipes decrypted bytes both ways.
- **Master:** for each worker in the cluster, `ClusterChannel.kt` starts a
  relay on `127.0.0.1:<ephemeral>`. The endpoints passed to the native loader
  (`g_cluster_endpoints` in `jni_wrapper.cpp`) become these local relay
  addresses, and each relay dials the real worker and runs the handshake. Map
  local endpoints back to worker names wherever they're shown
  (`lastLoadBuffers`, `RPC0[host:port]`, error messages).
- Relays stop when cluster mode is turned off or the worker stops.

### Secret

- 32 random bytes from the platform CSPRNG, created the first time a worker
  starts.
- **Worker:** stored in secure storage on the native side. On Android, a
  Keystore-wrapped AES key encrypts the stored secret. On iOS, use the Keychain
  with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which means no
  iCloud sync.
- **Master:** per-worker secrets live on the native side the same way, keyed by
  worker ID. Dart never stores them in Hive. The Dart `ClusterWorker` record
  keeps a `paired: bool` (or similar) only.
- **Reset pairing** (worker UI) replaces the secret. Every existing master
  then fails authentication.
- **Removing a worker** on the master deletes its stored secret.

### QR code

Existing `privatelm://worker?...` URI (`cluster_service.dart:162`) plus
`key=<base64url secret, no padding>`, plus `v=1`, the protocol version.
`addFromQr` rejects a code without `key` or with an unknown `v`, and shows "This
worker needs a newer PrivateLM" or "Update PrivateLM on this phone". Show this
warning under the QR on the worker screen: "Anyone who scans this code can use
this phone as a worker. Don't share it."

### Handshake and framing (protocol v1)

K = 32-byte secret. All MACs are HMAC-SHA256. All lengths are big-endian.

1. Client → server: magic `PLMC` + version byte `0x01` + `Nc` (32 random bytes).
2. Server → client: `Ns` (32 random bytes) + `HMAC(K, "PLMC1 server" ‖ Nc ‖ Ns)`.
3. The client verifies the server's tag in constant time, then sends
   `HMAC(K, "PLMC1 client" ‖ Nc ‖ Ns)`.
4. The server verifies the client's tag in constant time. On any failure,
   either side closes the socket without sending an error.
5. Session keys: `HKDF-SHA256(ikm=K, salt=Nc‖Ns)`, with info `"PLMC1 c2s"` and
   `"PLMC1 s2c"`, 32 bytes each.
6. Frames: 4-byte ciphertext length + AES-256-GCM ciphertext and tag. The nonce
   is a 96-bit per-direction counter, starting at 0 and never reused. Close the
   connection if it would wrap. Max plaintext per frame is 1 MiB. Reject larger
   lengths before allocating.

- Handshake timeout: 5 s.
- The worker opens the loopback RPC connection only after step 4.

Both sides prove they know K, so a fake worker can't impersonate a paired one.
That also matters for re-finding by ID: an attacker announcing a stolen ID
still fails step 3. Fresh nonces on both sides stop replay.

### Probe and re-finding workers

- `probe(endpoint)` (`ClusterChannel.kt:224`) runs the handshake with the
  stored secret and closes. "Reachable" means "reachable and authenticated".
- `relocateWorkers` (`cluster_service.dart:276`) keeps matching by ID through
  Bonjour, then must pass the authenticated probe before it updates the stored
  address.
- The Bonjour TXT record keeps advertising ID, RAM, and speed, and never the
  secret.

### Existing pairings

Saved workers without a secret are shown as "Scan again to reconnect" and are
left out of loads. There's no fallback to unprotected connections.

### UI changes (`cluster_view.dart`)

- Remove "Enter worker IP" and "Add" on discovered workers. Scanning is the
  only add action.
- Worker screen: QR warning text and a "Reset pairing" action, with a
  confirmation.
- Master worker list: "Scan again" state for unpaired or legacy workers.
  Authentication failure shows "This worker was reset. Scan its code again."

### Docs to update

- `llama_cluster.dart:101` ("The RPC protocol has no authentication…")
- README cluster section, if one is added later. Note pairing is QR-only and
  encrypted.

## Verification

- **Protocol test vectors.** A fixed K, Nc, Ns, and plaintext give expected
  tags, keys, and the first frame. These are checked in as one file and
  asserted by both a Kotlin JVM unit test and a Swift test, so Android and iOS
  can't drift apart.
- **Kotlin unit tests:**
  - wrong key is rejected
  - truncated or oversized frames are rejected
  - a tampered ciphertext closes the connection
  - a replayed handshake fails
  - counter nonces increase
- **Dart unit tests:**
  - `addFromQr` requires `key` and a supported `v`
  - legacy workers are marked unpaired
  - `addManual` and `addFound` are gone
- **Manual, on real devices:**
  - Android master + Android worker, and Android master + iOS worker: pair,
    load a model, chat, move the worker to a new IP, re-find it, reset
    pairing, and confirm the master gets refused.
  - `nc <worker-ip> 50052` with junk gets disconnected.
  - From another machine, nothing answers on the internal RPC port.
- **Performance:** load time and tokens/s for the same model and devices,
  before and after. Goal: within about 10%. If it's worse, report it before
  going further.

## Left to the builder

- Threading model of the relays (threads vs coroutines on Android,
  Network.framework vs BSD sockets on iOS).
- Internal RPC port choice (fixed `50053` vs ephemeral passed to
  `nativeServe`).
- Exact secure-storage wrapper code and the method-channel API for the
  secret (e.g. `workerPairingCode()`, `resetPairing()`, `setWorkerKey(id, key)`).
- Copy wording, as long as it carries the meaning above.
- Backoff on repeated handshake failures (nice to have; a 256-bit secret makes
  brute force a non-issue, so this is DoS-only).
