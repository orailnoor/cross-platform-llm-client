/// Hardware backend for LiteRT-LM inference.
enum LiteLmBackend {
  /// CPU backend (default, available on all platforms).
  cpu,

  /// GPU backend (OpenCL-based, Android only).
  gpu,

  /// NPU backend (requires compatible hardware, Android only).
  npu,
}
