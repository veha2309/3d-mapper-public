package com.vicentric.three_d_mapper

import android.content.Context
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer
import java.security.MessageDigest
import kotlin.math.exp
import org.json.JSONObject
import org.opencv.core.*
import org.opencv.imgproc.Imgproc

/** Fixed-shape, CPU-only official ALIKED + LightGlue; no network or pose claims. */
class LearnedVision(context: Context, val intraOpThreads: Int = minOf(DEFAULT_THREADS, Runtime.getRuntime().availableProcessors().coerceAtLeast(1))) : AutoCloseable {
    companion object {
        const val DEFAULT_THREADS = 4
        const val SIZE = 480
        const val COUNT = 256
        const val DIM = 128
        const val NAME = "ALIKED + LightGlue"
    }
    data class Features(val rawPoints: FloatArray, val descriptors: FloatArray,
                        val points: Array<KeyPoint>, val valid: BooleanArray) {
        val validCount get() = valid.count { it }
    }
    private val environment = OrtEnvironment.getEnvironment()
    private val extractor: OrtSession
    private val matcher: OrtSession
    val metadata: String = context.assets.open("vision/models.json").bufferedReader().use { it.readText() }
    init {
        require(intraOpThreads in 1..8) { "Unsupported inference thread count" }
        val manifest = JSONObject(metadata)
        check(manifest.getInt("image_size") == SIZE && manifest.getInt("keypoints") == COUNT && manifest.getInt("descriptor_size") == DIM) { "Unsupported learned model dimensions" }
        check(manifest.getString("matcher_output") == "log_assignment") { "Unsupported learned matcher output" }
        fun load(name: String): OrtSession {
            val bytes = context.assets.open("vision/$name").use { it.readBytes() }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            check(digest == manifest.getJSONObject("files").getString(name)) { "Model checksum failed: $name" }
            return OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(intraOpThreads)
                options.setInterOpNumThreads(1)
                options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                environment.createSession(bytes, options)
            }
        }
        extractor = load("aliked.onnx")
        try { matcher = load("lightglue.onnx") } catch (error: Exception) { extractor.close(); throw error }
    }
    private fun floats(result: OrtSession.Result, index: Int, count: Int): FloatArray {
        val buffer = (result[index] as OnnxTensor).floatBuffer
        check(buffer.remaining() == count) { "Unexpected learned model output" }
        return FloatArray(count).also { buffer.get(it); check(it.all { x -> x.isFinite() }) { "Non-finite learned features" } }
    }
    fun extract(gray: Mat): Features {
        val transform = VisionLetterbox(gray.cols(), gray.rows(), SIZE)
        val resized = Mat()
        val canvas = Mat.zeros(SIZE, SIZE, CvType.CV_8UC1)
        try {
            Imgproc.resize(gray, resized, Size(transform.width.toDouble(), transform.height.toDouble()))
            val region = canvas.submat(Rect(transform.left, transform.top, transform.width, transform.height))
            try { resized.copyTo(region) } finally { region.release() }
            val bytes = ByteArray(SIZE * SIZE)
            canvas.get(0, 0, bytes)
            val values = FloatArray(bytes.size) { (bytes[it].toInt() and 255) / 255f }
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(values), longArrayOf(1, 1, SIZE.toLong(), SIZE.toLong())).use { input ->
                extractor.run(mapOf("image" to input)).use { result ->
                    val raw = floats(result, 0, COUNT * 2)
                    val descriptors = floats(result, 1, COUNT * DIM)
                    val scores = floats(result, 2, COUNT)
                    val points = Array(COUNT) { i -> KeyPoint(transform.originalX(raw[2*i]), transform.originalY(raw[2*i+1]), 1f) }
                    val valid = BooleanArray(COUNT) { i -> scores[i] >= .2f && transform.contains(raw[2*i], raw[2*i+1]) }
                    return Features(raw, descriptors, points, valid)
                }
            }
        } finally { resized.release(); canvas.release() }
    }
    fun match(reference: Features, query: Features): List<DMatch> {
        if (reference.validCount < 16 || query.validCount < 16) return emptyList()
        val tensors = linkedMapOf<String, OnnxTensor>()
        try {
            fun add(name: String, values: FloatArray, dim: Int) {
                tensors[name] = OnnxTensor.createTensor(environment, FloatBuffer.wrap(values), longArrayOf(1, COUNT.toLong(), dim.toLong()))
            }
            add("points0", reference.rawPoints, 2); add("descriptors0", reference.descriptors, DIM)
            add("points1", query.rawPoints, 2); add("descriptors1", query.descriptors, DIM)
            matcher.run(tensors).use { result ->
                val scores = floats(result, 0, COUNT * COUNT)
                val matches = IntArray(COUNT)
                val reverse = IntArray(COUNT)
                for (i in 0 until COUNT) for (j in 0 until COUNT) {
                    if (scores[i * COUNT + j] > scores[i * COUNT + matches[i]]) matches[i] = j
                    if (scores[i * COUNT + j] > scores[reverse[j] * COUNT + j]) reverse[j] = i
                }
                return matches.indices.mapNotNull { i ->
                    val j = matches[i]
                    val confidence = exp(scores[i * COUNT + j])
                    if (reverse[j] == i && reference.valid[i] && query.valid[j] && confidence > .1f)
                        DMatch(i, j, 1f - confidence) else null
                }
            }
        } finally { tensors.values.forEach { it.close() } }
    }
    override fun close() { try { matcher.close() } finally { extractor.close() } }
}
