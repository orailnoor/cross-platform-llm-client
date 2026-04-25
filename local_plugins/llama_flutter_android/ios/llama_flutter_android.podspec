Pod::Spec.new do |s|
  s.name             = 'llama_flutter_android'
  s.version          = '0.1.2'
  s.summary          = 'Run GGUF models on iOS/Android with llama.cpp'
  s.description      = 'A Flutter plugin to run GGUF quantized LLM models locally using llama.cpp, with Metal GPU acceleration on iOS.'
  s.homepage         = 'https://github.com/dragneel2074/Llama-Flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'dragneel2074' => '' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.0'
  s.dependency 'Flutter'
  s.requires_arc = ['Classes/**/*.{swift,m,mm,h}']

  # Copy llama.cpp sources and preprocess the Metal shader.
  # The .metal file uses #include "ggml-common.h" (one dir up) and
  # #include "ggml-metal-impl.h" which Xcode's Metal compiler cannot
  # find via HEADER_SEARCH_PATHS. We inline both headers into a single
  # self-contained .metal file at prepare time.
  s.prepare_command = <<-'CMD'
    set -e
    LLAMA_SRC="$(pwd)/../android/src/main/cpp/llama.cpp"
    DST="$(pwd)/llama_cpp_src"
    rm -rf "$DST"
    mkdir -p "$DST"
    cp -r "$LLAMA_SRC/include"  "$DST/include"
    cp -r "$LLAMA_SRC/src"      "$DST/src"
    cp -r "$LLAMA_SRC/ggml"     "$DST/ggml"

    # Preprocess ggml-metal.metal: inline ggml-common.h and ggml-metal-impl.h
    # so Xcode Metal compiler can build it without external header search paths.
    METAL_DIR="$DST/ggml/src/ggml-metal"
    COMMON_H="$DST/ggml/src/ggml-common.h"
    IMPL_H="$METAL_DIR/ggml-metal-impl.h"
    METAL_SRC="$METAL_DIR/ggml-metal.metal"
    METAL_OUT="$METAL_DIR/ggml-metal-ios.metal"

    # Step 1: replace __embed_ggml-common.h__ with the file contents
    sed -e "/__embed_ggml-common.h__/r $COMMON_H" \
        -e "/__embed_ggml-common.h__/d" \
        < "$METAL_SRC" > "${METAL_OUT}.tmp"

    # Step 2: inline ggml-metal-impl.h
    sed -e "/#include \"ggml-metal-impl.h\"/r $IMPL_H" \
        -e "/#include \"ggml-metal-impl.h\"/d" \
        < "${METAL_OUT}.tmp" > "$METAL_OUT"

    rm -f "${METAL_OUT}.tmp"

    # Define missing version macros in ggml.c
    echo '#define GGML_VERSION "unknown"' | cat - "$DST/ggml/src/ggml.c" > temp && mv temp "$DST/ggml/src/ggml.c"
    echo '#define GGML_COMMIT "unknown"' | cat - "$DST/ggml/src/ggml.c" > temp && mv temp "$DST/ggml/src/ggml.c"
  CMD

  llama_root = '$(PODS_TARGET_SRCROOT)/llama_cpp_src'

  s.source_files = [
    'Classes/**/*.{swift,h,m,mm}',
    'llama_cpp_src/src/**/*.cpp',
    'llama_cpp_src/ggml/src/*.{c,cpp}',
    'llama_cpp_src/ggml/src/ggml-cpu/*.{c,cpp}',
    'llama_cpp_src/ggml/src/ggml-cpu/llamafile/*.cpp',
    'llama_cpp_src/ggml/src/ggml-cpu/arch/arm/*.{c,cpp}',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal.cpp',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-common.cpp',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-device.cpp',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-ops.cpp',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-context.m',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-device.m',
    'llama_cpp_src/ggml/src/ggml-metal/ggml-metal-ios.metal',
  ]

  s.frameworks = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation'
  s.libraries  = 'c++'

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS'  => '$(inherited) GGML_USE_METAL=1 GGML_USE_CPU=1 NDEBUG=1',
    'OTHER_CPLUSPLUSFLAGS'          => '$(inherited) -std=c++17 -O3 -DNDEBUG -DGGML_USE_METAL=1 -DGGML_USE_CPU=1',
    'OTHER_CFLAGS'                  => '$(inherited) -O3 -DNDEBUG -DGGML_USE_METAL=1 -DGGML_USE_CPU=1',
    'CLANG_CXX_LANGUAGE_STANDARD'  => 'c++17',
    'HEADER_SEARCH_PATHS'           => [
      "#{llama_root}/include",
      "#{llama_root}/ggml/include",
      "#{llama_root}/src",
      "#{llama_root}/ggml/src",
      "#{llama_root}/ggml/src/ggml-cpu",
      "#{llama_root}/ggml/src/ggml-metal",
    ].join(' '),
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'MTL_COMPILER_FLAGS' => '$(inherited) -DGGML_METAL_EMBED_LIBRARY=1'
  }
end
