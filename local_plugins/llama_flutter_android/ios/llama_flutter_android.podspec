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

  # llama.cpp (CPU, Metal, RPC) prebuilt from the same tree as the Android
  # build by ../scripts/build_llama_ios.sh, so both platforms run the same
  # engine and can join one phone cluster. Device (arm64) only.
  s.source_files = 'Classes/**/*.{swift,h,m,mm}'
  s.vendored_libraries = 'llama_ios/lib/libllama_ios.a'
  s.preserve_paths = 'llama_ios/**/*'

  s.frameworks = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation'
  s.libraries  = 'c++'

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS'  => '$(inherited) NDEBUG=1',
    'OTHER_CPLUSPLUSFLAGS'          => '$(inherited) -std=c++17 -O3 -DNDEBUG',
    'CLANG_CXX_LANGUAGE_STANDARD'  => 'c++17',
    'HEADER_SEARCH_PATHS'           => '"$(PODS_TARGET_SRCROOT)/llama_ios/include"',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64 i386',
  }
end
