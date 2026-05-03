package com.aichat.ai_chat

import android.app.AlertDialog
import android.app.AlarmManager
import android.app.DownloadManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread
import kotlin.system.exitProcess
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val importChannelName = "com.aichat.ai_chat/model_import"
    private val tunnelChannelName = "com.aichat.ai_chat/tunnel"
    private val importRequestCode = 4207
    private val mainHandler = Handler(Looper.getMainLooper())

    private var importChannel: MethodChannel? = null
    private var tunnelChannel: MethodChannel? = null
    private var pendingImportResult: MethodChannel.Result? = null
    private var pendingModelsDir: String? = null
    private var tunnelProcess: Process? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        importChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, importChannelName)
        importChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickAndImportModel" -> {
                    if (pendingImportResult != null) {
                        result.error("IMPORT_BUSY", "Another model import is already running.", null)
                        return@setMethodCallHandler
                    }
                    val modelsDir = call.argument<String>("modelsDir")
                    if (modelsDir.isNullOrBlank()) {
                        result.error("INVALID_DIR", "Models directory is missing.", null)
                        return@setMethodCallHandler
                    }
                    pendingModelsDir = modelsDir
                    pendingImportResult = result
                    openModelPicker()
                }
                "downloadToDownloads" -> {
                    val url = call.argument<String>("url")
                    val filename = call.argument<String>("filename")
                    if (url.isNullOrBlank() || filename.isNullOrBlank()) {
                        result.error("INVALID_DOWNLOAD", "Model URL or filename is missing.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val downloadId = enqueueDownloadToDownloads(url, filename)
                        result.success(mapOf("downloadId" to downloadId, "filename" to sanitizeFilename(filename)))
                    } catch (e: Exception) {
                        result.error("DOWNLOAD_FAILED", e.message ?: e.toString(), null)
                    }
                }
                "restartApp" -> {
                    restartApp()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        tunnelChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, tunnelChannelName)
        tunnelChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startTunnel" -> {
                    val provider = call.argument<String>("provider") ?: "cloudflare"
                    val port = call.argument<Int>("port") ?: 8080
                    val cloudflareToken = call.argument<String>("cloudflareToken") ?: ""
                    val cloudflarePublicUrl = call.argument<String>("cloudflarePublicUrl") ?: ""
                    val ngrokAuthToken = call.argument<String>("ngrokAuthToken") ?: ""
                    val ngrokDomain = call.argument<String>("ngrokDomain") ?: ""
                    startTunnelAsync(
                        provider = provider,
                        port = port,
                        cloudflareToken = cloudflareToken,
                        cloudflarePublicUrl = cloudflarePublicUrl,
                        ngrokAuthToken = ngrokAuthToken,
                        ngrokDomain = ngrokDomain,
                        result = result
                    )
                }
                "stopTunnel" -> {
                    stopTunnel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startTunnelAsync(
        provider: String,
        port: Int,
        cloudflareToken: String,
        cloudflarePublicUrl: String,
        ngrokAuthToken: String,
        ngrokDomain: String,
        result: MethodChannel.Result,
    ) {
        thread(name = "ai-chat-tunnel-start") {
            try {
                stopTunnel()
                val tunnelResult = if (provider == "ngrok") {
                    startNgrokTunnel(port, ngrokAuthToken, ngrokDomain)
                } else {
                    startCloudflareTunnel(port, cloudflareToken, cloudflarePublicUrl)
                }
                mainHandler.post {
                    result.success(
                        mapOf(
                            "success" to tunnelResult.success,
                            "publicUrl" to tunnelResult.publicUrl,
                            "error" to tunnelResult.error
                        )
                    )
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.success(
                        mapOf(
                            "success" to false,
                            "publicUrl" to null,
                            "error" to (e.message ?: e.toString())
                        )
                    )
                }
            }
        }
    }

    private fun startCloudflareTunnel(
        port: Int,
        token: String,
        configuredUrl: String,
    ): TunnelResult {
        val binary = resolveNativeBinary("libcloudflared.so")
            ?: return TunnelResult(false, null, "cloudflared binary is missing for this ABI.")
        val args = mutableListOf(
            binary.absolutePath,
            "tunnel",
            "--no-autoupdate",
            "--protocol",
            "http2",
        )
        val normalizedConfiguredUrl = normalizeHttpsUrl(configuredUrl)
        if (token.isNotBlank()) {
            args += listOf("run", "--token", token.trim())
        } else {
            args += listOf("--url", "http://localhost:$port")
        }
        val process = startTunnelProcess(args)
        tunnelProcess = process

        val deadline = System.currentTimeMillis() + 45000L
        var publicUrl = normalizedConfiguredUrl
        val reader = process.inputStream.bufferedReader()
        while (System.currentTimeMillis() < deadline) {
            if (processHasExited(process)) {
                return TunnelResult(false, null, "cloudflared exited before the tunnel was ready.")
            }
            val line = readLineWithTimeout(reader) ?: continue
            Log.d("AIChatTunnel", "cloudflared: $line")
            publicUrl = publicUrl ?: Regex("""https://[A-Za-z0-9.-]+\.trycloudflare\.com""")
                .find(line)
                ?.value
            if (line.contains("Registered tunnel connection") && publicUrl != null) {
                startLogReader(reader, "cloudflared")
                return TunnelResult(true, publicUrl, null)
            }
        }
        return TunnelResult(false, null, "Cloudflare tunnel did not become ready in time.")
    }

    private fun startNgrokTunnel(
        port: Int,
        authToken: String,
        domain: String,
    ): TunnelResult {
        if (authToken.isBlank()) {
            return TunnelResult(false, null, "ngrok auth token is required.")
        }
        val binary = resolveNativeBinary("libngrok.so")
            ?: return TunnelResult(false, null, "ngrok binary is missing for this ABI.")
        val configFile = writeNgrokConfig(authToken)
        val args = mutableListOf(
            binary.absolutePath,
            "http",
            port.toString(),
            "--config",
            configFile.absolutePath,
            "--log",
            "stdout",
            "--log-format",
            "json",
        )
        val requestedUrl = normalizeHttpsUrl(domain)
        if (requestedUrl != null) {
            args += listOf("--url", requestedUrl)
        }
        val process = startTunnelProcess(args)
        tunnelProcess = process
        startLogReader(process.inputStream.bufferedReader(), "ngrok")
        val deadline = System.currentTimeMillis() + 30000L
        while (System.currentTimeMillis() < deadline) {
            if (processHasExited(process)) {
                return TunnelResult(false, null, "ngrok exited before the tunnel was ready.")
            }
            queryNgrokPublicUrl()?.let { url ->
                if (requestedUrl == null || requestedUrl == url) {
                    return TunnelResult(true, url, null)
                }
            }
            Thread.sleep(500L)
        }
        return TunnelResult(false, null, "ngrok tunnel did not become ready in time.")
    }

    private fun startTunnelProcess(args: List<String>): Process {
        return ProcessBuilder(args).apply {
            directory(filesDir)
            environment()["HOME"] = filesDir.parentFile?.absolutePath ?: filesDir.absolutePath
            redirectErrorStream(true)
        }.start()
    }

    private fun resolveNativeBinary(name: String): File? {
        val nativeDir = applicationInfo.nativeLibraryDir ?: return null
        return File(nativeDir, name).takeIf { it.exists() }
    }

    private fun stopTunnel() {
        try {
            tunnelProcess?.destroy()
        } catch (_: Exception) {}
        tunnelProcess = null
    }

    private fun processHasExited(process: Process): Boolean {
        return try {
            process.exitValue()
            true
        } catch (_: IllegalThreadStateException) {
            false
        }
    }

    private fun readLineWithTimeout(reader: java.io.BufferedReader): String? {
        val started = System.currentTimeMillis()
        while (System.currentTimeMillis() - started < 500L) {
            if (reader.ready()) return reader.readLine()
            Thread.sleep(50L)
        }
        return null
    }

    private fun startLogReader(reader: java.io.BufferedReader, label: String) {
        thread(name = "ai-chat-$label-log", isDaemon = true) {
            try {
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.d("AIChatTunnel", "$label: ${line.orEmpty()}")
                }
            } catch (_: Exception) {}
        }
    }

    private fun writeNgrokConfig(authToken: String): File {
        val dir = File(filesDir, "ngrok")
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, "ngrok.yml")
        file.writeText(
            """
            version: 3
            agent:
              authtoken: ${authToken.trim()}
              dns_resolver_ips:
                - 1.1.1.1
                - 8.8.8.8
              update_check: false
              crl_noverify: true
            """.trimIndent()
        )
        return file
    }

    private fun queryNgrokPublicUrl(): String? {
        val connection = (URL("http://127.0.0.1:4040/api/tunnels").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 4000
            readTimeout = 4000
            doInput = true
            setRequestProperty("Accept", "application/json")
        }
        return try {
            if (connection.responseCode !in 200..299) return null
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val tunnels = JSONObject(body).optJSONArray("tunnels") ?: return null
            for (i in 0 until tunnels.length()) {
                val url = tunnels.optJSONObject(i)?.optString("public_url").orEmpty()
                if (url.startsWith("https://")) return url.trimEnd('/')
            }
            null
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun normalizeHttpsUrl(value: String): String? {
        val trimmed = value.trim().trimEnd('/').trimStart('.')
        if (trimmed.isBlank()) return null
        return if (trimmed.startsWith("https://") || trimmed.startsWith("http://")) trimmed else "https://$trimmed"
    }

    private data class TunnelResult(
        val success: Boolean,
        val publicUrl: String?,
        val error: String?,
    )

    private fun restartApp() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent == null) {
            finishAffinity()
            return
        }
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val pendingIntent = PendingIntent.getActivity(
            this,
            9208,
            launchIntent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.set(
            AlarmManager.RTC,
            System.currentTimeMillis() + 350L,
            pendingIntent
        )
        finishAffinity()
        exitProcess(0)
    }

    private fun enqueueDownloadToDownloads(url: String, filename: String): Long {
        val safeName = sanitizeFilename(filename)
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(safeName)
            setDescription("Downloading AI model")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeName)
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return manager.enqueue(request)
    }

    private fun openModelPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, importRequestCode)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != importRequestCode) return

        if (resultCode != RESULT_OK || data?.data == null) {
            finishImportSuccess(mapOf("cancelled" to true))
            return
        }

        val uri = data.data!!
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {
            // Some providers do not allow persistable grants; the one-shot grant is enough here.
        }

        val filename = displayNameFor(uri)
        val lower = filename.lowercase()
        if (!lower.endsWith(".gguf") && !lower.endsWith(".litertlm") && !lower.endsWith(".safetensors")) {
            finishImportError(
                "UNSUPPORTED_MODEL",
                "Only .gguf, .litertlm, and .safetensors files can be imported."
            )
            return
        }

        val size = sizeFor(uri)
        if (size <= 0L) {
            finishImportError("EMPTY_MODEL", "The selected file is empty or unreadable.")
            return
        }

        val modelsDir = pendingModelsDir
        if (modelsDir.isNullOrBlank()) {
            finishImportError("INVALID_DIR", "Models directory is missing.")
            return
        }

        val destination = File(modelsDir, sanitizeFilename(filename))
        if (destination.exists()) {
            AlertDialog.Builder(this)
                .setTitle("Model already imported")
                .setMessage("${destination.name} already exists in app storage. Replace it?")
                .setNegativeButton("Cancel") { _, _ ->
                    finishImportSuccess(mapOf("cancelled" to true))
                }
                .setPositiveButton("Replace") { _, _ ->
                    copyUriToModel(uri, destination, size, true)
                }
                .show()
        } else {
            copyUriToModel(uri, destination, size, false)
        }
    }

    private fun copyUriToModel(uri: Uri, destination: File, totalBytes: Long, replacing: Boolean) {
        emitProgress(destination.name, 0L, totalBytes, 0.0, "Copying to app storage...")
        thread(name = "model-import-${destination.name}") {
            val partFile = File(destination.parentFile, "${destination.name}.part")
            val startedAt = System.currentTimeMillis()
            var copied = 0L
            try {
                destination.parentFile?.mkdirs()
                if (partFile.exists()) partFile.delete()

                contentResolver.openInputStream(uri).use { input ->
                    if (input == null) {
                        throw IllegalStateException("Unable to open selected file.")
                    }
                    partFile.outputStream().use { output ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            copied += read
                            val elapsedSeconds =
                                (System.currentTimeMillis() - startedAt).coerceAtLeast(1) / 1000.0
                            emitProgress(
                                destination.name,
                                copied,
                                totalBytes,
                                copied / elapsedSeconds,
                                "Copying to app storage..."
                            )
                        }
                    }
                }

                if (replacing && destination.exists()) destination.delete()
                if (!partFile.renameTo(destination)) {
                    throw IllegalStateException("Unable to finalize imported model.")
                }
                emitProgress(destination.name, totalBytes, totalBytes, 0.0, "Import complete")
                finishImportSuccess(
                    mapOf(
                        "cancelled" to false,
                        "filename" to destination.name,
                        "bytes" to totalBytes,
                        "replaced" to replacing
                    )
                )
            } catch (e: Exception) {
                if (partFile.exists()) partFile.delete()
                finishImportError("IMPORT_FAILED", e.message ?: e.toString())
            }
        }
    }

    private fun emitProgress(
        filename: String,
        copiedBytes: Long,
        totalBytes: Long,
        bytesPerSecond: Double,
        status: String,
    ) {
        mainHandler.post {
            importChannel?.invokeMethod(
                "importProgress",
                mapOf(
                    "filename" to filename,
                    "copiedBytes" to copiedBytes,
                    "totalBytes" to totalBytes,
                    "bytesPerSecond" to bytesPerSecond,
                    "status" to status
                )
            )
        }
    }

    private fun finishImportSuccess(payload: Map<String, Any?>) {
        mainHandler.post {
            pendingImportResult?.success(payload)
            pendingImportResult = null
            pendingModelsDir = null
        }
    }

    private fun finishImportError(code: String, message: String) {
        mainHandler.post {
            pendingImportResult?.error(code, message, null)
            pendingImportResult = null
            pendingModelsDir = null
        }
    }

    private fun displayNameFor(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) {
                        val value = cursor.getString(index)
                        if (!value.isNullOrBlank()) return value
                    }
                }
            }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "model.gguf"
    }

    private fun sizeFor(uri: Uri): Long {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0) return cursor.getLong(index)
                }
            }
        return -1L
    }

    private fun sanitizeFilename(filename: String): String {
        return filename.replace(Regex("""[\\/:*?"<>|]"""), "_")
    }
}
