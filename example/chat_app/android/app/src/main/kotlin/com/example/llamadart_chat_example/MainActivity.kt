package com.example.llamadart_chat_example

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val clipboardExecutor = Executors.newSingleThreadExecutor()
    private var clipboardChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIPBOARD_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            if (call.method != "readMedia") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val allowImage = call.argument<Boolean>("allowImage") ?: false
            val allowAudio = call.argument<Boolean>("allowAudio") ?: false
            clipboardExecutor.execute {
                try {
                    val attachment = readClipboardMedia(allowImage, allowAudio)
                    runOnUiThread { result.success(attachment) }
                } catch (error: ClipboardAttachmentTooLargeException) {
                    runOnUiThread {
                        result.error(
                            "attachment_too_large",
                            "Clipboard attachment is larger than 64 MB.",
                            null,
                        )
                    }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error(
                            "clipboard_read_failed",
                            "Could not read the clipboard attachment.",
                            error.message,
                        )
                    }
                }
            }
        }
        clipboardChannel = channel
    }

    override fun onDestroy() {
        clipboardChannel?.setMethodCallHandler(null)
        clipboardChannel = null
        clipboardExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun readClipboardMedia(
        allowImage: Boolean,
        allowAudio: Boolean,
    ): Map<String, Any>? {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null
        val resolver = contentResolver
        for (index in 0 until clip.itemCount) {
            val uri = clip.getItemAt(index).uri ?: continue
            val kind = mediaKind(resolver.getType(uri), uri) ?: continue
            if ((kind == "image" && !allowImage) || (kind == "audio" && !allowAudio)) {
                continue
            }
            resolver.openInputStream(uri)?.use { stream ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_CLIPBOARD_BYTES) {
                        throw ClipboardAttachmentTooLargeException()
                    }
                    output.write(buffer, 0, count)
                }
                return mapOf("kind" to kind, "bytes" to output.toByteArray())
            }
        }
        return null
    }

    private fun mediaKind(mimeType: String?, uri: Uri): String? {
        if (mimeType?.startsWith("image/") == true) return "image"
        if (mimeType?.startsWith("audio/") == true) return "audio"

        val path = uri.lastPathSegment?.lowercase() ?: return null
        if (IMAGE_EXTENSIONS.any(path::endsWith)) return "image"
        if (AUDIO_EXTENSIONS.any(path::endsWith)) return "audio"
        return null
    }

    private class ClipboardAttachmentTooLargeException : Exception()

    companion object {
        private const val CLIPBOARD_CHANNEL = "llamadart_chat/clipboard"
        private const val MAX_CLIPBOARD_BYTES = 64 * 1024 * 1024
        private val IMAGE_EXTENSIONS = setOf(
            ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp",
            ".heic", ".heif", ".tif", ".tiff",
        )
        private val AUDIO_EXTENSIONS = setOf(
            ".mp3", ".m4a", ".aac", ".wav", ".ogg", ".oga",
            ".opus", ".flac",
        )
    }
}
