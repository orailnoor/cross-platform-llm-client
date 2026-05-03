package com.example.sd_flutter_android

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*

class SdFlutterAndroidPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel
  private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

  // Callback object passed to JNI; JNI calls onProgress(step, total) from worker threads
  inner class ProgressCallback {
    fun onProgress(step: Int, total: Int) {
      // Marshal back to main thread for MethodChannel
      CoroutineScope(Dispatchers.Main).launch {
        channel.invokeMethod("onProgress", mapOf("step" to step, "total" to total))
      }
    }
  }

  // Native methods (linked to sd_jni_wrapper.cpp)
  private external fun initModel(path: String): Boolean
  private external fun generateImage(prompt: String, steps: Int, callback: ProgressCallback): ByteArray?
  private external fun unloadModel()

  init {
    System.loadLibrary("sd_jni")
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
          scope.launch {
            try {
              val success = initModel(path)
              withContext(Dispatchers.Main) { result.success(success) }
            } catch (e: Exception) {
              withContext(Dispatchers.Main) { result.error("INIT_FAILED", e.message, null) }
            }
          }
        } else {
          result.error("INVALID_ARGUMENT", "Path is null", null)
        }
      }
      "generateImage" -> {
        val prompt = call.argument<String>("prompt")
        val steps = call.argument<Int>("steps") ?: 20
        if (prompt != null) {
          scope.launch {
            try {
              val callback = ProgressCallback()
              val bytes = generateImage(prompt, steps, callback)
              withContext(Dispatchers.Main) {
                if (bytes != null) {
                  result.success(bytes)
                } else {
                  result.error("GENERATION_FAILED", "Image generation returned null", null)
                }
              }
            } catch (e: Exception) {
              withContext(Dispatchers.Main) {
                result.error("GENERATION_FAILED", e.message, null)
              }
            }
          }
        } else {
          result.error("INVALID_ARGUMENT", "Prompt is null", null)
        }
      }
      "unloadModel" -> {
        scope.launch {
          try {
            unloadModel()
            withContext(Dispatchers.Main) { result.success(null) }
          } catch (e: Exception) {
            withContext(Dispatchers.Main) { result.error("UNLOAD_FAILED", e.message, null) }
          }
        }
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    scope.cancel()
  }
}
