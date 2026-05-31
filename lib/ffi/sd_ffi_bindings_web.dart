/// Web stub for sd_ffi_bindings.dart.
/// Contains only the enums and extensions needed by UI code.
/// No dart:ffi imports — safe for web compilation.

enum QuantizationType {
  f32,
  f16,
  q4_0,
  q4_1,
  q5_0,
  q5_1,
  q8_0,
  q8_1,
  q2_k,
  q3_k,
  q4_k,
  q5_k,
  q6_k,
  q8_k,
}

extension QuantizationTypeExtension on QuantizationType {
  String get displayName {
    switch (this) {
      case QuantizationType.f32:
        return 'FP32';
      case QuantizationType.f16:
        return 'FP16';
      case QuantizationType.q4_0:
        return 'Q4_0 (fastest)';
      case QuantizationType.q4_1:
        return 'Q4_1';
      case QuantizationType.q5_0:
        return 'Q5_0';
      case QuantizationType.q5_1:
        return 'Q5_1';
      case QuantizationType.q8_0:
        return 'Q8_0 (balanced)';
      case QuantizationType.q8_1:
        return 'Q8_1';
      case QuantizationType.q2_k:
        return 'Q2_K (smallest)';
      case QuantizationType.q3_k:
        return 'Q3_K';
      case QuantizationType.q4_k:
        return 'Q4_K (recommended)';
      case QuantizationType.q5_k:
        return 'Q5_K';
      case QuantizationType.q6_k:
        return 'Q6_K (near-lossless)';
      case QuantizationType.q8_k:
        return 'Q8_K';
    }
  }

  int get nativeValue => 0;
}

enum Backend {
  cpu,
  vulkan,
  opencl,
}

extension BackendExtension on Backend {
  String get displayName {
    switch (this) {
      case Backend.cpu:
        return 'CPU';
      case Backend.vulkan:
        return 'Vulkan (GPU)';
      case Backend.opencl:
        return 'OpenCL (GPU)';
    }
  }

  String get libraryName => '';

  bool get isAvailable => this == Backend.cpu;
}

enum SampleMethod {
  euler,
  eulerA,
  heun,
  dpm2,
  dpmpp2sA,
  dpmpp2m,
  dpmpp2mv2,
  ipndm,
  ipndmV,
  lcm,
  ddimTrailing,
  tcd,
  resMultistep,
  res2s,
  erSde,
}

enum Schedule {
  discrete,
  karras,
  exponential,
  ays,
  gits,
  sgmUniform,
  simple,
  smoothstep,
  klOptimal,
  lcm,
  bongTangent,
}

class SdFfiBindings {
  static void initialize([Backend backend = Backend.cpu]) {}
  static void setupCallbacks(dynamic sendPort) {}
  static void clearCallbacks() {}
}
