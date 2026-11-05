# Desktop worker test results

Date: 2026-11-05. Repository source commit: `8a5f3b0c0ca8c2108b76ac9619fe5faf6a6a098e` (`orailnoor/cross-platform-llm-client`). Android's vendored llama.cpp RPC source reports protocol `7.0.0`; desktop worker source is upstream llama.cpp `b11157`, commit `53ed051ce5e8193652e449f43216ca3859454f49`.

## Hardware and model

- Laptop: ASUS TUF F15, Linux/Omarchy, NVIDIA RTX 4060 Laptop GPU with 8 GB VRAM, 16 GB system memory, CUDA toolkit 13.4.
- Phone: Samsung Galaxy S24 Ultra, Android, PrivateLM Cluster Master. The installed app version was not read from the device.
- Phone and laptop used the same Wi-Fi. The test worker bound to laptop address `192.168.0.10:50052`; UFW allowed that TCP port only from phone address `192.168.0.5` during the test.
- Model: `LiquidAI/LFM2.5-1.2B-Instruct-GGUF`, Q4_K_M, 730,895,168 bytes, SHA-256 `b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5`. The model uses LFM Open License v1.0. No model file is part of this change.
- Prompt: `Write a 25-word story about a robot finding a garden. Use no introduction.`

## Phone and RPC result

The phone accepted the worker address and generated an answer with LFM2.5. The user reported an app rate of `8.2 tk/s` and a layer allocation of 83% phone / 17% laptop. The worker log showed a connection from `192.168.0.5`, remote buffer allocations, and repeated RPC `graph_compute` requests during phone generation. The RTX 4060 showed approximately 573 MiB VRAM use during an observed phone RPC session.

This proves that this phone and this desktop build exchanged compute requests and generated output. It does not establish that every PrivateLM release or every model is RPC-compatible. The app version and its timing method were not read from the phone.

The first app-listed Qwen model was LiteRT and could not be shared with cluster workers. It was not used for the phone test. A separately downloaded Apache-2.0 Qwen GGUF was used for an earlier laptop-to-local-RPC smoke test only.

## Laptop-only measurement

The local laptop used the same LFM2.5 GGUF and prompt after one warm-up. Each measured CLI run used context 1024, 40 predicted tokens, temperature 0, seed 42, 8 CPU threads, and all model layers on CUDA. The prompt tokenization and generation count were 27 and 33 tokens.

| Run | Prompt processing | Generation | Eval time |
|---|---:|---:|---:|
| 1 | 1,373.98 tokens/s | 272.99 tokens/s | 117.22 ms |
| 2 | 1,291.62 tokens/s | 269.22 tokens/s | 118.86 ms |
| 3 | 1,330.90 tokens/s | 265.95 tokens/s | 120.32 ms |
| Mean | 1,332.17 tokens/s | 269.39 tokens/s | 118.80 ms |

These are llama.cpp CLI timings, not app timings. The phone and CLI did not expose matching context, tokenization, or timing controls. In a separate phone-only run, the user reported `23.2 tokens/s`; they noted that the answer was random. The single hybrid rate of `8.2 tokens/s` was about 2.8 times slower than that single phone-only rate. This is an app-reported observation, not a controlled benchmark. Neither phone run exposed time to first token, and neither rate was repeated three times.

The user ran the phone-only prompt two more times, but both runs failed with PrivateLM's `failed to decode prompt` error. Treat the phone-only and phone-plus-desktop rates as one successful observation each, not stable averages.

The desktop launcher was also tested against the CUDA RPC server on loopback. With the same LFM2.5 file, prompt, and CLI settings, and with CUDA hidden from the client, three runs generated at `248.44`, `244.40`, and `247.35 tokens/s` through RPC. Mean generation was `246.73 tokens/s`, about 8.3% below the mean direct-CUDA rate. This is a local loopback comparison, not a Wi-Fi or phone benchmark.

## Commands and outcomes

- RPC source build: CMake configured llama.cpp `b11157` with `GGML_CUDA=ON`, `GGML_RPC=ON`; `cmake --build ... --target ggml-rpc-server --parallel 4` passed.
- Worker launcher invocation: `desktop-worker/scripts/start-worker.sh --server ../build-rpc-cuda/bin/ggml-rpc-server --host 127.0.0.1 --port 50053 --device CUDA0 --threads 4` started the pinned CUDA server. It reported RPC protocol `7.0.0` and RTX 4060 Laptop GPU with 7888 MiB.
- Laptop inference through local RPC, with local CUDA hidden from the client: `CUDA_VISIBLE_DEVICES='' GGML_RPC_DEBUG=1 llama-cli --model qwen2-0.5b-instruct-q4_k_m.gguf --prompt 'Write a 25-word story about a robot finding a garden. Use no introduction.' --n-predict 32 --ctx-size 1024 --gpu-layers 99 --threads 8 --threads-batch 8 --temp 0 --seed 42 --no-display-prompt --single-turn --rpc 192.168.0.10:50052 --verbose` passed. The client assigned all model layers to RPC0; the server logged RPC buffer allocations and graph compute. This verified RPC locally, not from the phone.
- A reachable HTTP server was also given to `llama-cli` as an RPC endpoint. The client did not complete an RPC handshake or generate output; it hung until stopped with SIGTERM (exit 143). This confirms that a TCP connection alone cannot validate an RPC worker. The PrivateLM app's successful Add action was treated as a TCP check only.
- `bash desktop-worker/tests/test-start-worker.sh` passed. The test uses a stub server and covers safe default bind, LAN opt-in, wildcard/public/link-local/CGNAT/invalid addresses, ports, thread counts, and device-name validation.
- `bash desktop-worker/scripts/build-worker.sh --source ../llama.cpp-b11157 --build-dir ../build-worker-cpu` passed. It built the pinned CPU RPC server target. The initial run failed because this upstream revision creates the RPC server target only when `LLAMA_BUILD_TOOLS=ON`; the script now enables tools while still building only `ggml-rpc-server`.
- Full Flutter tests: 30 passed; 9 unrelated `openai_server_service_test.dart` cases failed because the pre-existing local service occupied port 18765 (`EADDRINUSE`). The other 7 test files passed (30 tests).
- `flutter analyze` exited 1 on two pre-existing diagnostics: an unawaited Future at `lib/services/download_native.dart:152` and deprecated `axisAlignment` at `lib/widgets/thought_disclosure.dart:170`.
- `flutter build apk --debug --no-pub` did not reach app compilation: Gradle 8.14.3 could not start under the installed Java 27 toolchain; Gradle distribution access also failed TLS in the wrapper. The desktop-worker change does not alter Flutter or Android source.
- Windows PowerShell and macOS worker paths are provided but were not run on those operating systems. The workflow in `.github/workflows/desktop-worker.yml` builds Linux CPU, macOS Metal, and Windows CPU variants on GitHub Actions. Those hosted results are pending.

## Limits

The llama.cpp RPC server is an experimental unauthenticated service. The task test used a trusted private Wi-Fi network and a temporary firewall rule from the phone only. The server stopped after the test and the temporary UFW rule was removed. No public bind, permanent service, failover behavior, controlled phone benchmark, or cross-platform runtime claim was tested.
