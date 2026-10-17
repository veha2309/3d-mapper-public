package com.vicentric.three_d_mapper

import kotlin.math.roundToInt

/** The exact resize/padding transform used by model tensors and geometry. */
class VisionLetterbox(val originalWidth: Int, val originalHeight: Int, val size: Int) {
    init { require(originalWidth > 0 && originalHeight > 0 && size > 0) }
    private val scale = size.toDouble() / maxOf(originalWidth, originalHeight)
    val width = (originalWidth * scale).roundToInt().coerceIn(1, size)
    val height = (originalHeight * scale).roundToInt().coerceIn(1, size)
    val left = (size - width) / 2
    val top = (size - height) / 2
    fun originalX(x: Float): Float = (x - left) * originalWidth / width
    fun originalY(y: Float): Float = (y - top) * originalHeight / height
    fun contains(x: Float, y: Float): Boolean = x.isFinite() && y.isFinite() &&
        x >= left && x < left + width && y >= top && y < top + height
}
