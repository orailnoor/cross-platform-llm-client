package com.example.sd_flutter_android

import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class SdFlutterAndroidPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel

  companion object {
    init {
      System.loadLibrary("sd_jni")
    }
  }

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
          val success = initModel(path)
          result.success(success)
        } else {
          result.error("INVALID_ARGUMENT", "Path is null", null)
        }
      }
      "generateImage" -> {
        val prompt = call.argument<String>("prompt")
        val steps = call.argument<Int>("steps") ?: 20
        if (prompt != null) {
          // Run in background thread as it's heavy
          Thread {
            val bytes = generateImage(prompt, steps, object : ProgressCallback {
              override fun onProgress(step: Int, total: Int) {
                // Send progress back to Flutter
                Handler(Looper.getMainLooper()).post {
                    channel.invokeMethod("onProgress", mapOf("step" to step, "total" to total))
                }
              }
            })
            Handler(Looper.getMainLooper()).post {
                if (bytes != null) {
                    result.success(bytes)
                } else {
                    result.error("GENERATION_FAILED", "Native generation returned null", null)
                }
            }
          }.start()
        } else {
          result.error("INVALID_ARGUMENT", "Prompt is null", null)
        }
      }
      "unloadModel" -> {
        unloadModel()
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

  // Native methods
  private external fun initModel(path: String): Boolean
  private external fun generateImage(prompt: String, steps: Int, callback: ProgressCallback): ByteArray?
  private external fun unloadModel()

  interface ProgressCallback {
    fun onProgress(step: Int, total: Int)
  }
}
