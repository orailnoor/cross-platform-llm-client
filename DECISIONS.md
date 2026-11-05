# Decisions

Architecture decisions for PrivateLM, newest first. Each entry: Context /
Decision / Rationale / Alternatives considered / Date.

## 2026-11-06 — Secure the phone cluster with PLMC relays, not a ggml-rpc patch

**Context:** Cluster workers ran llama.cpp's RPC server on 0.0.0.0:50052 with no
authentication or encryption. The app is shipped to other people, who will run
workers on public Wi-Fi. llama.cpp warns this server must never face an
untrusted network.

**Decision:** The RPC server binds 127.0.0.1:50053. A relay on 0.0.0.0:50052
(Kotlin on Android, Swift on iOS) admits only masters that prove they hold the
worker's 32-byte pairing secret (mutual HMAC-SHA256 handshake, "PLMC v1"), then
carries AES-256-GCM frames. The Android master runs a matching loopback relay
per worker. The secret travels only in the worker's QR code, so pairing is
QR-only, lasts across sessions, and "Reset pairing" revokes it. Secrets live in
the Android Keystore or the iOS Keychain.

**Rationale:** Leaves llama.cpp untouched, so upgrades stay cheap. Uses only
platform crypto. Is safe against eavesdropping, tampering, replay and
impersonation on shared networks.

**Alternatives considered:** Patching ggml-rpc's socket layer (diverges from
upstream on every upgrade); a password without encryption (open to passive
sniffing and session hijack on public Wi-Fi); TLS with self-signed certs
(awkward certificate generation on Android without extra libraries).

**Details:** `docs/superpowers/specs/2026-11-06-cluster-secure-pairing-design.md`
