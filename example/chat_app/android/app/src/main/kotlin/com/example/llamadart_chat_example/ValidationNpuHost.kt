package com.example.llamadart_chat_example

import android.app.Activity
import android.os.Build
import android.system.Os
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Private validation entry point; normal app builds contain no NPU assets. */
class ValidationNpuHost(private val activity: Activity, engine: FlutterEngine) {
    private val executor = Executors.newSingleThreadExecutor()
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "llamadart_validation/npu")
    @Volatile private var cancelled = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancel") {
                cancelled = true
                result.success(null)
            } else if (call.method == "prepare") {
                cancelled = false
                executor.execute {
                    try {
                        val value = prepare(call.argument<String>("profile") ?: "")
                        activity.runOnUiThread { result.success(value) }
                    } catch (error: Exception) {
                        activity.runOnUiThread {
                            result.error("npu_preparation_failed", error.message, null)
                        }
                    }
                }
            } else result.notImplemented()
        }
    }

    fun close() {
        cancelled = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    private fun assetJson(name: String): JSONObject =
        activity.assets.open("llamadart_npu/$name").bufferedReader().use { JSONObject(it.readText()) }

    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                check(!cancelled) { "NPU preparation cancelled" }
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun prepare(profileId: String): Map<String, Any> {
        check(Build.VERSION.SDK_INT >= 31) { "NPU requires Android API 31+" }
        val profile = assetJson("profile.json")
        check(profile.getString("id") == profileId) { "NPU compiled profile mismatch" }
        val target = profile.getJSONObject("npu_target")
        val soc = Build.SOC_MODEL
        val aliases = target.getJSONArray("device_soc_models")
        check((0 until aliases.length()).any { aliases.getString(it).equals(soc, true) }) {
            "NPU SoC mismatch: observed $soc, expected ${target.getString("soc")}" }
        check(Build.SUPPORTED_ABIS.contains("arm64-v8a")) { "NPU requires arm64-v8a" }
        val directory = activity.applicationInfo.nativeLibraryDir
        val kit = assetJson("npu-kit.json")
        val libraries = kit.getJSONObject("libraries")
        val required = target.getJSONObject("libraries")
        check(libraries.length() == required.length()) { "NPU library inventory mismatch" }
        for (name in required.keys()) {
            check(name.matches(Regex("lib[A-Za-z0-9_]+\\.so"))) { "Invalid NPU library name" }
            val file = File(directory, name)
            val entry = libraries.getJSONObject(name)
            check(file.isFile && file.length() == entry.getLong("bytes") &&
                hash(file) == entry.getString("sha256")) { "NPU library integrity failed: $name" }
            val lock = required.getJSONObject(name)
            if (lock.has("sha256")) check(entry.getString("sha256") == lock.getString("sha256")) {
                "NPU audited library hash mismatch: $name" }
        }
        // Scope DSP lookup to the installed app first, retaining normal device
        // firmware locations. This changes no device files or root permissions.
        Os.setenv("ADSP_LIBRARY_PATH", "$directory;/vendor/lib/rfsa/adsp;/vendor/dsp", true)
        val model = profile.getJSONObject("model")
        val expected = model.getString("sha256")
        val cache = File(activity.filesDir, "validation-npu/$expected")
        cache.mkdirs()
        val destination = File(cache, "model.litertlm")
        val start = System.nanoTime()
        if (!destination.isFile || destination.length() != model.getLong("bytes") || hash(destination) != expected) {
            val temporary = File(cache, "model.partial")
            try {
                activity.assets.open("llamadart_npu/model.litertlm").use { input ->
                    temporary.outputStream().use { output ->
                        val buffer = ByteArray(1024 * 1024)
                        var total = 0L
                        while (true) {
                            check(!cancelled) { "NPU preparation cancelled" }
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            check(total <= model.getLong("bytes")) { "NPU model exceeds locked size" }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                check(temporary.length() == model.getLong("bytes") && hash(temporary) == expected) {
                    "NPU model integrity failed" }
                check(temporary.renameTo(destination)) { "Cannot finalize staged NPU model" }
            } finally { temporary.delete() }
        }
        check(!cancelled) { "NPU preparation cancelled" }
        return mapOf(
            "path" to destination.path, "dispatch_directory" to directory,
            "soc_model" to soc, "soc_manufacturer" to Build.SOC_MANUFACTURER,
            "device_model" to Build.MODEL, "android_api" to Build.VERSION.SDK_INT,
            "abi" to "arm64-v8a", "verified" to true,
            "sha256" to expected, "bytes" to destination.length(),
            "total_ms" to (System.nanoTime() - start) / 1e6,
            "kit" to kit.toString()
        )
    }
}
