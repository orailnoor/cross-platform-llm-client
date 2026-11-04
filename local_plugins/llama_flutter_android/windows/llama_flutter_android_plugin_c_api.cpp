#include "include/llama_flutter_android/llama_flutter_android_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "llama_flutter_android_plugin.h"

void LlamaFlutterAndroidPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  llama_flutter_android::LlamaFlutterAndroidPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
