#ifndef FLUTTER_PLUGIN_LLAMA_FLUTTER_ANDROID_PLUGIN_H_
#define FLUTTER_PLUGIN_LLAMA_FLUTTER_ANDROID_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace llama_flutter_android {

class LlamaFlutterAndroidPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  LlamaFlutterAndroidPlugin();
  virtual ~LlamaFlutterAndroidPlugin();

  LlamaFlutterAndroidPlugin(const LlamaFlutterAndroidPlugin&) = delete;
  LlamaFlutterAndroidPlugin& operator=(const LlamaFlutterAndroidPlugin&) =
      delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace llama_flutter_android

#endif  // FLUTTER_PLUGIN_LLAMA_FLUTTER_ANDROID_PLUGIN_H_
