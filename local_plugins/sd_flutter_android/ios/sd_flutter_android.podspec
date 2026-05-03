Pod::Spec.new do |s|
  s.name             = 'sd_flutter_android'
  s.version          = '0.0.1'
  s.summary          = 'Run Stable Diffusion models locally on iOS/Android'
  s.description      = 'A Flutter plugin to run Stable Diffusion models locally using stable-diffusion.cpp'
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.0'
  s.dependency 'Flutter'

  s.prepare_command = <<-'CMD'
    set -e
    SD_SRC="$(pwd)/../android/src/main/cpp/stable-diffusion.cpp"
    DST="$(pwd)/sd_cpp_src"
    rm -rf "$DST"
    mkdir -p "$DST"
    cp -r "$SD_SRC/src" "$DST/src"
    cp -r "$SD_SRC/include" "$DST/include"
    cp -r "$SD_SRC/ggml" "$DST/ggml"
    mkdir -p "$DST/thirdparty"
    cp "$SD_SRC/thirdparty/zip.c" "$DST/thirdparty/"
    cp "$SD_SRC/thirdparty/zip.h" "$DST/thirdparty/"
    cp "$SD_SRC/thirdparty/miniz.h" "$DST/thirdparty/"
    cp "$SD_SRC/thirdparty/darts.h" "$DST/thirdparty/" 2>/dev/null || true
    cp "$SD_SRC/thirdparty/json.hpp" "$DST/thirdparty/" 2>/dev/null || true
    cp "$SD_SRC/thirdparty/httplib.h" "$DST/thirdparty/" 2>/dev/null || true
    cp "$SD_SRC/thirdparty/stb_image.h" "$DST/thirdparty/" 2>/dev/null || true
    cp "$SD_SRC/thirdparty/stb_image_resize.h" "$DST/thirdparty/" 2>/dev/null || true
    cp "$SD_SRC/thirdparty/stb_image_write.h" "$DST/thirdparty/" 2>/dev/null || true

    echo '#define GGML_VERSION "0.9.8"' | cat - "$DST/ggml/src/ggml.c" > temp && mv temp "$DST/ggml/src/ggml.c"
    echo '#define GGML_COMMIT "404fcb9d"' | cat - "$DST/ggml/src/ggml.c" > temp && mv temp "$DST/ggml/src/ggml.c"

    METAL_DIR="$DST/ggml/src/ggml-metal"
    COMMON_H="$DST/ggml/src/ggml-common.h"
    IMPL_H="$METAL_DIR/ggml-metal-impl.h"
    METAL_SRC="$METAL_DIR/ggml-metal.metal"
    METAL_OUT="$METAL_DIR/ggml-metal-ios.metal"

    if [ -f "$METAL_SRC" ]; then
      sed -e "/__embed_ggml-common.h__/r $COMMON_H" \
          -e "/__embed_ggml-common.h__/d" \
          < "$METAL_SRC" > "${METAL_OUT}.tmp"

      sed -e "/#include \"ggml-metal-impl.h\"/r $IMPL_H" \
          -e "/#include \"ggml-metal-impl.h\"/d" \
          < "${METAL_OUT}.tmp" > "$METAL_OUT"

      rm -f "${METAL_OUT}.tmp"
    fi
  CMD

  sd_root = '$(PODS_TARGET_SRCROOT)/sd_cpp_src'

  s.source_files = [
    'Classes/**/*.{swift,h,m,mm}',
    'sd_cpp_src/src/**/*.{c,cpp,h,hpp}',
    'sd_cpp_src/include/**/*.h',
    'sd_cpp_src/ggml/src/*.{c,cpp}',
    'sd_cpp_src/ggml/src/ggml-cpu/*.{c,cpp}',
    'sd_cpp_src/ggml/src/ggml-cpu/llamafile/*.cpp',
    'sd_cpp_src/ggml/src/ggml-cpu/arch/arm/*.{c,cpp}',
    'sd_cpp_src/ggml/src/ggml-metal/*.{c,cpp,m}',
    'sd_cpp_src/ggml/src/ggml-metal/ggml-metal-ios.metal',
    'sd_cpp_src/thirdparty/zip.c',
  ]

  s.exclude_files = [
    'sd_cpp_src/ggml/src/ggml-cpu/amx/**/*',
  ]

  s.requires_arc = ['Classes/**/*.{swift,m,mm,h}']

  s.frameworks = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation'
  s.libraries  = 'c++'

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS'  => '$(inherited) GGML_USE_METAL=1 GGML_USE_CPU=1 NDEBUG=1 GGML_MAX_NAME=128',
    'OTHER_CPLUSPLUSFLAGS'          => '$(inherited) -std=c++17 -O3 -DNDEBUG -DGGML_USE_METAL=1 -DGGML_USE_CPU=1',
    'OTHER_CFLAGS'                  => '$(inherited) -O3 -DNDEBUG -DGGML_USE_METAL=1 -DGGML_USE_CPU=1',
    'CLANG_CXX_LANGUAGE_STANDARD'  => 'c++17',
    'HEADER_SEARCH_PATHS'           => [
      "#{sd_root}/include",
      "#{sd_root}/ggml/include",
      "#{sd_root}/src",
      "#{sd_root}/ggml/src",
      "#{sd_root}/ggml/src/ggml-cpu",
      "#{sd_root}/ggml/src/ggml-metal",
      "#{sd_root}/thirdparty",
    ].join(' '),
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'MTL_COMPILER_FLAGS' => '$(inherited) -DGGML_METAL_EMBED_LIBRARY=1'
  }
end
