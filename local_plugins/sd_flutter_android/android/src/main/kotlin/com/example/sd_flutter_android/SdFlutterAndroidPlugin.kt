package com.example.sd_flutter_android

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class SdFlutterAndroidPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "sd_flutter_android")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "initModel" -> {
        val path = call.argument<String>("path")
        if (path != null) {
          result.error(
            "ENGINE_NOT_BUNDLED",
            "The stable-diffusion.cpp native engine is not bundled in this checkout.",
            null
          )
        } else {
          result.error("INVALID_ARGUMENT", "Path is null", null)
        }
      }
      "generateImage" -> {
        val prompt = call.argument<String>("prompt")
        val steps = call.argument<Int>("steps") ?: 20
        if (prompt != null) {
          result.error(
            "ENGINE_NOT_BUNDLED",
            "The stable-diffusion.cpp native engine is not bundled in this checkout.",
            null
          )
        } else {
          result.error("INVALID_ARGUMENT", "Prompt is null", null)
        }
      }
      "unloadModel" -> {
        result.success(null)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
