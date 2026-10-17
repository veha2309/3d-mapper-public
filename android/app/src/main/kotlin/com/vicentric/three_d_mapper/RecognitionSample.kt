package com.vicentric.three_d_mapper

import java.io.File
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.json.JSONObject
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.imgcodecs.Imgcodecs

/** Exported only after the user explicitly presses Save failed view. */
object RecognitionSample {
    fun write(cache: File, gray: Mat, frame: Map<String, Any?>,
              geometry: Map<String, Any?>, references: List<Pair<Map<String, Any?>, File>>,
              expected: String?): File {
        val directory = File(cache, "recognition_samples").apply { mkdirs() }
        val output = File(directory, "sample-${UUID.randomUUID()}.zip")
        try {
            ZipOutputStream(output.outputStream().buffered()).use { zip ->
                fun bytes(name: String, data: ByteArray) {
                    zip.putNextEntry(ZipEntry(name)); zip.write(data); zip.closeEntry()
                }
                val encoded = MatOfByte()
                try {
                    check(Imgcodecs.imencode(".png", gray, encoded)) { "Could not encode camera sample" }
                    bytes("query.png", encoded.toArray())
                } finally { encoded.release() }
                val descriptions = references.mapIndexed { index, (metadata, file) ->
                    check(file.length() in 1..(32L * 1024 * 1024)) { "Reference sample too large" }
                    val name = "references/reference-$index.${file.extension.lowercase()}"
                    zip.putNextEntry(ZipEntry(name))
                    file.inputStream().use { it.copyTo(zip) }; zip.closeEntry()
                    metadata + mapOf("image" to name)
                }
                val metadata = mapOf("version" to 1, "expected_label_id" to expected,
                    "capture_uptime_ms" to android.os.SystemClock.elapsedRealtime(),
                    "frame" to frame, "geometry" to geometry, "references" to descriptions,
                    "query_image" to "query.png", "navigation_authority" to false,
                    "note" to "Upright analyzed frame. Original reference photos may carry EXIF orientation. Explicit user-triggered diagnostic, not a new enrollment.")
                bytes("sample.json", JSONObject(metadata).toString(2).toByteArray(Charsets.UTF_8))
            }
            return output
        } catch (error: Exception) { output.delete(); throw error }
    }
    fun discard(cache: File, path: String) {
        val file = File(path).canonicalFile
        val directory = File(cache, "recognition_samples").canonicalFile
        check(file.parentFile == directory && file.name.startsWith("sample-") && file.extension == "zip") { "Not an owned recognition sample" }
        if (file.exists()) check(file.delete()) { "Could not remove temporary sample" }
    }
}
