package com.write4me.llama_flutter_android

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

class LlamaFlutterAndroidPlugin : FlutterPlugin, LlamaHostApi, ActivityAware {
    private lateinit var context: Context
    private lateinit var flutterApi: LlamaFlutterApi
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var generationJob: Job? = null
    private val isModelLoaded = AtomicBoolean(false)
    private val isStopping = AtomicBoolean(false)
    private var currentModelPath: String? = null
    private var nativeLoadError: Throwable? = null
    private var clusterChannel: ClusterChannel? = null

    companion object {
        private const val TAG = "LlamaFlutterPlugin"
        /** llama.cpp mtmd's default media marker (mtmd_default_marker()). */
        private const val MEDIA_MARKER = "<__media__>"
        /** Error prefix: text model loaded, but its vision file did not. */
        const val VISION_LOAD_FAILED = "VISION_LOAD_FAILED:"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.i(TAG, "Attaching llama Flutter plugin")
        context = binding.applicationContext
        flutterApi = LlamaFlutterApi(binding.binaryMessenger)
        LlamaHostApi.setUp(binding.binaryMessenger, this)
        clusterChannel = ClusterChannel(context, binding.binaryMessenger, scope)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        clusterChannel?.dispose()
        clusterChannel = null
        scope.cancel()
        if (isModelLoaded.get()) {
            nativeFreeModel()
        }
        LlamaHostApi.setUp(binding.binaryMessenger, null)
    }

