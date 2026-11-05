# Desktop worker test results

Date: 2026-11-05. Repository source commit: `8a5f3b0c0ca8c2108b76ac9619fe5faf6a6a098e` (`orailnoor/cross-platform-llm-client`). Android's vendored llama.cpp RPC source reports protocol `7.0.0`; desktop worker source is upstream llama.cpp `b11157`, commit `53ed051ce5e8193652e449f43216ca3859454f49`.

## Hardware and model

- Laptop: ASUS TUF F15, Linux/Omarchy, NVIDIA RTX 4060 Laptop GPU with 8 GB VRAM, 16 GB system memory, CUDA toolkit 13.4.
- Phone: Samsung Galaxy S24 Ultra, Android, PrivateLM Cluster Master. ADB package readback confirmed version `1.0.7` (`versionCode=7`), installed/updated 2026-11-05 00:39 local time.
- Phone and laptop used the same Wi-Fi. The successful phone test initially used `192.168.0.5`, then `192.168.0.3` after the phone's address changed. UFW allowed only the phone address to reach laptop `192.168.0.10:50052` during those tests. The temporary rules were removed; the laptop currently has no RPC listener or RPC firewall exception.
- Desktop benchmark file: `LiquidAI/LFM2.5-1.2B-Instruct-GGUF`, Q4_K_M, 730,895,168 bytes, SHA-256 `b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5`. The phone app selected the LFM2.5 1.2B Instruct Q4_K_M catalog model, but its file hash was not read from the device. The model uses LFM Open License v1.0. No model file is part of this change.
- Prompt: `Write a 25-word story about a robot finding a garden. Use no introduction.`

## Phone and RPC result

The phone master connected to the worker and generated a sensible answer with LFM2.5. The user reported app rates of `8.2` and later `9.5 tk/s`, with an 83% phone / 17% laptop allocation. The worker log showed a connection from the phone, remote buffer allocations, and repeated RPC `graph_compute` requests during phone generation. The RTX 4060 showed approximately 573 MiB VRAM use during an observed phone RPC session. When the phone changed to `192.168.0.3`, UFW initially blocked it; one narrow allow rule fixed the connection and was removed after testing.

This proves that this phone and this desktop build exchanged compute requests and generated output. It does not establish that every PrivateLM release or every model is RPC-compatible. The app displayed tokens/s but did not expose time-to-first-token.

The first app-listed Qwen model was LiteRT and could not be shared with cluster workers. It was not used for the phone test. A separately downloaded Apache-2.0 Qwen GGUF was used for an earlier laptop-to-local-RPC smoke test only.

## Controlled desktop measurements

The local laptop used the exact same LFM2.5 GGUF and prompt for direct CUDA and loopback RPC runs. Each measured run used context 1024, maximum 40 predicted tokens, temperature 0, top-p 0.9, top-k 40, min-p 0.05, repeat penalty 1.1, repeat-last-n 64, seed 42, 8 CPU threads, and all model layers on CUDA/RPC. The local file was 730,895,168 bytes with SHA-256 `b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5`. The phone's app-private copy could not be read by ADB because the installed package is not debuggable; the same phone-file checksum remains unverified.

| Run | Direct CUDA generation |
|---|---:|
| 1 | 225.8 tokens/s |
| 2 | 251.2 tokens/s |
| 3 | 223.6 tokens/s |
| Mean | 233.5 tokens/s |

Three loopback RPC runs with the same prompt and settings generated at `233.0`, `228.7`, and `221.7 tokens/s` (mean `227.8 tokens/s`), 2.4% below direct CUDA. The client hid its local CUDA device, assigned model layers to `RPC0`, and emitted remote `graph_compute` operations. The remote GPU had 7,764 MiB free at worker startup; the client reported 763 MiB allocated for the model, context, and compute buffers on RPC0 (694 MiB model, 12 MiB context, 57 MiB compute). This is a loopback comparison, not a Wi-Fi or phone benchmark. Both paths produced the same coherent 23-word answer, shorter than the prompt's requested 25 words.

These llama.cpp CLI timings are not app timings. Prompt prefill rate was reported by the CLI, but time-to-first-token was not measured. The phone and CLI do not expose matching context, tokenization, or timing controls. In phone-only mode, the user reported `23.2` and later `22.5 tokens/s`, but said the output was gibberish; two more attempts failed with `failed to decode prompt`. Do not use those phone-only rates as quality-valid baselines. In hybrid mode, the user reported sensible output at `8.2` and later `9.5 tokens/s`. Those app-reported rates are not controlled phone benchmarks.

The user ran the phone-only prompt two more times, but both runs failed with PrivateLM's `failed to decode prompt` error. Treat the single hybrid rate as an app-reported observation, not a stable average.

## Phone-only failure diagnosis

