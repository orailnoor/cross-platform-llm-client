package com.write4me.llama_flutter_android

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Method channel for [LlamaExtNative] plus the server keep-awake switch.
 * Kept apart from the Pigeon-generated LlamaHostApi.
 */
class LlamaExtChannel(
    private val context: Context,
    messenger: BinaryMessenger,
    private val scope: CoroutineScope,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "llama_flutter_android/ext")

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    /** Runs [block] off the main thread and reports its value or error. */
    private fun io(result: MethodChannel.Result, block: () -> Any?) {
        scope.launch(Dispatchers.IO) {
            val outcome = runCatching(block)
            withContext(Dispatchers.Main) {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("EXT_FAILED", it.message ?: it.toString(), null) },
                )
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val n = LlamaExtNative
        when (call.method) {
            "setGrammar" -> {
                n.nativeSetGrammar(call.argument<String>("grammar") ?: "")
                result.success(null)
            }
            "jsonSchemaToGrammar" -> io(result) {
                n.nativeJsonSchemaToGrammar(call.argument<String>("schema") ?: "{}")
            }
            "lastStats" -> result.success(n.nativeLastStats())
            "tokenize" -> io(result) {
                n.nativeTokenize(
                    call.argument<String>("text") ?: "",
                    call.argument<Boolean>("addSpecial") ?: true,
                    call.argument<Boolean>("parseSpecial") ?: true,
                ).toList()
            }
            "detokenize" -> io(result) {
                val tokens = call.argument<List<Number>>("tokens") ?: emptyList()
                n.nativeDetokenize(tokens.map { it.toInt() }.toIntArray(),
                    call.argument<Boolean>("special") ?: false)
            }
            "embed" -> io(result) {
                n.nativeEmbed(call.argument<String>("text") ?: "",
                    call.argument<Boolean>("normalize") ?: true).map { it.toDouble() }
            }
            "hasVision" -> result.success(n.nativeHasVision())
            "loadMmproj" -> io(result) {
                n.nativeLoadMmproj(call.argument<String>("path") ?: "",
                    (call.argument<Number>("threads") ?: 4).toLong())
            }
            "setLoadMtp" -> {
                n.nativeSetLoadMtp(call.argument<Boolean>("loadLayers") ?: false,
                    call.argument<Int>("nDraft") ?: 3)
                result.success(null)
            }
            "loadMtp" -> io(result) {
                n.nativeLoadMtp(call.argument<String>("path") ?: "",
                    call.argument<Int>("nDraft") ?: 3,
                    (call.argument<Number>("pMin") ?: 0.0).toFloat())
            }
            "freeMtp" -> io(result) { n.nativeFreeMtp(); null }
            "setMtp" -> {
                n.nativeSetMtp(call.argument<Boolean>("enabled") ?: true, call.argument<Int>("nDraft") ?: 0)
                result.success(null)
            }
            "mtpInfo" -> result.success(n.nativeMtpInfo())
            "modelInfo" -> result.success(n.nativeModelInfo())
            "chatPrepare" -> io(result) { n.nativeChatPrepare(call.argument<String>("request") ?: "{}") }
            "chatParse" -> io(result) {
                n.nativeChatParse(call.argument<String>("text") ?: "", call.argument<Boolean>("partial") ?: false)
            }
            "setStartOnBoot" -> {
                // Read by the app's BootReceiver (no Flutter engine at boot).
                context.getSharedPreferences("privatelm_autostart", Context.MODE_PRIVATE)
                    .edit().putBoolean("start_on_boot", call.argument<Boolean>("enabled") == true).apply()
                result.success(null)
            }
            "keepAwake" -> {
                // Foreground service + PARTIAL_WAKE_LOCK + high-perf Wi-Fi lock
                // while the API server runs (screen off, app in background).
                val on = call.argument<Boolean>("on") == true
                val intent = Intent(context, InferenceService::class.java)
                    .setAction(if (on) InferenceService.ACTION_KEEP_AWAKE_ON else InferenceService.ACTION_KEEP_AWAKE_OFF)
                    .putExtra(InferenceService.EXTRA_TITLE, call.argument<String>("title"))
                    .putExtra(InferenceService.EXTRA_TEXT, call.argument<String>("text"))
                try {
                    if (on) ContextCompat.startForegroundService(context, intent)
                    else if (InferenceService.isRunning) context.startService(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("KEEP_AWAKE_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