    // The cluster channel needs the window (keep the screen on while sharing).
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        clusterChannel?.activity = binding.activity
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        clusterChannel?.activity = binding.activity
    }
    override fun onDetachedFromActivityForConfigChanges() {
        clusterChannel?.activity = null
    }
    override fun onDetachedFromActivity() {
        clusterChannel?.activity = null
    }

    override fun loadModel(config: ModelConfig, callback: (Result<Unit>) -> Unit) {
        ensureNativeLoaded()?.let {
            callback(Result.failure(it))
            return
        }

        scope.launch {
            try {
                // Start foreground service for long-running task
                val intent = Intent(context, InferenceService::class.java)
                ContextCompat.startForegroundService(context, intent)

                // Load model with progress callback
                nativeLoadModel(
                    config.modelPath,
                    config.nThreads,
                    config.contextSize,
                    config.nGpuLayers ?: 0L
                ) { progress ->
                    scope.launch {
                        withContext(Dispatchers.Main) {
                            flutterApi.onLoadProgress(progress) { result ->
                                // Handle result if needed
                            }
                        }
                    }
                }

                currentModelPath = config.modelPath
                isModelLoaded.set(true)

                // Vision projector for multimodal models. If it fails the text
                // model stays loaded; Dart sees VISION_LOAD_FAILED and carries
                // on text-only instead of reloading.
                val mmproj = config.mmprojPath
                val visionError = if (!mmproj.isNullOrBlank()) {
                    nativeLoadMmproj(mmproj, config.nThreads)
                } else null

                withContext(Dispatchers.Main) {
                    if (visionError != null) {
                        callback(Result.failure(
                            RuntimeException("$VISION_LOAD_FAILED $visionError")))
                    } else {
                        callback(Result.success(Unit))
                    }
                }
            } catch (e: Exception) {
                scope.launch {
                    withContext(Dispatchers.Main) {
                        flutterApi.onError(e.message ?: "Failed to load model") { result ->
                            // Handle result if needed
                        }
                        callback(Result.failure(e))
                    }
                }
            }
        }
    }

    override fun generate(request: GenerateRequest, callback: (Result<Unit>) -> Unit) {
        ensureNativeLoaded()?.let {
            callback(Result.failure(it))
            return
        }

        if (!isModelLoaded.get()) {
            callback(Result.failure(IllegalStateException("Model not loaded")))
            return
        }

        val previous = generationJob
        generationJob = scope.launch {
            // One generation at a time on the native context. A client that
            // hangs up mid-stream (API server) leaves the previous one still
            // stopping; starting another meanwhile crashed llama.cpp. Wait for
            // it to return, and only then accept tokens again, so its last
            // token or "done" can't leak into this reply.
            previous?.let { nativeStop(); it.join() }
            isStopping.set(false)
            try {
                nativeGenerate(
                    request.prompt,
                    null,
                    request.maxTokens,
                    request.temperature,
                    request.topP,
                    request.topK,
                    request.minP,
                    request.typicalP,
                    request.repeatPenalty,
                    request.frequencyPenalty,
                    request.presencePenalty,
                    request.repeatLastN,
                    request.mirostat,
                    request.mirostatTau,
                    request.mirostatEta,
                    request.seed ?: -1L,  // Use -1 for random seed
                    request.penalizeNewline
                ) { token ->
                    if (!isStopping.get()) {
                        scope.launch {
                            withContext(Dispatchers.Main) {
                                flutterApi.onToken(token) { result ->
                                    // Handle result if needed
                                }
                            }
                        }
                    }
                }

                if (!isStopping.get()) {
                    scope.launch {
                        withContext(Dispatchers.Main) {
                            flutterApi.onDone { result ->
                                // Handle result if needed
                            }
                        }
                    }
                }

                withContext(Dispatchers.Main) {
                    callback(Result.success(Unit))
                }
            } catch (e: Exception) {
                if (!isStopping.get()) {
                    scope.launch {
                        withContext(Dispatchers.Main) {
                            flutterApi.onError(e.message ?: "Generation failed") { result ->
                                // Handle result if needed
                            }
                            callback(Result.failure(e))
                        }
                    }
                }
            }
        }
    }

    override fun stop(callback: (Result<Unit>) -> Unit) {
        isStopping.set(true)
        generationJob?.cancel()
        if (nativeLoadError == null) {
            nativeStop()
        }
        callback(Result.success(Unit))
    }

    override fun dispose(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            try {
                stop { }
                if (isModelLoaded.get()) {
                    nativeFreeModel()
                    isModelLoaded.set(false)
                }
                
                // Stop foreground service
                val intent = Intent(context, InferenceService::class.java)
                context.stopService(intent)
                
                withContext(Dispatchers.Main) {
                    callback(Result.success(Unit))
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    callback(Result.failure(e))
                }
            }
        }
    }

    override fun generateChat(request: ChatRequest, callback: (Result<Unit>) -> Unit) {
        ensureNativeLoaded()?.let {
            callback(Result.failure(it))
            return
        }

        if (!isModelLoaded.get()) {
            callback(Result.failure(IllegalStateException("Model not loaded")))
            return
        }

        val previous = generationJob
        generationJob = scope.launch {
            // One generation at a time on the native context. A client that
            // hangs up mid-stream (API server) leaves the previous one still
            // stopping; starting another meanwhile crashed llama.cpp. Wait for
            // it to return, and only then accept tokens again, so its last
            // token or "done" can't leak into this reply.
            previous?.let { nativeStop(); it.join() }
            isStopping.set(false)
            try {
                // Only the newest image is sent (earlier ones stay as text).
                // Its message gets llama.cpp's media marker, which the native
                // side replaces with the encoded image.
                val imageIndex = request.messages.indexOfLast { !it.imagePath.isNullOrBlank() }
                val imagePath = if (imageIndex >= 0) request.messages[imageIndex].imagePath else null

                // Format the chat messages using the template manager
                val formattedPrompt = ChatTemplateManager.formatMessages(
                    request.messages.mapIndexed { i, msg ->
                        val content = if (i == imageIndex) "$MEDIA_MARKER\n${msg.content}" else msg.content
                        TemplateChatMessage(msg.role, content)
                    },
                    request.template,
                    currentModelPath
                )

                if (imagePath != null) {
                    android.util.Log.i(TAG, "Image turn: message $imageIndex of ${request.messages.size}, " +
                        "marker in prompt=${formattedPrompt.contains(MEDIA_MARKER)}")
                }
                nativeGenerate(
                    formattedPrompt,
                    imagePath,
                    request.maxTokens.toLong(),
                    request.temperature.toDouble(),
                    request.topP.toDouble(),
                    request.topK.toLong(),
                    request.minP.toDouble(),
                    request.typicalP.toDouble(),
                    request.repeatPenalty.toDouble(),
                    request.frequencyPenalty.toDouble(),
                    request.presencePenalty.toDouble(),
                    request.repeatLastN.toLong(),
                    request.mirostat.toLong(),
                    request.mirostatTau.toDouble(),
                    request.mirostatEta.toDouble(),
                    request.seed ?: -1L,  // Use -1 for random seed
                    request.penalizeNewline
                ) { token ->
                    if (!isStopping.get()) {
                        scope.launch {
                            withContext(Dispatchers.Main) {
                                flutterApi.onToken(token) { result ->
                                    // Handle result if needed
                                }
                            }
                        }
                    }
                }

                if (!isStopping.get()) {
                    scope.launch {
                        withContext(Dispatchers.Main) {
                            flutterApi.onDone { result ->
                                // Handle result if needed
                            }
                        }
                    }
                }

                withContext(Dispatchers.Main) {
                    callback(Result.success(Unit))
                }
            } catch (e: Exception) {
                if (!isStopping.get()) {
                    scope.launch {
                        withContext(Dispatchers.Main) {
                            flutterApi.onError(e.message ?: "Generation failed") { result ->
                                // Handle result if needed
                            }
                            callback(Result.failure(e))
                        }
                    }
                }
            }
        }
    }

    override fun getSupportedTemplates(): List<String> {
        return ChatTemplateManager.getSupportedTemplates()
    }

    override fun isModelLoaded(): Boolean {
        return isModelLoaded.get()
    }

    override fun getContextInfo(): ContextInfo {
        ensureNativeLoaded()?.let { throw it }

        val tokensUsed = nativeGetTokensUsed().toLong()
        val contextSize = nativeGetContextSize().toLong()
        val usagePercentage = if (contextSize > 0) {
            (tokensUsed.toDouble() / contextSize.toDouble() * 100.0)
        } else {
            0.0
        }
        
        return ContextInfo(
            tokensUsed = tokensUsed,
            contextSize = contextSize,
            usagePercentage = usagePercentage
        )
    }

    override fun clearContext(callback: (Result<Unit>) -> Unit) {
        ensureNativeLoaded()?.let {
            callback(Result.failure(it))
            return
        }

        scope.launch {
            try {
                nativeClearContext()
                withContext(Dispatchers.Main) {
                    callback(Result.success(Unit))
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    callback(Result.failure(e))
                }
            }
        }
    }

    override fun setSystemPromptLength(length: Long) {
        ensureNativeLoaded()?.let { throw it }
        nativeSetSystemPromptLength(length.toInt())
    }

    /**
     * Register a custom chat template
     * Allows users to provide their own template format at runtime
     */
    override fun registerCustomTemplate(name: String, content: String) {
        ChatTemplateManager.registerCustomTemplate(name, content)
    }

    /**
     * Unregister a custom chat template
     * Removes a previously registered custom template
     */
    override fun unregisterCustomTemplate(name: String) {
        ChatTemplateManager.unregisterCustomTemplate(name)
    }

    override fun detectGpu(callback: (Result<GpuInfo>) -> Unit) {
        ensureNativeLoaded()?.let {
            callback(Result.failure(it))
            return
        }

        scope.launch {
            try {
                // Loading the Vulkan backend initialises the driver, so skip it
                // entirely on devices where that step itself is risky.
                if (isGpuEligibleSoc()) {
                    nativeInitBackends(context.applicationInfo.nativeLibraryDir, true)
                } else {
                    Log.i(TAG, "GPU offload not enabled for SoC ${socDescription()}")
                }
                val outStats = LongArray(2) { -1L }
                val gpuName: String? = nativeDetectGpu(outStats)
                val vulkanSupported = gpuName != null
                val apiVersion = outStats[0]
                val deviceLocalMemory = outStats[1]

                val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memInfo = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(memInfo)
                val freeRamBytes = memInfo.availMem

                val recommendedGpuLayers = computeRecommendedLayers(
                    vulkanSupported = vulkanSupported,
                    gpuName = gpuName ?: "",
                    freeRamBytes = freeRamBytes,
                    deviceLocalMemoryBytes = deviceLocalMemory
                )

                withContext(Dispatchers.Main) {
                    callback(Result.success(GpuInfo(
                        vulkanSupported = vulkanSupported,
                        gpuName = gpuName ?: "None",
                        vulkanApiVersion = apiVersion,
                        deviceLocalMemoryBytes = deviceLocalMemory,
                        freeRamBytes = freeRamBytes,
                        recommendedGpuLayers = recommendedGpuLayers.toLong()
                    )))
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    callback(Result.success(GpuInfo(
                        vulkanSupported = false,
                        gpuName = "None",
                        vulkanApiVersion = -1L,
                        deviceLocalMemoryBytes = -1L,
                        freeRamBytes = -1L,
                        recommendedGpuLayers = 0L
                    )))
                }
            }
        }
    }

    private fun ensureNativeLoaded(): Throwable? {
        nativeLoadError?.let { return it }

        return try {
            System.loadLibrary("llama_jni")
            // Load the CPU backend now; the GPU backend is only loaded on
            // request by detectGpu() for eligible devices.
            nativeInitBackends(context.applicationInfo.nativeLibraryDir, false)
            null
        } catch (t: Throwable) {
            nativeLoadError = t
            Log.e(TAG, "Failed to load llama native library", t)
            IllegalStateException("Failed to load llama native library: ${t.message}", t)
        }
    }

    /**
     * Coarse pre-Vulkan check, using only SoC info (no GPU driver touched):
     * Android 12+ (older Vulkan drivers are the ones that crash on init) and
     * not a Unisoc budget SoC (PowerVR / old Mali). Individual GPUs are then
     * filtered by name in [computeRecommendedLayers].
     */
    private fun isGpuEligibleSoc(): Boolean {
        // Tester override: create this file in the app's private files dir
        // (needs adb run-as/root) to try the GPU on any device.
        if (isGpuForced()) {
            Log.w(TAG, "GPU eligibility overridden by force_gguf_gpu")
            return true
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val maker = Build.SOC_MANUFACTURER.lowercase()
        return !(maker.contains("unisoc") || maker.contains("spreadtrum"))
    }

    /** GPUs whose Vulkan drivers are known to break llama.cpp. */
    private fun isBlockedGpu(gpuName: String): Boolean {
        val name = gpuName.lowercase()
        if (name.contains("powervr") || name.contains("img ")) return true
        if (name.contains("mali-t")) return true  // Midgard (pre-2016)
        val adreno = Regex("adreno.*?(\\d{3})").find(name)
        if (adreno != null) return adreno.groupValues[1].toInt() < 640
        return false
    }

    private fun isGpuForced(): Boolean =
        java.io.File(context.filesDir, "force_gguf_gpu").exists()

    private fun socDescription(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        } else {
            "unknown (API ${Build.VERSION.SDK_INT})"
        }

    private fun computeRecommendedLayers(
        vulkanSupported: Boolean,
        gpuName: String,
        freeRamBytes: Long,
        deviceLocalMemoryBytes: Long
    ): Int {
        val GB = 1_073_741_824L
        val safeRam = (freeRamBytes * 0.7).toLong()
        // Phone GPUs share system RAM (UMA), so offloading needs no extra
        // memory and partial offload only adds CPU<->GPU traffic: all or none.
        return when {
            !vulkanSupported -> 0
            isBlockedGpu(gpuName) && !isGpuForced() -> 0
            safeRam < GB -> 0 // too little free RAM for GPU buffers + driver
            else -> 99
        }
    }

    // Native methods
    private external fun nativeLoadModel(
        path: String,
        nThreads: Long,
        contextSize: Long,
        nGpuLayers: Long,
        progressCallback: (Double) -> Unit
    )

    private external fun nativeGenerate(
        prompt: String,
        imagePath: String?,
        maxTokens: Long,
        temperature: Double,
        topP: Double,
        topK: Long,
        minP: Double,
        typicalP: Double,
        repeatPenalty: Double,
        frequencyPenalty: Double,
        presencePenalty: Double,
        repeatLastN: Long,
        mirostat: Long,
        mirostatTau: Double,
        mirostatEta: Double,
        seed: Long,
        penalizeNewline: Boolean,
        tokenCallback: (String) -> Unit
    )

    /** Returns null on success, otherwise why the vision file didn't load. */
    private external fun nativeLoadMmproj(path: String, nThreads: Long): String?
    private external fun nativeStop()
    private external fun nativeFreeModel()
    private external fun nativeGetTokensUsed(): Int
    private external fun nativeGetContextSize(): Int
    private external fun nativeClearContext()
    private external fun nativeSetSystemPromptLength(length: Int)
    private external fun nativeDetectGpu(outStats: LongArray): String?
    private external fun nativeInitBackends(libDir: String, allowGpu: Boolean): Boolean
    // outStats[0] = vulkanApiVersion, outStats[1] = deviceLocalMemoryBytes
}
