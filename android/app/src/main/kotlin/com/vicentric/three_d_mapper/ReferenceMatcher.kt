package com.vicentric.three_d_mapper

import android.graphics.BitmapFactory
import android.os.SystemClock
import java.io.File
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.calib3d.Calib3d
import org.opencv.core.*
import org.opencv.features2d.BFMatcher
import org.opencv.features2d.ORB
import org.opencv.features2d.SIFT
import org.opencv.imgproc.Imgproc

/** Appearance matching with diagnostic reasons. It does not estimate a metric pose. */
class ReferenceMatcher(context: android.content.Context, private val allowedRoot: File, entries: List<Map<*, *>>, private val useLearned: Boolean = true) : AutoCloseable {
    private data class Features(val points: Array<KeyPoint>, val descriptors: Mat, val width: Int, val height: Int, val learned: LearnedVision.Features? = null) {
        fun close() = descriptors.release()
    }
    private data class Reference(val id: String, val identity: String, val name: String, val centre: String, val centreId: String, val file: File, val features: Features, val labelId: String, val source: String)
    private data class Attempt(val reference: Reference, val algorithm: String, var reason: String = "few_correspondences", var good: Int = 0,
        var referenceKeypoints: Int = 0, var inliers: Int = 0, var ratio: Double = 0.0, var x: Double = .5, var y: Double = .5, var spreadX: Double = 0.0, var spreadY: Double = 0.0, var area: Double = 0.0) {
        val verified get() = reason == "verified"
        val score get() = inliers * ratio
        var matchPoints: List<Map<String, Any>> = emptyList()
        fun diagnostic() = mapOf("reference_id" to reference.id, "label_id" to reference.labelId, "source" to reference.source, "name" to reference.name, "identity" to reference.identity, "centre" to reference.centre,
            "matcher" to algorithm, "reason" to reason, "reference_keypoints" to referenceKeypoints, "good_matches" to good,
            "inliers" to inliers, "inlier_ratio" to ratio, "spread_x" to spreadX, "spread_y" to spreadY, "projected_area" to area, "projected_label_x" to x, "projected_label_y" to y)
    }
    private var learnedVision: LearnedVision? = null
    private val engineName get() = if (useLearned) LearnedVision.NAME else "ORB + SIFT"
    private val orb: ORB
    private val sift: SIFT
    private val orbMatcher: BFMatcher
    private val siftMatcher: BFMatcher
    private val references = mutableListOf<Reference>()
    private val siftCache = LinkedHashMap<String, Features>(16, .75f, true)
    private val scheduler = FallbackScheduler()
    private val learnedSelector = LearnedCandidateSelector()
    val warnings = mutableListOf<String>()
    private val referenceStats = mutableListOf<Map<String, Any?>>()
    private val gate = ConfirmationGate()
    private var sampleAttempts: List<Attempt> = emptyList()
    fun sampleGeometry(): Map<String, Any?> = mapOf("attempts" to sampleAttempts.map { it.diagnostic() + mapOf("match_points" to it.matchPoints) }, "model_metadata" to learnedVision?.metadata)
    fun sampleReferences(): List<Pair<Map<String, Any?>, File>> = sampleAttempts.map { it.reference }.distinctBy { it.id }.map {
        mapOf<String, Any?>("reference_id" to it.id, "label_id" to it.labelId, "name" to it.name,
            "identity" to it.identity, "source" to it.source,
            "decoded_width" to it.features.width, "decoded_height" to it.features.height) to it.file
    }
    init {
        check(entries.size in 1..60) { "Choose between 1 and 60 labeled reference views" }
        check(OpenCVLoader.initLocal()) { "OpenCV could not be initialized" }
        orb = ORB.create(1400).apply { setFastThreshold(12) }
        sift = SIFT.create(1200)
        orbMatcher = BFMatcher.create(Core.NORM_HAMMING, false)
        siftMatcher = BFMatcher.create(Core.NORM_L2, false)
        try {
            if (useLearned) learnedVision = LearnedVision(context)
            for (entry in entries) {
                val name = entry["name"] as? String ?: "Unnamed"
                try {
                    val original = if (useLearned && entry["source"] == "separate_photo") entry["original_path"] as? String else null
                    val file = File(original ?: entry["path"] as String).canonicalFile
                    check(file.path.startsWith(allowedRoot.canonicalPath + File.separator) && file.extension.lowercase() in listOf("png", "jpg", "jpeg") && file.length() in 1..(32L * 1024 * 1024)) { "Invalid reference file" }
                    val feature = fromFile(file, false)
                    referenceStats.add(mapOf("reference_id" to entry["id"], "label_id" to (entry["label_id"] ?: entry["id"]), "source" to (entry["source"] ?: "panorama"), "uses_original_photo" to (original != null), "identity" to referenceIdentity(entry), "name" to name, "orb_keypoints" to (if (useLearned) null else feature.points.size), "learned_keypoints" to feature.learned?.validCount, "loaded" to ((feature.learned?.validCount ?: feature.points.size) >= (if (useLearned) 16 else 40))))
                    if ((feature.learned?.validCount ?: feature.points.size) < (if (useLearned) 16 else 40)) { feature.close(); warnings.add("$name: too little visual detail"); continue }
                    val id = entry["id"] as String
                    val identity = referenceIdentity(entry)
                    references.add(Reference(id, identity, name, entry["centre"] as String, entry["centre_id"] as String, file, feature, entry["label_id"] as? String ?: id, entry["source"] as? String ?: "panorama"))
                } catch (e: Exception) {
                    warnings.add("$name: ${e.message}")
                    referenceStats.add(mapOf("reference_id" to entry["id"], "label_id" to (entry["label_id"] ?: entry["id"]), "identity" to referenceIdentity(entry), "name" to name, "loaded" to false, "error" to e.message))
                }
            }
            check(references.isNotEmpty()) { "No usable reference views. Label distinctive signs, doors, and surrounding details on Windows. ${warnings.joinToString("; ")}" }
        } catch (e: Exception) { close(); throw e }
    }
    fun diagnostics(): Map<String, Any?> = mapOf("event" to "reference_preparation", "engine_version" to "android-learned-v3-cpu4", "matcher" to engineName, "model_metadata" to learnedVision?.metadata, "state" to "ready", "loaded" to references.size,
        "reference_stats" to referenceStats.toList(), "warnings" to warnings.toList(),
        "config" to mapOf("inference_cpu_threads" to learnedVision?.intraOpThreads, "learned_image_size" to (if (useLearned) LearnedVision.SIZE else null), "learned_keypoints" to (if (useLearned) LearnedVision.COUNT else null), "learned_candidates_per_frame" to 2, "neural_budget_ms" to 1400, "orb_features" to 1400, "sift_features" to 1200, "sift_candidates_per_frame" to 3,
            "min_good_matches" to 16, "min_inliers" to 12, "min_inlier_ratio" to .45, "ratio_test" to .75, "min_spread" to .2, "confirmation_frames" to 3))
    private fun fromFile(file: File, fallback: Boolean): Features {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        check(bounds.outWidth in 64..16000 && bounds.outHeight in 64..16000 && bounds.outWidth.toLong() * bounds.outHeight <= 64000000) { "Invalid reference dimensions" }
        val options = BitmapFactory.Options().apply { inSampleSize = 1 }
        while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 1600) options.inSampleSize *= 2
        var bitmap = BitmapFactory.decodeFile(file.path, options) ?: error("Unreadable reference")
        val orientation = android.media.ExifInterface(file.path).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)
        val transform = android.graphics.Matrix()
        when (orientation) {
            2 -> transform.setScale(-1f, 1f)
            3 -> transform.setRotate(180f)
            4 -> transform.setScale(1f, -1f)
            5 -> { transform.setRotate(90f); transform.postScale(-1f, 1f) }
            6 -> transform.setRotate(90f)
            7 -> { transform.setRotate(-90f); transform.postScale(-1f, 1f) }
            8 -> transform.setRotate(-90f)
        }
        if (!transform.isIdentity) {
            val upright = android.graphics.Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, transform, true)
            if (upright !== bitmap) { bitmap.recycle(); bitmap = upright }
        }
        val rgba = Mat(); val gray = Mat()
        try {
            Utils.bitmapToMat(bitmap, rgba); Imgproc.cvtColor(rgba, gray, Imgproc.COLOR_RGBA2GRAY)
            return features(gray, fallback)
        } finally { rgba.release(); gray.release(); bitmap.recycle() }
    }
    private fun features(gray: Mat, fallback: Boolean = false): Features {
        if (useLearned) {
            val learned = learnedVision!!.extract(gray)
            val descriptors = Mat(LearnedVision.COUNT, LearnedVision.DIM, CvType.CV_32F)
            descriptors.put(0, 0, learned.descriptors)
            return Features(learned.points, descriptors, gray.cols(), gray.rows(), learned)
        }
        val points = MatOfKeyPoint(); val descriptors = Mat(); val mask = Mat()
        try {
            if (fallback) sift.detectAndCompute(gray, mask, points, descriptors) else orb.detectAndCompute(gray, mask, points, descriptors)
            return Features(points.toArray(), descriptors, gray.cols(), gray.rows())
        } catch (e: Exception) { descriptors.release(); throw e }
        finally { points.release(); mask.release() }
    }
    private fun cachedSift(reference: Reference): Features {
        siftCache[reference.id]?.let { return it }
        val feature = fromFile(reference.file, true)
        siftCache[reference.id] = feature
        if (siftCache.size > 12) { val oldest = siftCache.entries.first(); oldest.value.close(); siftCache.remove(oldest.key) }
        return feature
    }
    private fun verify(reference: Reference, r: Features, live: Features, fallback: Boolean, proposed: List<DMatch>? = null): Attempt {
        val result = Attempt(reference, if (proposed != null) "ALIKED descriptor retrieval" else if (useLearned) LearnedVision.NAME else if (fallback) "SIFT" else "ORB", referenceKeypoints = r.learned?.validCount ?: r.points.size)
        if (!useLearned && r.descriptors.empty()) return result.apply { reason = "reference_low_detail" }
        if ((live.learned?.validCount ?: live.descriptors.rows()) < 2) return result.apply { reason = "live_low_detail" }
        val matches = mutableListOf<MatOfDMatch>(); val source = MatOfPoint2f(); val target = MatOfPoint2f(); val mask = Mat()
        var homography: Mat? = null
        val corners = MatOfPoint2f(); val projected = MatOfPoint2f(); val centre = MatOfPoint2f(); val mappedCentre = MatOfPoint2f()
        try {
            if (!useLearned) (if (fallback) siftMatcher else orbMatcher).knnMatch(r.descriptors, live.descriptors, matches, 2)
            val good = proposed ?: if (useLearned) learnedVision!!.match(r.learned!!, live.learned!!) else matches.mapNotNull { row -> val p = row.toArray(); if (p.size == 2 && p[0].distance < .75f * p[1].distance) p[0] else null }
                .sortedBy { it.distance }.distinctBy { it.trainIdx }
            result.good = good.size
            result.matchPoints = if (proposed == null && useLearned) good.map { match ->
                val a = r.points[match.queryIdx].pt; val b = live.points[match.trainIdx].pt
                mapOf("reference" to listOf(a.x, a.y), "query" to listOf(b.x, b.y), "match_distance" to match.distance, "inlier" to false)
            } else emptyList()
            if (good.size < 16) return result
            source.fromList(good.map { r.points[it.queryIdx].pt }); target.fromList(good.map { live.points[it.trainIdx].pt })
            homography = Calib3d.findHomography(source, target, Calib3d.RANSAC, 4.0, mask)
            if (homography.empty()) return result.apply { reason = "no_homography" }
            result.inliers = Core.countNonZero(mask); result.ratio = result.inliers.toDouble() / good.size
            result.matchPoints = result.matchPoints.mapIndexed { index, point -> point + mapOf("inlier" to (mask.get(index, 0)[0] > 0)) }
            if (result.inliers < 12) return result.apply { reason = "too_few_inliers" }
            if (result.ratio < .45) return result.apply { reason = "low_inlier_ratio" }
            val spread = good.indices.filter { mask.get(it, 0)[0] > 0 }.map { r.points[good[it].queryIdx].pt }
            result.spreadX = (spread.maxOf { it.x } - spread.minOf { it.x }) / r.width
            result.spreadY = (spread.maxOf { it.y } - spread.minOf { it.y }) / r.height
            if (result.spreadX < .2 || result.spreadY < .2) return result.apply { reason = "concentrated_details" }
            corners.fromArray(Point(0.0, 0.0), Point(r.width.toDouble(), 0.0), Point(r.width.toDouble(), r.height.toDouble()), Point(0.0, r.height.toDouble()))
            Core.perspectiveTransform(corners, projected, homography)
            val p = projected.toArray()
            if (p.any { !it.x.isFinite() || !it.y.isFinite() }) return result.apply { reason = "unstable_projection" }
            result.area = p.indices.sumOf { i -> p[i].x * p[(i+1)%4].y - p[(i+1)%4].x * p[i].y } / 2 / (live.width * live.height)
            val contour = MatOfPoint(*p)
            val convex = try { Imgproc.isContourConvex(contour) } finally { contour.release() }
            if (!convex) return result.apply { reason = "non_convex_projection" }
            if (result.area !in .02..4.0) return result.apply { reason = "projection_size" }
            centre.fromArray(Point(r.width / 2.0, r.height / 2.0)); Core.perspectiveTransform(centre, mappedCentre, homography)
            val visible = mappedCentre.toArray().single()
            result.x = visible.x / live.width; result.y = visible.y / live.height; val y = result.y
            if (!result.x.isFinite() || !y.isFinite() || result.x !in 0.0..1.0 || y !in 0.0..1.0) return result.apply { reason = "label_out_of_frame" }
            return result.apply { reason = "verified" }
        } catch (e: Exception) { return result.apply { reason = "geometry_error" } }
        finally {
            matches.forEach { it.release() }; source.release(); target.release(); mask.release(); homography?.release()
            corners.release(); projected.release(); centre.release(); mappedCentre.release()
        }
    }
    private fun retrieve(reference: Reference, live: Features): Attempt {
        if (live.learned!!.validCount < 16) return Attempt(reference, "ALIKED descriptor retrieval", reason = "live_low_detail")
        val rows = mutableListOf<MatOfDMatch>()
        try {
            siftMatcher.knnMatch(reference.features.descriptors, live.descriptors, rows, 2)
            val good = rows.mapNotNull { row ->
                val pair = row.toArray()
                if (pair.size == 2 && pair[0].distance < .85f * pair[1].distance &&
                    reference.features.learned!!.valid[pair[0].queryIdx] && live.learned.valid[pair[0].trainIdx]) pair[0] else null
            }.sortedBy { it.distance }.distinctBy { it.trainIdx }
            return verify(reference, reference.features, live, false, good)
        } finally { rows.forEach { it.release() } }
    }
    private fun quality(gray: Mat): Map<String, Double> {
        val laplacian = Mat(); val mean = MatOfDouble(); val deviation = MatOfDouble()
        try {
            val brightness = Core.mean(gray).`val`[0]
            Imgproc.Laplacian(gray, laplacian, CvType.CV_64F); Core.meanStdDev(laplacian, mean, deviation)
            val sigma = deviation.toArray()[0]
            return mapOf("brightness" to brightness, "sharpness_variance" to sigma * sigma)
        } finally { laplacian.release(); mean.release(); deviation.release() }
    }
    fun reset() { gate.reset(); scheduler.reset() }
    fun analyze(gray: Mat, now: Long): Map<String, Any?> {
        val start = SystemClock.elapsedRealtime()
        val live = features(gray)
        val featuresMs = SystemClock.elapsedRealtime() - start
        val attempts = mutableListOf<Attempt>()
        var siftMs = 0L; var fallbackSkipped = 0
        var retrievalMs = 0L
        var comparisonIncomplete = false
        val retrieval = mutableListOf<Attempt>()
        try {
            val orbStart = SystemClock.elapsedRealtime()
            if (useLearned) {
                references.forEach { retrieval.add(retrieve(it, live)) }
                retrievalMs = SystemClock.elapsedRealtime() - orbStart
                val selectedIds = learnedSelector.select(retrieval.map {
                    LearnedCandidateSelector.Candidate(it.reference.id, it.reference.identity, it.inliers, it.ratio, it.good)
                })
                for (id in selectedIds) {
                    if (SystemClock.elapsedRealtime() - start >= 1400) { comparisonIncomplete = true; break }
                    val reference = references.first { it.id == id }
                    attempts.add(verify(reference, reference.features, live, false))
                }
            } else references.forEach { attempts.add(verify(it, it.features, live, false)) }
            val orbMs = SystemClock.elapsedRealtime() - orbStart
            if (!useLearned && attempts.none { it.verified } && SystemClock.elapsedRealtime() - start < 1000) {
                val fallbackStart = SystemClock.elapsedRealtime()
                val rankedIds = attempts.sortedByDescending { it.good }.map { it.reference.id }
                val selected = scheduler.select(references.map { it.id }, rankedIds).map { id -> references.first { it.id == id } }
                val fallbackLive = features(gray, true)
                try {
                    for (reference in selected) {
                        if (SystemClock.elapsedRealtime() - start > 1200) { fallbackSkipped++; continue }
                        attempts.add(verify(reference, cachedSift(reference), fallbackLive, true))
                    }
                } finally { fallbackLive.close() }
                siftMs = SystemClock.elapsedRealtime() - fallbackStart
            }
            val candidates = attempts.filter { it.verified }.groupBy { it.reference.identity }.values.map { group -> group.maxBy { it.score } }.sortedByDescending { it.score }
            val best = candidates.firstOrNull()
            if (best?.algorithm == "SIFT") scheduler.remember(best.reference.id)
            val ambiguous = best != null && candidates.size > 1 && candidates[1].score >= best.score * .8
            val confirmed = gate.update(if (ambiguous || comparisonIncomplete) null else best?.reference?.identity, now)
            val ranked = attempts.sortedWith(compareByDescending<Attempt> { it.verified }.thenByDescending { it.inliers }.thenByDescending { it.good })
            val closest = ranked.firstOrNull()
            val quality = quality(gray)
            val hint = when {
                quality.getValue("brightness") < 35 -> "Scene is dark. Add light or aim at a brighter landmark."
                quality.getValue("sharpness_variance") < 35 -> "Image has little sharp detail. Hold steady, check focus, and move closer."
                closest?.reason == "few_correspondences" -> "Try nearer the capture position and include the same surrounding details."
                closest?.reason == "concentrated_details" -> "Include more of the doorway, sign, and surrounding edges."
                closest?.reason == "label_out_of_frame" -> "The labeled point may be outside the camera view. Turn toward it."
                else -> "Hold steady and keep the landmark and its surroundings visible."
            }
            val base = mutableMapOf<String, Any?>("event" to "frame", "inliers" to (best?.inliers ?: closest?.inliers ?: 0), "streak" to gate.streak,
                "loaded" to references.size, "warnings" to warnings.toList(), "query_keypoints" to (live.learned?.validCount ?: live.points.size),
                "frame_width" to gray.cols(), "frame_height" to gray.rows(), "quality" to quality, "hint" to hint,
                "features_ms" to featuresMs, "retrieval_ms" to retrievalMs, "retrieval_checked" to retrieval.size, "neural_checked" to (if (useLearned) attempts.size else 0), "comparison_incomplete" to comparisonIncomplete, "learned_match_ms" to (if (useLearned) orbMs - retrievalMs else 0L), "orb_ms" to (if (useLearned) 0L else orbMs), "sift_ms" to siftMs, "fallback_skipped" to fallbackSkipped,
                "candidates" to ranked.map { it.diagnostic() } + retrieval.map { it.diagnostic() + mapOf("reason" to ("retrieval_" + it.reason), "neural_evaluated" to attempts.any { a -> a.reference.id == it.reference.id }) } + referenceStats.filter { it["loaded"] == false }.map { it + mapOf("reason" to "reference_not_loaded", "matcher" to "not analyzed") }, "rejection_counts" to attempts.filter { !it.verified }.groupingBy { it.reason }.eachCount(),
                "reason" to if (comparisonIncomplete) "comparison_budget_exhausted" else if (ambiguous) "ambiguous_landmarks" else if (best != null) "verified" else closest?.reason,
                "candidate_name" to closest?.reference?.name, "matcher" to (best?.algorithm ?: closest?.algorithm ?: engineName))
            if (confirmed && best != null) {
                base.putAll(mapOf("state" to "recognized", "name" to best.reference.name, "label_id" to best.reference.labelId, "reference_id" to best.reference.id, "reference_source" to best.reference.source,
                    "centre" to best.reference.centre, "centre_id" to best.reference.centreId,
                    "position" to if (best.x < .35) "left" else if (best.x > .65) "right" else "centre"))
            } else {
                base["state"] = if (ambiguous) "uncertain" else "searching"
                base["message"] = if (comparisonIncomplete) "Comparison is taking too long; no fresh recognition yet." else if (ambiguous) "Uncertain: similar landmarks match. Try another view." else if (best != null) "Checking a possible match — hold steady…" else "No verified match. Aim at a labeled landmark."
            }
            sampleAttempts = attempts.filter { it.algorithm == LearnedVision.NAME }
            return base
        } finally { live.close() }
    }
    override fun close() {
        learnedVision?.close(); learnedVision = null
        references.forEach { it.features.close() }; references.clear(); siftCache.values.forEach { it.close() }; siftCache.clear()
        orb.clear(); sift.clear(); orbMatcher.clear(); siftMatcher.clear(); gate.reset()
    }
}
