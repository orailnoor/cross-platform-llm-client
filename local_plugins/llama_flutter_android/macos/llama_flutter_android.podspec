Pod::Spec.new do |s|
  s.name             = 'llama_flutter_android'
  s.version          = '0.1.2'
  s.summary          = 'Device cluster worker for macOS with ggml/llama.cpp'
  s.description      = 'Serves this Mac\'s Metal GPU or CPU to a PrivateLM cluster master using ggml\'s RPC backend.'
  s.homepage         = 'https://github.com/dragneel2074/Llama-Flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'dragneel2074' => '' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '11.0'
  s.swift_version    = '5.0'
  s.dependency 'FlutterMacOS'
  s.requires_arc = true

  # The macOS worker needs only ggml: no llama model or vision library.
  # Build it with ../scripts/build_ggml_macos.sh before the first macOS build.
  # The cluster worker/channel live in ../apple/Classes because iOS uses the
  # same code with UIKit instead of AppKit.
  s.source_files = 'Classes/**/*.{swift,h,m,mm}', '../apple/Classes/**/*.{swift,h,m,mm}'
  s.vendored_libraries = 'llama/lib/libggml_macos.a'
  s.preserve_paths = 'llama/**/*'

  s.frameworks = 'Metal', 'MetalKit', 'MetalPerformanceShaders', 'Accelerate', 'Foundation'
  s.libraries  = 'c++'

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS'  => '$(inherited) NDEBUG=1',
    'OTHER_CPLUSPLUSFLAGS'          => '$(inherited) -std=c++17 -O3 -DNDEBUG',
    'CLANG_CXX_LANGUAGE_STANDARD'   => 'c++17',
    'HEADER_SEARCH_PATHS'           => '"$(PODS_TARGET_SRCROOT)/llama/include"',
  }
end
