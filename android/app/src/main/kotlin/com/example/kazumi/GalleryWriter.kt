package com.example.kazumi

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Writes image bytes into the gallery **byte for byte**.
 *
 * saver_gallery re-encodes every non-GIF through
 * `BitmapFactory.decodeByteArray` + `Bitmap.compress(JPEG, 100)`, which turns a
 * 432 KB cover into 975 KB and silently loses the original quality. Saving an
 * "original" must keep the source bytes intact, so this handler writes the
 * stream straight to MediaStore (API 29+) or to a file plus a media scan (older
 * releases) without ever decoding the image.
 */
class GalleryWriter(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.predidit.kazumi/gallery_writer"
        private const val DEFAULT_ALBUM = "Pictures"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveImage" -> saveImage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")?.trim()
        val mimeType = call.argument<String>("mimeType")?.trim()
        if (bytes == null || bytes.isEmpty() || fileName.isNullOrEmpty() || mimeType.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "bytes, fileName and mimeType are required", null)
            return
        }
        try {
            val relativePath = "${DEFAULT_ALBUM}/${call.argument<String>("album")?.trim().orEmpty()}"
                .trimEnd('/')
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                writeThroughMediaStore(bytes, fileName, mimeType, relativePath)
            } else {
                writeThroughFile(bytes, fileName, relativePath)
            }
            result.success(uri?.toString())
        } catch (e: Exception) {
            result.error("SAVE_FAILED", "Failed to write image: ${e.message}", null)
        }
    }

    /** API 29+: MediaStore accepts an output stream, so the bytes stay untouched. */
    private fun writeThroughMediaStore(
        bytes: ByteArray,
        fileName: String,
        mimeType: String,
        relativePath: String
    ): Uri? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            // Keep the stream opaque: no transcoding on the way in or out.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IOException("MediaStore refused the insert")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IOException("MediaStore returned no output stream")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    /** API < 29: write the file directly, then let the scanner index it. */
    @Suppress("DEPRECATION")
    private fun writeThroughFile(bytes: ByteArray, fileName: String, relativePath: String): Uri? {
        val root = Environment.getExternalStorageDirectory()
        val directory = File(root, relativePath)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Cannot create $directory")
        }
        val file = uniqueFile(directory, fileName)
        file.outputStream().use { output ->
            output.write(bytes)
            output.flush()
        }
        MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf(null), null)
        return Uri.fromFile(file)
    }

    /** Never overwrite: append a counter until the name is free. */
    private fun uniqueFile(directory: File, fileName: String): File {
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var candidate = File(directory, fileName)
        var index = 1
        while (candidate.exists()) {
            candidate = File(directory, "$base-$index$ext")
            index++
        }
        return candidate
    }
}
