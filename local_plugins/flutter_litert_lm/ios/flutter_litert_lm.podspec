#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_litert_lm.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_litert_lm'
  s.version          = '0.3.0'
  s.summary          = 'Flutter plugin for LiteRT-LM on-device LLM inference.'
  s.description      = <<-DESC
Run Large Language Models on-device with GPU acceleration via Google's LiteRT-LM.
Supports Gemma, Qwen, Phi, DeepSeek and more.
                       DESC
  s.homepage         = 'https://github.com/songhieu/flutter_litert_lm'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Song Hieu Tran' => 'songhieutran@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm,swift}'
  s.public_header_files = 'Classes/LiteLmNativeBridge.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # XCFrameworks built from LiteRT-LM sources via scripts/build_ios_frameworks.sh
  # See ios/Frameworks/README.md for build instructions.
  s.vendored_frameworks = [
    'Frameworks/LiteRTLM.xcframework',
    'Frameworks/GemmaModelConstraintProvider.xcframework',
  ]

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # LiteRT-LM xcframework only ships arm64 slices. Exclude x86_64 since
    # there is no Intel simulator slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Use -all_load so the linker includes every object file (including those
    # that self-register via static constructors, like the engine factory
    # entries). Without this, dead-code elimination drops engine registrations
    # and engine_create() fails with "NOT_FOUND: Engine type not found".
    'OTHER_LDFLAGS' => '-lc++ -framework AVFAudio -framework AudioToolbox -framework GemmaModelConstraintProvider -all_load',
  }

  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'OTHER_LDFLAGS' => '-framework AVFAudio -framework AudioToolbox',
  }

  s.swift_version = '5.0'
  s.frameworks = 'AVFAudio', 'AudioToolbox'
end
