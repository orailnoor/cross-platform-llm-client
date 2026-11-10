# PrivateLM

[![Live Web App](https://img.shields.io/badge/Live_Demo-Try_Web_App-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://ai-chat-orailnoor.web.app/)

A production-ready, cross-platform AI chat client built with Flutter. It unifies local on-device LLM inference (Android) with cloud API access, giving users full control over how their models run.

![Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast](PrivateLM.png)
_Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast_

![Generated on pixel 6 with 20 step](IMG_2390.png)
_Generated on pixel 6 with 20 step_

---

## What It Does

- **Local Inference on Android** — Download and run GGUF models directly on your phone using GPU-accelerated inference (Vulkan). No internet required after download.
- **Cloud API Fallback** — Seamlessly switch to OpenAI, Anthropic, Google Gemini, or Kimi (Moonshot AI) when you need more power or are on unsupported platforms.
- **Multimodal Chat** — Send text and images in conversations. Vision support works with both local models (Qwen2-VL) and cloud providers.
- **Persistent Sessions** — All chats and settings are stored locally via Hive. Nothing leaves your device unless you explicitly choose cloud mode.
- **Background Services** — Firebase Cloud Messaging integration for push updates and background task handling.
- **Smart Auto-Configuration** — On first launch, the app detects your device's RAM and recommends optimal context size and token limits automatically.
- **Task Management (in development)** — A task view for structured, multi-step AI workflows is being built. It is not available in the app yet.

---

## Technical Architecture

### Stack

- **Framework:** Flutter 3.x (Dart >=3.3.0)
- **State Management:** GetX
- **Local Storage:** Hive
- **Networking:** Dio + `package:http`
- **Background Execution:** `flutter_background_service` + `flutter_local_notifications`
- **Push Notifications:** Firebase Core + Firebase Messaging

### Inference Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / ModelView / ServerView / SettingsView          │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · TaskController · ModelController         │
│   SettingsController · HomeController                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (OpenAI/Claude/ │  │ (model dl)  │ │
│  │                 │  │  Gemini/Kimi)   │  │             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ExecutionSvc │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (bg tasks)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Local Inference (Android)

The app uses `llama_flutter_android`, a custom Flutter plugin wrapping `llama.cpp` for ARM64 devices. At runtime it:

1. **Detects GPU capabilities** via Vulkan to determine offload layers.
2. **Selects thread count** based on device tier (ultra / high / mid / low).
3. **Loads the GGUF model** with progress streaming.
4. **Generates tokens** via `generateChat()` with native chat-template support (ChatML, Llama-3, Gemma, Phi).
5. **Falls back** to manual prompt construction if native templates fail.

Idle detection (5s) and hard timeouts (180s) keep the UX responsive even on underpowered hardware.

### Cloud Inference

`CloudService` normalizes four different API shapes into a single interface:

- **OpenAI** — standard `/v1/chat/completions`
- **Anthropic** — Messages API with separate system param
- **Google Gemini** — `generateContent` with inline image base64
- **Kimi** — OpenAI-compatible endpoint from Moonshot AI

API keys are stored in Hive and never transmitted anywhere except to the provider's endpoint.

### Cross-Platform Abstraction

Local inference is conditionally compiled:

- **Android** → `inference_android.dart` (full llama.cpp engine)
- **Web** → `inference_stub.dart` (cloud-only, local coming soon)
- **iOS** → `inference_android.dart` (full llama.cpp engine via Metal GPU)
- **Windows** → bundled llama.cpp GGUF text inference (CPU/Vulkan GPU),
  master/worker RPC clustering, and optional API providers.

The `InferenceService` exposes `supportsLocalInference` so the UI can hide local-model UI on unsupported platforms.

---

## Supported Platforms

| Platform | Local Inference | Cloud APIs | Notes                           |
| -------- | --------------- | ---------- | ------------------------------- |
| Android  | ✅ Yes          | ✅ Yes     | CPU offload via NEON; minSdk 28 |
| iOS      | ✅ Yes          | ✅ Yes     | Metal GPU acceleration          |
| Windows  | ✅ Yes          | ✅ Yes    | Bundled CPU/Vulkan GGUF engine; master and worker roles |
| Web      | ❌ No           | ✅ Yes     | Cloud-only (local coming soon)  |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/orailnoor/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `PrivateLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, PrivateLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

*Note: Sideloaded apps via AltStore expire after 7 days, but AltStore will attempt to automatically refresh them in the background when connected to the same Wi-Fi as your computer running AltServer.*

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0
- Android SDK (API 26+)
- JDK 17
- NDK (bundled with Android SDK)

### Android

```bash
flutter pub get
flutter build apk --debug
```

Release APKs require a stable signing key. Copy
`android/key.properties.example` to `android/key.properties`, fill in the
keystore values, and keep both the key and its backup. Android accepts an APK
upgrade only when it is signed with the same key as the installed APK.

```bash
cp android/key.properties.example android/key.properties
flutter build apk --release --split-per-abi
```

Never rotate the signing key between GitHub releases. The per-ABI APKs must
also keep increasing the build number in `pubspec.yaml`.

### iOS

```bash
flutter pub get
cd ios
pod install
flutter build ios
```

### Web

```bash
flutter pub get
flutter build web --release
```

### Windows

Install the stable Flutter SDK and Visual Studio 2022 (or Build Tools) with
the **Desktop development with C++** workload, MSVC, CMake, and a Windows SDK.
Visual Studio Code alone does not include the native compiler.
For GPU builds, install the Vulkan SDK (including `glslc` and the SPIRV-Headers
CMake development package) and set `VULKAN_SDK` to its root. The SDK is needed
only to build; users need an up-to-date Vulkan-capable GPU driver, not the SDK.
The GPU-enabled build requires the Vulkan runtime supplied by that driver,
including in CPU Safe mode. A CPU-only build can disable the CMake option
`PRIVATELM_WINDOWS_VULKAN` and does not require the Vulkan SDK/runtime.
Enable **Developer Mode** in Windows Settings so Flutter can create plugin
symlinks (`start ms-settings:developers` opens the relevant settings page).
Run these commands in PowerShell from the repository root:

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
flutter pub get
flutter run -d windows
```

New Windows installations start in local mode; existing API selections are
preserved. Open **Models > Import** to copy a GGUF text model into app storage,
or download one from **Browse**, then load it. The bundled
`privatelm-native.exe` runs the model directly: no Ollama, LM Studio, Python,
or separately installed model server is required. Model loading reports
progress, generation streams tokens, and Stop cancels native generation.
Chat history, settings, document attachments,
and image attachments use the same client as mobile. Images can be saved using
the Windows file dialog. Wide Windows windows use sidebar navigation; narrow
windows retain the bottom tabs.

**GPU acceleration:** Settings > Performance > GGUF acceleration > Auto fast
uses Vulkan GPU offload when available, including NVIDIA RTX. The engine
limits GPU layers using available VRAM, reserving room for context and working
buffers; remaining layers use CPU RAM. Reload after changing settings.
Auto fast retries on CPU if a GPU load fails; failures are recorded in app logs.
CPU safe disables GPU offload. With 6 GB VRAM, start with a 2B-4B Q4 GGUF and
2048 context tokens; 7B-8B models may need partial offload. Use AC power and
Windows' high-performance GPU preference for the app/native engine.

**Master/worker:** Open Settings > Device cluster on each device. Choose Worker
on the devices lending memory, and Master on the device you chat on. Only the
master needs the GGUF file. Add workers using Find nearby, their displayed
IP/port, or a pasted `privatelm://worker?...` pairing link. Phone masters can
also scan a Windows worker's QR code. Windows advertises/discovers the same
`_privatelm._tcp` rpc7 service used by Android/iOS; compatible mobile workers
can participate. Windows workers use a supported GPU when available, otherwise
CPU. **Settings > Performance > Use GPU memory for workers** switches between
GPU VRAM/GPU compute (on, the default) and system RAM/CPU compute (off).
The choice is saved separately from local GGUF acceleration. Set Device cluster
to Off before changing it, then choose Worker again. Unload the model on the
master first, then remove and re-add the worker using Find nearby or its pairing
link/QR code so the master gets its new capacity.
System RAM typically offers more capacity but slower inference; this does not
make RAM operate at GPU speed. GPU mode advertises free VRAM minus a 15% reserve
and 512 MB, not the GPU's total VRAM. The worker screen identifies the actual
memory backend; Process RAM is the worker's Windows working set, not VRAM usage,
and System RAM speed is a CPU memory benchmark.
Choose whether to share a model when loading it; inspect Device cluster for
the actual per-device weight buffers after loading.

Keep all devices on the same trusted private LAN (Wi-Fi or Ethernet) and
allow `privatelm-native.exe` through Windows Firewall **only on private
networks**. RPC is unauthenticated: never expose worker TCP port 50052 to the
internet or untrusted networks. Discovery uses UDP 5353; if multicast is
blocked, enter the IP manually. Workers prevent Windows sleep while running;
turn the role Off to stop and release memory. App-owned native processes
also exit when PrivateLM closes, including after an app crash.

An RTX PC is generally the best master. Prefer local GPU inference when the
model fits: distributing layers over a network mainly increases capacity,
not speed, and can be slower than one GPU.

Alternatively, start an OpenAI-compatible server and choose
**Models > Cloud > Custom API**:

| Server | Base URL | Model ID |
| ------ | -------- | -------- |
| LM Studio | `http://127.0.0.1:1234/v1` | The ID of your loaded model |
| Ollama | `http://127.0.0.1:11434/v1` | An installed model name |
| llama.cpp server | `http://127.0.0.1:8080/v1` | The server's model ID |

Include `/v1`, but not `/chat/completions`, in the base URL. Leave the API key
blank for servers without authentication; otherwise enter the server's key.
This optional server runs separately from the bundled GGUF engine.
LiteRT, local vision/audio inference, on-device image generation, model
hosting, camera capture, speech recognition, mobile background services,
and Firebase Crashlytics are not available in the Windows client. Use an
image file instead of the camera.

Build a distributable release:

```powershell
flutter build windows --release
```

Distribute the **entire** `build\windows\x64\runner\Release` directory, not just
`privatelm.exe`: the adjacent DLLs and `data` directory are required. The target
PC needs the Microsoft Visual C++ 2015-2022 x64 Redistributable. Include
`privatelm-native.exe` and its bundled license notices alongside the app.

Native integration tests require a small GGUF fixture and the built helper:

```powershell
$env:PRIVATELM_TEST_ENGINE = (Resolve-Path 'build\windows\x64\runner\Release\privatelm-native.exe').Path
$env:PRIVATELM_TEST_MODEL = 'C:\models\test-model.gguf'
flutter test test\windows_native_integration_test.dart
```

These tests exercise actual CPU generation, Vulkan offload (requires a
supported GPU), cancellation, errors, and a master/worker RPC load.

---

## License

MIT — see [LICENSE](./LICENSE) for details.
