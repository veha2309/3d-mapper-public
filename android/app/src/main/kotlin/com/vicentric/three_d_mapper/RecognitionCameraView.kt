package com.vicentric.three_d_mapper

import android.content.Context
import android.os.SystemClock
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.platform.PlatformView
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.util.concurrent.Executors

class RecognitionCameraView(private val activity: MainActivity, context: Context, private val entries: List<Map<*, *>>, private val useLearned: Boolean = true) : PlatformView, DefaultLifecycleObserver {
    private val preview = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        // Full analysis frame stays visible; left/right labels refer to this frame.
        scaleType = PreviewView.ScaleType.FIT_CENTER
    }
    private val worker = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var previewCase: Preview? = null
    private var analysisCase: ImageAnalysis? = null
    private var matcher: ReferenceMatcher? = null
    @Volatile private var closed = false
    private var lastFrame = 0L
    private var sampleImage: Mat? = null
    private var sampleResult: Map<String, Any?>? = null
    private var sampleAt = 0L
    init {
        activity.lifecycle.addObserver(this)
        preview.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            val rotation = preview.display?.rotation ?: android.view.Surface.ROTATION_0
            if (analysisCase != null && analysisCase!!.targetRotation != rotation) {
                previewCase?.targetRotation = rotation
                analysisCase?.targetRotation = rotation
                resetEvidence()
            }
        }
        preview.post {
            if (!closed) {
                worker.execute {
                    try {
                        activity.emit(this, mapOf("state" to "loading", "message" to "Preparing ${entries.size} labeled reference views…"))
                        matcher = ReferenceMatcher(context, activity.filesDir.parentFile!!, entries, useLearned)
                        activity.emit(this, matcher!!.diagnostics() + mapOf("device" to mapOf("manufacturer" to android.os.Build.MANUFACTURER, "model" to android.os.Build.MODEL, "android_sdk" to android.os.Build.VERSION.SDK_INT)))
                        activity.runOnUiThread { if (!closed) startCamera() }
                    } catch (e: Exception) { emitError(e) }
                }
            }
        }
    }
    private fun emitError(e: Exception) {
        if (!closed) activity.emit(this, mapOf("event" to "error", "state" to "error", "reason" to "camera_or_matcher_error", "message" to "Camera recognition: ${e.message}", "error_type" to e.javaClass.simpleName))
    }
    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(preview.context)
        future.addListener({
            if (closed) return@addListener
            try {
                provider = future.get()
                val rotation = preview.display?.rotation ?: android.view.Surface.ROTATION_0
                val cameraPreview = Preview.Builder().setTargetRotation(rotation).build().also { it.setSurfaceProvider(preview.surfaceProvider) }
                val analysis = ImageAnalysis.Builder().setTargetRotation(rotation)
                    .setTargetResolution(android.util.Size(960, 720))
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                previewCase = cameraPreview; analysisCase = analysis
                analysis.setAnalyzer(worker) { image ->
                    try {
                        val now = SystemClock.elapsedRealtime()
                        if (closed || now - lastFrame < 450) return@setAnalyzer
                        lastFrame = now
                        val gray = grayscale(image)
                        try {
                            val result = matcher!!.analyze(gray, now)
                            val processingMs = SystemClock.elapsedRealtime() - now
                            sampleImage?.release(); sampleImage = gray
                            sampleAt = now
                            sampleResult = result + mapOf("processing_ms" to processingMs,
                                "freshness_rejected" to (processingMs > 1800),
                                "analysis_start_uptime_ms" to now, "rotation_degrees" to image.imageInfo.rotationDegrees,
                                "sensor_width" to image.width, "sensor_height" to image.height)
                            if (processingMs > 1800) {
                                matcher?.reset()
                                if (!closed) activity.emit(this, result + mapOf("state" to "searching", "name" to null, "label_id" to null, "streak" to 0, "reason" to "slow_analysis", "geometry_reason" to result["reason"], "message" to "Analysis is too slow for fresh recognition. No current landmark confirmed.", "processing_ms" to processingMs, "rotation_degrees" to image.imageInfo.rotationDegrees, "sensor_width" to image.width, "sensor_height" to image.height))
                            } else if (!closed) activity.emit(this, result + mapOf("processing_ms" to processingMs, "rotation_degrees" to image.imageInfo.rotationDegrees, "sensor_width" to image.width, "sensor_height" to image.height))
                        } finally { if (sampleImage !== gray) gray.release() }
                    } catch (e: Exception) { matcher?.reset(); emitError(e) }
                    finally { image.close() }
                }
                provider!!.bindToLifecycle(activity, CameraSelector.DEFAULT_BACK_CAMERA, cameraPreview, analysis)
            } catch (e: Exception) { emitError(e) }
        }, ContextCompat.getMainExecutor(preview.context))
    }
    private fun grayscale(image: ImageProxy): Mat {
        val crop = image.cropRect; val plane = image.planes[0]
        val pixels = ByteArray(crop.width() * crop.height()); val buffer = plane.buffer.duplicate()
        val origin = buffer.position()
        for (y in 0 until crop.height()) {
            val sourceOffset = origin + (y + crop.top) * plane.rowStride + crop.left * plane.pixelStride
            val destinationOffset = y * crop.width()
            if (plane.pixelStride == 1) {
                // Camera Y planes normally have contiguous pixels, with padding only between rows.
                buffer.position(sourceOffset)
                buffer.get(pixels, destinationOffset, crop.width())
            } else {
                for (x in 0 until crop.width()) {
                    pixels[destinationOffset + x] = buffer.get(sourceOffset + x * plane.pixelStride)
                }
            }
        }
        val sensor = Mat(crop.height(), crop.width(), CvType.CV_8UC1)
        val upright = Mat(); val small = Mat()
        try {
            sensor.put(0, 0, pixels)
            when (image.imageInfo.rotationDegrees) {
                90 -> Core.rotate(sensor, upright, Core.ROTATE_90_CLOCKWISE)
                180 -> Core.rotate(sensor, upright, Core.ROTATE_180)
                270 -> Core.rotate(sensor, upright, Core.ROTATE_90_COUNTERCLOCKWISE)
                else -> sensor.copyTo(upright)
            }
            val scale = 960.0 / maxOf(upright.cols(), upright.rows())
            if (scale < 1) Imgproc.resize(upright, small, Size(upright.cols() * scale, upright.rows() * scale)) else upright.copyTo(small)
            return small
        } catch (e: Exception) { small.release(); throw e }
        finally { sensor.release(); upright.release() }
    }
    fun saveSample(expected: String?, callback: io.flutter.plugin.common.MethodChannel.Result) {
        if (closed) { callback.error("sample_unavailable", "Camera test is closed", null); return }
        worker.execute {
            try {
                check(!closed && sampleImage != null && sampleResult != null && SystemClock.elapsedRealtime() - sampleAt <= 5000) { "No recent analyzed camera frame. Keep aiming at the test landmark and try again." }
                val file = RecognitionSample.write(activity.cacheDir, sampleImage!!, sampleResult!!,
                    matcher!!.sampleGeometry(), matcher!!.sampleReferences(), expected)
                activity.runOnUiThread { callback.success(mapOf("path" to file.path)) }
            } catch (error: Exception) { activity.runOnUiThread { callback.error("sample_failed", error.message, null) } }
        }
    }
    fun resetEvidence() { if (!closed) worker.execute { matcher?.reset(); sampleImage?.release(); sampleImage = null; sampleResult = null } }
    override fun onPause(owner: LifecycleOwner) { resetEvidence() }
    override fun getView(): View = preview
    override fun dispose() {
        if (closed) return
        closed = true; activity.lifecycle.removeObserver(this)
        analysisCase?.clearAnalyzer()
        val cases = listOfNotNull(previewCase, analysisCase)
        if (cases.isNotEmpty()) provider?.unbind(*cases.toTypedArray())
        worker.execute { matcher?.close(); matcher = null; sampleImage?.release(); sampleImage = null; sampleResult = null }
        worker.shutdown()
        if (activity.recognitionView === this) activity.recognitionView = null
    }
}
