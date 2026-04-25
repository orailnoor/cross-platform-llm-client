#import <Flutter/Flutter.h>

/// Dummy no-op plugin stub for llama_flutter_android on iOS.
/// The actual plugin is Android-only; this stub satisfies the
/// GeneratedPluginRegistrant reference.
@interface LlamaFlutterAndroidPlugin : NSObject<FlutterPlugin>
@end

@implementation LlamaFlutterAndroidPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // No-op on iOS — local inference is only supported on Android.
}
@end