- ADB confirmed PrivateLM `1.0.7`. The app-selected LFM2.5 GGUF resides in app-private storage. `run-as` is denied because the package is not debuggable, and no matching copy was found in shared Downloads. Its actual phone SHA-256 and byte size therefore remain unverified; the desktop copy's hash above is not proof of the phone copy.
- Source defaults are temperature `0.7`, max output `1024`, and context `2048`; Android GGUF generation sends top-p `0.9`, top-k `40`, min-p `0.05`, repeat penalty `1.1`, and repeat-last-n `64`. The app passes a null chat template to its template manager; filename detection falls back to ChatML for LFM2.5. The user's persisted settings were not readable through the installed app's private storage, so these defaults are not claimed to be the live settings.
- Source inspection shows standalone GGUF load may use the phone GPU, while adding cluster workers forces the phone's local GGUF portion to CPU. This makes the standalone GPU path a credible cause of the phone-only symptom, but no controlled CPU-safe phone run or matching live decode log was captured, so the cause is not confirmed. LFM2.5's ordinary text chat format is ChatML-compatible; the template fallback alone does not establish a template defect.
- At the latest read-only ADB sample, the S24 had 2.6 GiB `MemAvailable`; the laptop had 4.3 GiB available system RAM and 7,863 MiB free GPU memory. The app's manually added worker has no capacity metadata and the current planner fallback is 2,000 MiB and 4.0 GB/s. The previously observed 83%/17% split is consistent with that conservative fallback, but a larger-model placement test is still required to establish its effect.
- The requested Gemma 4 26B workload was not confirmed as fully downloaded or selected. No model larger than 1.2B was loaded on the phone/worker, and no result currently proves combined memory enabled a model that either device could not run alone.

## Commands and outcomes

- RPC source build: CMake configured llama.cpp `b11157` with `GGML_CUDA=ON`, `GGML_RPC=ON`; `cmake --build ... --target ggml-rpc-server --parallel 4` passed.
- Worker launcher invocation: `desktop-worker/scripts/start-worker.sh --server ../build-rpc-cuda/bin/ggml-rpc-server --host 127.0.0.1 --port 50053 --device CUDA0 --threads 4` started the pinned CUDA server. It reported RPC protocol `7.0.0` and RTX 4060 Laptop GPU with 7888 MiB.
- Laptop inference through local RPC, with local CUDA hidden from the client: `CUDA_VISIBLE_DEVICES='' GGML_RPC_DEBUG=1 llama-cli --model qwen2-0.5b-instruct-q4_k_m.gguf --prompt 'Write a 25-word story about a robot finding a garden. Use no introduction.' --n-predict 32 --ctx-size 1024 --gpu-layers 99 --threads 8 --threads-batch 8 --temp 0 --seed 42 --no-display-prompt --single-turn --rpc 192.168.0.10:50052 --verbose` passed. The client assigned all model layers to RPC0; the server logged RPC buffer allocations and graph compute. This verified RPC locally, not from the phone.
- A reachable HTTP server was also given to `llama-cli` as an RPC endpoint. The client did not complete an RPC handshake or generate output; it hung until stopped with SIGTERM (exit 143). This confirms that a TCP connection alone cannot validate an RPC worker. The PrivateLM app's successful Add action was treated as a TCP check only.
- `bash desktop-worker/tests/test-start-worker.sh` passed. The test uses a stub server and covers safe default bind, LAN opt-in, wildcard/public/link-local/CGNAT/invalid addresses, ports, thread counts, and device-name validation.
- `bash desktop-worker/scripts/build-worker.sh --source ../llama.cpp-b11157 --build-dir ../build-worker-cpu` passed. It built the pinned CPU RPC server target. The initial run failed because this upstream revision creates the RPC server target only when `LLAMA_BUILD_TOOLS=ON`; the script now enables tools while still building only `ggml-rpc-server`.
- GitHub Actions run `41998963409` passed on Ubuntu CPU, macOS Metal, and Windows CPU. Linux and macOS launcher tests passed. Windows built the server and passed the PowerShell launcher tests. An earlier Windows test run exposed a test-harness argument-binding error; the test now launches the worker script in a child PowerShell process.
- GitHub Actions run `42004133999` passed on the report-update commit `33929fd33d717b4fa296f2902250b5d6a87687a2`: Ubuntu CPU, macOS Metal, and Windows CPU builds and launcher checks all passed.
- Full Flutter tests: 30 passed; 9 unrelated `openai_server_service_test.dart` cases failed because the pre-existing local service occupied port 18765 (`EADDRINUSE`). The other 7 test files passed (30 tests).
- `flutter analyze` exited 1 on two pre-existing diagnostics: an unawaited Future at `lib/services/download_native.dart:152` and deprecated `axisAlignment` at `lib/widgets/thought_disclosure.dart:170`.
- `flutter build apk --debug --no-pub` did not reach app compilation: Gradle 8.14.3 could not start under the installed Java 27 toolchain; Gradle distribution access also failed TLS in the wrapper. The desktop-worker change does not alter Flutter or Android source.
- The GitHub Windows and macOS checks prove builds and launcher validation only. No Windows/macOS phone inference or runtime worker session was tested.

## Limits

The llama.cpp RPC server is an experimental unauthenticated service. The task test used a trusted private Wi-Fi network and a temporary firewall rule from the phone only. The server stopped after the test and the temporary UFW rule was removed. No public bind, permanent service, failover behavior, controlled phone benchmark, or cross-platform runtime claim was tested.
