# PrivateLM desktop RPC worker

This folder builds and starts the upstream llama.cpp RPC server at the commit used by PrivateLM's Android build. It does not change the phone app or its model planner.

The RPC server is experimental and has no authentication. Keep it on a trusted LAN. Do not expose port 50052 to the Internet. Permit connections only from the phone's IP address in the host firewall.

## Linux and macOS

Install Git, CMake, a C/C++ compiler, and Python 3. The `--cuda` option also needs the NVIDIA CUDA toolkit. The `--metal` option needs macOS and its Xcode command line tools.

From this repository, build the CPU worker or select a GPU backend:

```sh
bash desktop-worker/scripts/build-worker.sh
bash desktop-worker/scripts/build-worker.sh --cuda
bash desktop-worker/scripts/build-worker.sh --metal
```

The build script pins llama.cpp commit `53ed051ce5e8193652e449f43216ca3859454f49` (tag `b11157`). It stores source and build files in the user's cache directory. It does not install a service.

The default server bind is `127.0.0.1`. To serve a phone on a trusted LAN, pass the laptop's private IPv4 address and opt in:

```sh
bash desktop-worker/scripts/start-worker.sh --allow-lan --host 192.168.0.10 --port 50052 --device CUDA0
```

For CPU, omit `--device CUDA0`. Set a host firewall rule that allows TCP port 50052 only from the phone's current IP. Do not disable the firewall. Press Ctrl-C to stop the worker.

## Windows

Install Git, CMake, Visual Studio C++ Build Tools, and the NVIDIA CUDA toolkit for a CUDA build. Open PowerShell in this repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\desktop-worker\scripts\build-worker.ps1
powershell -ExecutionPolicy Bypass -File .\desktop-worker\scripts\build-worker.ps1 -Cuda
powershell -ExecutionPolicy Bypass -File .\desktop-worker\scripts\start-worker.ps1
```

To serve a phone on a trusted LAN, add `-AllowLan -HostAddress 192.168.0.10`. Add a Windows Defender Firewall inbound rule for TCP port 50052 with the phone's IP as the remote address. Press Ctrl-C to stop the worker.

## Verify phone inference

In PrivateLM, select Master and add the worker's private IP and port. A successful add only confirms that a TCP connection opened. It does not confirm RPC compatibility or inference.

Load a GGUF model that the app can share with workers. Generate a prompt. Confirm that the server logs show buffer allocation and `graph_compute` requests while the phone generates output. On a CUDA worker, also inspect GPU memory and utilization. Stop the worker after the check.

The current server protocol is unauthenticated. Do not use it on an untrusted network or with sensitive prompts. The launcher rejects wildcard and public IPv4 binds. It does not add firewall rules.

## Tests

Run launcher validation tests on Linux or macOS:

```sh
bash desktop-worker/tests/test-start-worker.sh
```

The test checks loopback defaults, explicit private-LAN opt-in, bad addresses, invalid ports, thread counts, and device names. It uses a local stub executable. It does not test RPC compatibility; use a real model and phone for that check.
